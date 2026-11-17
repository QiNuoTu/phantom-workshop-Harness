extends SceneTree
## 画布尺寸的单一真源（app 0.0.17）。
##
## 背景：`output.final` 上有「画布宽 / 画布高」两个参数。它们曾经是**覆盖值**：
## 节点说 256×108、文档说 192×108，输出帧尺寸就和帧缓存的定长布局不符，
## 每一帧都被渲染服务的尺寸闸门丢掉 —— 画面卡死、不报错、日志干净。
##
## 现在它们是文档画布的**视图**（节点定义里声明 `binds`）：
##   · 算子一律按 `ctx.canvas` 出图，不看参数；
##   · 写这个参数 = 写文档画布，节点上不留值；
##   · 归因诊断能认出「遗留覆盖值」并判给插件。
##
## 运行：
##   godot --headless --path . --script res://tests/test_render_canvas_binding.gd

var failures: Array[String] = []


func _initialize() -> void:
	FxCatalog.reload()
	print("== 画布单一真源自测 ==")
	_test_op_ignores_override()
	_test_binding_writes_canvas()
	_test_nested_path_untouched()
	_test_blame_reports_legacy()
	_test_blame_clean_doc()
	_test_time_change_uses_cache()
	print("----")
	if failures.is_empty():
		print("全部通过。")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)


func _doc_with_output(canvas: Vector2i) -> Dictionary:
	var doc := FxGraphDoc.create("画布绑定")
	FxGraphDoc.set_canvas(doc, canvas.x, canvas.y)
	var output := FxGraphDoc.add_node(doc, "output.final", "out")
	doc["output"] = String(output["id"])
	var solid := FxGraphDoc.add_node(doc, "image.solid", "solid",
		Vector2.ZERO, {"color": "#3366cc"})
	FxGraphDoc.connect_ports(doc, String(solid["id"]), "image", String(output["id"]), "background")
	return doc


func _frame_size(doc: Dictionary) -> Vector2i:
	var runner := FxGraphRunner.new()
	var result := runner.run(doc, 0.0)
	var image: Variant = result.get("image")
	if not image is Image:
		return Vector2i.ZERO
	return (image as Image).get_size()


## 旧工程里留下的覆盖值不得改变输出尺寸：尺寸只认文档画布。
func _test_op_ignores_override() -> void:
	var doc := _doc_with_output(Vector2i(32, 24))
	# 直接写进节点，模拟「旧工程里的遗留值」（绕开 apply_param 的绑定拦截）。
	var node := FxGraphDoc.node(doc, "out")
	var params: Dictionary = node.get("params", {})
	params["canvas_width"] = 64
	params["canvas_height"] = 48
	node["params"] = params
	var size := _frame_size(doc)
	_check(size.x == 32, "遗留覆盖值不改变输出宽（实得 %d，画布 32）" % size.x)
	_check(size.y == 24, "遗留覆盖值不改变输出高（实得 %d，画布 24）" % size.y)


## 写绑定参数 = 写文档画布；节点上永远不留值。
func _test_binding_writes_canvas() -> void:
	var doc := _doc_with_output(Vector2i(32, 24))
	var api := FxGraphAccessCore.new()
	_check(api.doc_apply_path(doc, "out", "canvas_width", 64), "绑定参数写入被接受")
	_check(FxGraphDoc.canvas(doc) == Vector2i(64, 24),
		"写画布宽后文档画布变成 64×24（实得 %s）" % str(FxGraphDoc.canvas(doc)))
	var params: Dictionary = FxGraphDoc.node(doc, "out").get("params", {})
	_check(not params.has("canvas_width"), "节点上没有留下 canvas_width（不留第二份真相）")
	# 0 是「跟随」哨兵：不表达尺寸，什么都不该发生（也不该写进节点）。
	api.doc_apply_path(doc, "out", "canvas_width", 0)
	_check(FxGraphDoc.canvas(doc) == Vector2i(64, 24),
		"写 0 不改画布（0 = 跟随，不是 1 像素）")
	api.doc_apply_path(doc, "out", "canvas_height", 40)
	_check(FxGraphDoc.canvas(doc) == Vector2i(64, 40),
		"写画布高只改高（实得 %s）" % str(FxGraphDoc.canvas(doc)))
	_check(_frame_size(doc) == Vector2i(64, 40), "输出尺寸跟着文档画布走")


