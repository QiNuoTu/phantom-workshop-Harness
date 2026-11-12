extends SceneTree
## P1 无头自测：目录 → 文档 → 连线 → 执行 → 预览 → JSON 往返 → 控制流。
##
## 运行：
##   godot --headless --path . --script res://tests/test_graph_core.gd
##
## 不依赖场景树与渲染服务器：所有算子都只操作 Image，能在 CI 里跑。

var failures: Array[String] = []
var out_dir := "user://graph_test"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("== P1 图核心自测 ==")
	_test_catalog()
	_test_store_graph_ops()
	var doc := _build_render_doc()
	_test_connect_rules(doc)
	_test_roundtrip(doc)
	_test_render(doc)
	_test_single_preview(doc)
	_test_control_flow()
	print("----")
	if failures.is_empty():
		print("全部通过。输出目录：", ProjectSettings.globalize_path(out_dir))
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


func _test_catalog() -> void:
	FxCatalog.reload()
	var defs := FxCatalog.all()
	_check(defs.size() >= 15, "目录加载至少 15 个节点（实际 %d）" % defs.size())
	_check(FxCatalog.def("image.blur") != null, "存在 image.blur 定义")
	_check(FxCatalog.def("output.final") != null, "存在 output.final 定义")
	var out_def := FxCatalog.def("output.final")
	var ports := FxCatalog.ports(out_def, {"layers": [{"name": "A"}, {"name": "B"}, {"name": "C"}]})
	var ids: Array[String] = []
	for p in ports.get("inputs", []):
		ids.append(String((p as Dictionary).get("id", "")))
	_check(ids.has("background") and ids.has("layer_0") and ids.has("layer_2"), "输出图层端口按 layers 动态生成")
	# 背景 + 3 个图层 + 3 个可连线参数（背景色 / 画布宽 / 画布高）
	_check(ids.size() == 7, "三层输出共 7 个输入端口（实际 %d）" % ids.size())
	_check(ids.has("canvas_width") and ids.has("background_color"),
		"输出节点的参数同样可连线，不再有「只能填不能接」的参数")
	var blur_ports := FxCatalog.ports(FxCatalog.def("image.blur"))
	var has_radius_port := false
	for p in blur_ports.get("inputs", []):
		if String((p as Dictionary).get("id", "")) == "radius":
			has_radius_port = true
	_check(has_radius_port, "可绑定参数长出 radius 输入端口")