## 绑定只在顶层参数上生效：嵌套路径（图层透明度这类）照旧写进节点。
func _test_nested_path_untouched() -> void:
	var doc := _doc_with_output(Vector2i(32, 24))
	var api := FxGraphAccessCore.new()
	api.doc_apply_path(doc, "out", "layers.0.opacity", 0.5)
	var layers: Variant = FxGraphDoc.node(doc, "out").get("params", {}).get("layers", [])
	var opacity := 1.0
	if layers is Array and not (layers as Array).is_empty():
		opacity = float(((layers as Array)[0] as Dictionary).get("opacity", 1.0))
	_check(absf(opacity - 0.5) < 0.0001, "嵌套路径照常写进节点（实得 %.2f）" % opacity)
	_check(FxGraphDoc.canvas(doc) == Vector2i(32, 24), "嵌套路径不碰画布")


## 归因诊断：遗留覆盖值要判给插件（错误级），而不是静默。
func _test_blame_reports_legacy() -> void:
	var doc := _doc_with_output(Vector2i(32, 24))
	var node := FxGraphDoc.node(doc, "out")
	var params: Dictionary = node.get("params", {})
	params["canvas_width"] = 64
	node["params"] = params
	var found := _binding_findings(FxBlame.report(doc))
	_check(found.size() == 1, "遗留覆盖值被归因诊断抓到（实得 %d 条）" % found.size())
	if found.size() == 1:
		var item: Dictionary = found[0]
		_check(String(item.get("level", "")) == "error", "判为 error")
		_check(String(item.get("owner", "")) == "core.image",
			"归属节点定义所属插件（实得 %s）" % String(item.get("owner", "")))


func _test_blame_clean_doc() -> void:
	var doc := _doc_with_output(Vector2i(32, 24))
	var found := _binding_findings(FxBlame.report(doc))
	_check(found.is_empty(), "干净文档不被误报（实得 %d 条）" % found.size())


func _binding_findings(report: Dictionary) -> Array:
	var out: Array = []
	for raw in report.get("findings", []):
		var item: Dictionary = raw
		if String(item.get("message", "")).contains("的视图"):
			out.append(item)
	return out


## 拖时间轴（纯 time 变化）：缓存里那一格是精确帧，就必须直接接管，
## 不再排一次实时求值。拖动时每个鼠标事件都是一次 set_time，
## 求值一帧要上百毫秒，指针永远追不上 —— 那正是「拖了没反应」。
func _test_time_change_uses_cache() -> void:
	var store := FxDocumentStore.new()
	store.attach(_doc_with_output(Vector2i(16, 12)))
	var service := FxRenderService.new()
	root.add_child(service)
	service.setup(store)
	var cache: FxFrameCache = service.cache
	# 桶要按当前文档定下来，否则归档与索引都没有一帧可查。
	service._cache_ensure_fingerprint(30, 1.0, "test")
	_check(cache.frame_count() > 2, "测试用桶建起来了（%d 帧）" % cache.frame_count())
	var identity := store.content_key()
	var frame := Image.create_empty(16, 12, false, Image.FORMAT_RGBA8)
	frame.fill(Color(0.2, 0.4, 0.6, 1.0))
	cache.put(1, frame, true, false, identity)
	store.set_time(1.0 / 30.0)
	_check(not bool(service.get("_dirty")),
		"时间落到已缓存的精确帧：不排求值（_dirty = false）")
	# 落在一格没算过的帧上：照旧要排，否则屏幕上会一直停着上一张。
	store.set_time(0.9)
	_check(bool(service.get("_dirty")),
		"时间落到未缓存的帧：仍然排求值（_dirty = true）")
	service.free()