func _build_render_doc() -> Dictionary:
	var doc := FxGraphDoc.create("核心自测")
	FxGraphDoc.set_canvas(doc, 64, 64)
	FxGraphDoc.set_timeline(doc, 30, 1.0, true)
	FxGraphDoc.add_node(doc, "image.checker", "n_src", Vector2(0, 0), {
		"cell": 8, "color_a": "#ff3355", "color_b": "#223344",
	})
	FxGraphDoc.add_node(doc, "image.blur", "n_blur", Vector2(220, 0), {
		"radius": {"track": [[0.0, 0.0], [1.0, 4.0]], "interp": "linear"},
	})
	FxGraphDoc.add_node(doc, "image.tint", "n_tint", Vector2(440, 0), {
		"color": "#7dffb0", "amount": 0.35,
	})
	FxGraphDoc.add_node(doc, "output.final", "n_out", Vector2(660, 0), {
		"layers": [{"name": "主体", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
		"background_color": "#00000000",
	})
	doc["output"] = "n_out"
	var connections := [
		["n_src", "image", "n_blur", "image"],
		["n_blur", "image", "n_tint", "image"],
		["n_tint", "image", "n_out", "layer_0"],
		["n_src", "image", "n_out", "background"],
	]
	for c in connections:
		var err := FxGraphDoc.connect_ports(doc, String(c[0]), String(c[1]), String(c[2]), String(c[3]))
		_check(err == FxGraphDoc.LINK_OK, "连线 %s → %s" % [String(c[0]), String(c[2])])
	var errors := FxGraphDoc.validate(doc)
	_check(errors.is_empty(), "文档校验通过（%s）" % ", ".join(errors))
	return doc


## 文档存储的图语义：现在由 core.graph 通过 FxGraphFacade 提供，
## 基座的 FxDocumentStore 只负责撤销栈与通知（P0 里验的就是那一层）。
func _test_store_graph_ops() -> void:
	print("== 文档存储（图语义来自 core.graph） ==")
	var store := FxDocumentStore.new()
	store.attach(FxGraphDoc.create("store"))
	var out_node := store.add_node("output.final", "", Vector2(10, 10), {})
	_check(not out_node.is_empty(), "存储能建节点")
	_check(FxGraphDoc.output_id(store.doc) == String(out_node.get("id", "")),
		"第一个输出节点自动成为最终输出")
	store.add_node("image.blur", "b", Vector2.ZERO, {"radius": 1})
	store.apply_param("b", "radius", 5)
	_check(int((FxGraphDoc.node(store.doc, "b").get("params", {}) as Dictionary)["radius"]) == 5,
		"参数写入")
	store.undo()
	_check(int((FxGraphDoc.node(store.doc, "b").get("params", {}) as Dictionary)["radius"]) == 1,
		"撤销恢复参数")
	store.redo()
	var canvas_before := FxGraphDoc.canvas(store.doc)
	store.set_canvas(128, 96)
	_check(FxGraphDoc.canvas(store.doc) == Vector2i(128, 96), "画布尺寸可改")
	store.undo()
	_check(FxGraphDoc.canvas(store.doc) == canvas_before, "撤销恢复画布")
	# 图层路径写入：数组/嵌套的展开规则属于图语义，基座不复制一份。
	store.apply_path("b", "layers.0.opacity", 0.25)
	var params := FxGraphDoc.node(store.doc, "b").get("params", {}) as Dictionary
	var layers: Variant = params.get("layers")
	var layer_ok: bool = layers is Array and not (layers as Array).is_empty() \
		and absf(float(((layers as Array)[0] as Dictionary).get("opacity", 0.0)) - 0.25) < 0.001
	_check(layer_ok, "嵌套路径写入图层数组")
	# 失败的操作不能留撤销点。
	var undo_before: int = store._undo.size()
	var code := store.connect_ports("b", "image", String(out_node.get("id", "")), "not_a_port")
	_check(code != FxGraphDoc.LINK_OK, "非法连线返回错误码（%d）" % code)
	_check(store._undo.size() == undo_before, "失败连线不产生撤销点")


func _test_connect_rules(doc: Dictionary) -> void:
	var edges_before: int = (doc.get("edges", []) as Array).size()
	var err_cycle := FxGraphDoc.connect_ports(doc, "n_tint", "image", "n_blur", "image")
	_check(err_cycle == FxGraphDoc.LINK_CYCLE, "拒绝成环（返回 %d）" % err_cycle)
	_check((doc.get("edges", []) as Array).size() == edges_before, "成环失败后恢复原有连线")
	var err_port := FxGraphDoc.connect_ports(doc, "n_blur", "image", "n_out", "no_such_port")
	_check(err_port == FxGraphDoc.LINK_NO_PORT, "拒绝不存在的端口")
	FxGraphDoc.add_node(doc, "flow.index", "n_idx", Vector2(0, 300), {})
	var err_type := FxGraphDoc.connect_ports(doc, "n_idx", "index", "n_blur", "image")
	_check(err_type == FxGraphDoc.LINK_TYPE, "拒绝 number → image")
	FxGraphDoc.remove_node(doc, "n_idx")


func _test_roundtrip(doc: Dictionary) -> void:
	var path := out_dir.path_join("core.fxgraph")
	var err := FxGraphDoc.save(doc, path)
	_check(err == OK, "保存 JSON")
	var loaded := FxGraphDoc.load_json(path)
	_check((loaded.get("nodes", []) as Array).size() == 4, "读回 4 个节点")
	_check((loaded.get("edges", []) as Array).size() == 4, "读回 4 条连线")
	_check(FxGraphDoc.output_id(loaded) == "n_out", "读回输出节点")
	_check(FxGraphDoc.canvas(loaded) == Vector2i(64, 64), "读回画布尺寸")
	var loaded_blur := FxGraphDoc.node(loaded, "n_blur")
	var radius: Variant = FxCatalog.value_at(loaded_blur.get("params", {}), "radius.track.1.1")
	_check(is_equal_approx(FxPortType.as_number(radius, -1.0), 4.0), "轨道随 JSON 往返")
	var track := TimelineOps.track_of(loaded, "n_blur", "radius")
	_check(not track.is_empty(), "TimelineOps 能读到轨道（补齐 FxGraphDoc/FxCatalog 依赖）")
	_check(FxGraphDoc.validate(loaded).is_empty(), "读回文档校验通过")


func _test_render(doc: Dictionary) -> void:
	var runner := FxGraphRunner.new()
	runner.capture_previews = true
	runner.preview_limit = 96
	var result := runner.run(doc, 0.5)
	var image: Image = result.get("image")
	_check(image is Image, "输出节点产出 Image")
	if not image is Image:
		return
	_check(image.get_width() == 64 and image.get_height() == 64, "输出尺寸等于画布")
	var opaque := _count_opaque(image)
	_check(opaque > 100, "输出非空（%d 个不透明像素）" % opaque)
	var previews: Dictionary = result.get("previews", {})
	_check(previews.size() == 4, "四个节点都有预览（实际 %d）" % previews.size())
	_check(previews.has("n_blur") and previews.has("n_out"), "预览按节点 id 归档")
	image.save_png(out_dir.path_join("core.png"))
	var preview: Image = previews.get("n_blur")
	if preview is Image:
		preview.save_png(out_dir.path_join("preview_blur.png"))
	var t0 := runner.run(doc, 0.0)
	var t1 := runner.run(doc, 0.5)
	var a: Image = t0.get("image")
	var b: Image = t1.get("image")
	_check(a is Image and b is Image and a.get_data() != b.get_data(), "关键帧轨道改变画面（半径 0 → 2）")
	var loaded := FxGraphDoc.load_json(out_dir.path_join("core.fxgraph"))
	var loaded_image: Image = runner.run(loaded, 0.5).get("image")
	_check(loaded_image is Image and image.get_data() == loaded_image.get_data(), "读回文档渲染结果一致")
	print("      统计：", result.get("stats"))


func _test_single_preview(doc: Dictionary) -> void:
	var runner := FxGraphRunner.new()
	runner.capture_previews = true
	var out := runner.evaluate_node(doc, "n_blur", 0.75)
	_check(out.get("image") is Image, "单节点求值返回图像")
	_check((runner.ctx.previews as Dictionary).has("n_blur"), "单节点求值只捕获该节点预览")


func _test_control_flow() -> void:
	var doc := FxGraphDoc.create("循环自测")
	FxGraphDoc.set_canvas(doc, 32, 32)
	FxGraphDoc.add_node(doc, "image.solid", "n_solid", Vector2(0, 0), {"color": "#ff8844"})
	FxGraphDoc.add_node(doc, "flow.index", "n_idx", Vector2(0, 160), {})
	FxGraphDoc.add_node(doc, "image.transform", "n_xf", Vector2(220, 0), {"scale": [1, 1]})
	FxGraphDoc.add_node(doc, "flow.for", "n_loop", Vector2(0, 320), {
		"first": 0, "last": 3, "step": 1,
	})
	FxGraphDoc.add_node(doc, "image.accumulate", "n_acc", Vector2(440, 0), {
		"mode": "normal", "opacity": 1.0,
	})
	FxGraphDoc.add_node(doc, "output.final", "n_out", Vector2(660, 0), {
		"layers": [{"name": "累积", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
	})
	doc["output"] = "n_out"
	var links := [
		["n_solid", "image", "n_xf", "image"],
		["n_idx", "index", "n_xf", "offset"],
		["n_xf", "image", "n_acc", "image"],
		["n_loop", "body", "n_acc", "exec"],
		["n_acc", "image", "n_out", "layer_0"],
	]
	for c in links:
		var err := FxGraphDoc.connect_ports(doc, String(c[0]), String(c[1]), String(c[2]), String(c[3]))
		_check(err == FxGraphDoc.LINK_OK, "循环图连线 %s.%s → %s.%s" % [c[0], c[1], c[2], c[3]])
	var runner := FxGraphRunner.new()
	var result := runner.run(doc, 0.0)
	var image: Image = result.get("image")
	_check(image is Image, "循环图产出图像")
	if image is Image:
		_check(_count_opaque(image) > 100, "循环累积非空（%d 像素）" % _count_opaque(image))
		image.save_png(out_dir.path_join("loop.png"))
	var loop_out: Dictionary = runner.ctx.outputs.get("n_loop", {})
	_check(FxPortType.as_int(loop_out.get("iterations", 0), 0) == 4, "循环执行 4 次（实际 %s）" % str(loop_out.get("iterations", 0)))
	_check(runner.ctx.loop_ticks >= 4, "循环计数器工作（%d）" % runner.ctx.loop_ticks)


func _count_opaque(image: Image) -> int:
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.5:
				count += 1
	return count


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
