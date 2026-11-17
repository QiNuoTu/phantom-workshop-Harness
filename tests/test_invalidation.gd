extends SceneTree
## 差量失效（#1 / Q4）自测：改一个节点的参数，只该废掉「它和它的下游」。
##
## 运行：
##   godot --headless --path . --script res://tests/test_invalidation.gd
##
## 这条链是 solid → hue → tint → output.final 四个节点。它刻意做得很短：
## 想验的不是性能，而是**失效边界** —— 改 hue 之后，solid 那条缓存该不该留。
## 旧实现（整份文档一个签名）的答案是「不该，全清」，于是改完参数永远零命中。
##
## 注意命中数的口径：链式求值是**拉取式**的，命中的那个节点会截断对上游的拉取。
## 所以「同一份文档第二遍只有 1 次命中」不是缓存没用，而是整条链被输出节点一次挡住 ——
## 这正是最理想的结果。把命中数当成「缓存好不好」的唯一指标，是本末倒置。

var failures: Array[String] = []


func _initialize() -> void:
	FxCatalog.reload()
	print("== 差量失效自测 ==")
	_test_chain_hits()
	_test_downstream_boundary()
	_test_layout_is_not_content()
	_test_scale_change_is_not_a_hit()
	_test_key_parsing()
	_test_display_scale()
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


## 四节点链：solid → hue → tint → output.final（background 口）。
## tint 用非白色：白色 tint 的 `lerp(c, c*white, amount)` 恒等于原色，
## 拿它当「改了参数画面该变」的样本，断的是一条永远为假的性质。
func _build_chain() -> Dictionary:
	var doc := FxGraphDoc.create("失效边界")
	FxGraphDoc.set_canvas(doc, 32, 32)
	var solid := FxGraphDoc.add_node(doc, "image.solid", "solid",
		Vector2.ZERO, {"color": "#3366cc"})
	var hue := FxGraphDoc.add_node(doc, "image.hue", "hue",
		Vector2.ZERO, {"hue": 0.0})
	var tint := FxGraphDoc.add_node(doc, "image.tint", "tint",
		Vector2.ZERO, {"color": "#ff3300", "amount": 0.0})
	var output := FxGraphDoc.add_node(doc, "output.final", "out")
	FxGraphDoc.connect_ports(doc, String(solid["id"]), "image", String(hue["id"]), "image")
	FxGraphDoc.connect_ports(doc, String(hue["id"]), "image", String(tint["id"]), "image")
	FxGraphDoc.connect_ports(doc, String(tint["id"]), "image", String(output["id"]), "background")
	doc["output"] = String(output["id"])
	return doc


func _run(runner: FxGraphRunner, doc: Dictionary) -> Dictionary:
	var result := runner.run(doc, 0.0)
	return {"image": result.get("image"), "stats": result.get("stats", {})}


func _bytes(image: Image) -> PackedByteArray:
	return image.get_data() if image is Image else PackedByteArray()


func _hits(run: Dictionary) -> int:
	return int((run["stats"] as Dictionary).get("cache_hits", 0))


## 同一份文档跑第二遍：输出节点一次命中，上游整条链不再被拉取。
func _test_chain_hits() -> void:
	var doc := _build_chain()
	var runner := FxGraphRunner.new()
	var first := _run(runner, doc)
	var second := _run(runner, doc)
	_check(_hits(first) == 0, "首跑没有命中（缓存是空的）")
	_check(_hits(second) >= 1, "第二遍至少命中 1 次（实际 %d）" % _hits(second))
	_check(int((second["stats"] as Dictionary).get("sig_misses", 0)) == 0,
		"同一份文档重跑：签名全部对得上，没有一条被误判失效")
	_check(_bytes(first["image"]) == _bytes(second["image"]), "命中不改变像素")


## 改 hue 的参数：solid 是它的上游，必须留下；hue 与下游必须失效。
func _test_downstream_boundary() -> void:
	var doc := _build_chain()
	var runner := FxGraphRunner.new()
	_run(runner, doc)
	var before := _run(runner, doc)
	var report := runner.invalidate_downstream(["hue"])
	_check(int(report.get("dropped", 0)) >= 2,
		"改 hue：丢掉 hue 与它下游的条目（实际丢 %d）" % int(report.get("dropped", 0)))
	_check(int(report.get("kept", 0)) >= 1,
		"改 hue：上游 solid 的条目被留住（实际留 %d）" % int(report.get("kept", 0)))
	# 真的改参数，再跑：solid 命中，输出必须变。
	(doc["nodes"] as Array)[1]["params"]["hue"] = 0.5
	var after := _run(runner, doc)
	_check(_hits(after) >= 1,
		"改完参数后上游仍然命中（实际 %d）" % _hits(after))
	_check(_bytes(before["image"]) != _bytes(after["image"]),
		"改 hue 真的改了像素（不然前面的命中毫无意义）")
	# 改末端参数：上游全部保留，只丢它自己。
	var tail := _run(runner, doc)
	var tail_report := runner.invalidate_downstream(["tint"])
	_check(int(tail_report.get("dropped", 0)) >= 1 and int(tail_report.get("kept", 0)) >= 2,
		"改末端 tint：只丢它自己，上游 2 条保住（丢 %d / 留 %d）"
			% [int(tail_report.get("dropped", 0)), int(tail_report.get("kept", 0))])
	(doc["nodes"] as Array)[2]["params"]["amount"] = 0.6
	var tail_after := _run(runner, doc)
	_check(_hits(tail_after) >= 1,
		"末端改动后 hue 仍命中（实际 %d）" % _hits(tail_after))
	_check(_bytes(tail["image"]) != _bytes(tail_after["image"]), "改 tint 真的改了像素")


## 拖动节点只改 pos / collapsed：不算内容，缓存必须照常命中。
func _test_layout_is_not_content() -> void:
	var doc := _build_chain()
	var runner := FxGraphRunner.new()
	_run(runner, doc)
	var before := _run(runner, doc)
	(doc["nodes"] as Array)[1]["pos"] = [420.0, 260.0]
	(doc["nodes"] as Array)[1]["collapsed"] = true
	var after := _run(runner, doc)
	_check(int((after["stats"] as Dictionary).get("sig_misses", 0)) == 0,
		"只挪位置 / 折叠：签名一条都不该失配")
	_check(_hits(after) >= _hits(before), "只挪位置：命中数不下降（%d → %d）"
		% [_hits(before), _hits(after)])
	_check(_bytes(before["image"]) == _bytes(after["image"]), "只挪位置：像素不变")


## `res_scale` 声明在**下游**节点上，改的是上游的求值倍率，内容签名不会变。
## 只比内容就会拿一张旧档位的图当命中 —— 这条断言就是防这个。
func _test_scale_change_is_not_a_hit() -> void:
	var doc := _build_chain()
	var runner := FxGraphRunner.new()
	_run(runner, doc)
	_run(runner, doc)
	# tint 声明半分辨率：solid/hue/tint 都进半分辨率区段，输出仍是 32×32。
	(doc["nodes"] as Array)[2]["res_scale"] = 0.5
	var after := _run(runner, doc)
	_check(int((after["stats"] as Dictionary).get("cache_hits", 0)) == 0,
		"下游改了 res_scale：下游不能再拿旧图当命中（命中 %d）"
			% int((after["stats"] as Dictionary).get("cache_hits", 0)))
	var declared := int((runner.scale_report as Dictionary).get("declared", 0))
	_check(declared == 1, "半分辨率声明被接受（declared=%d）" % declared)
	var image: Image = after["image"]
	_check(image is Image and image.get_width() == 32 and image.get_height() == 32,
		"降档不改变输出尺寸（永远等于画布）")


## 渲染服务从变更键里取节点集合。键形如 `param:<id>:<path>` / `node:<id>`。
func _test_key_parsing() -> void:
	var service := FxRenderService.new()
	var ids: Array = service.call("_changed_nodes",
		["param:hue:hue", "node:tint", "param:hue:value", "structure"])
	_check(ids == ["hue", "tint"], "从变更键取出节点集合（实际 %s）" % str(ids))
	var empty: Array = service.call("_changed_nodes", ["structure", "doc"])
	_check(empty.is_empty(), "结构类键不产出节点集合")
	service.free()


## 显示倍率只缩「贴到屏幕的那一张」：同一个 `_gpu_display` 入口，
## 缓存与导出走 `raw`（全分辨率），两者必须能同时成立。
func _test_display_scale() -> void:
	var service := FxRenderService.new()
	var image := Image.create_empty(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.4, 0.6, 1.0))
	service.policy = {"display_scale": 1.0}
	var full: Image = service.call("_gpu_display", 0, image)
	_check(full is Image and full.get_size() == Vector2i(64, 32), "倍率 1.0：显示副本等于画布尺寸")
	service.policy = {"display_scale": 0.5}
	var half: Image = service.call("_gpu_display", 1, image)
	_check(half is Image and half.get_size() == Vector2i(32, 16), "倍率 0.5：显示副本减半")
	service.policy = {"display_scale": 0.25}
	var quarter: Image = service.call("_gpu_display", 2, image)
	_check(quarter is Image and quarter.get_size() == Vector2i(16, 8), "倍率 0.25：显示副本四分之一")
	_check(image.get_size() == Vector2i(64, 32), "源图（归档用的那一份）一个像素都没被改")
	_check(half.get_size() != quarter.get_size(), "不同倍率不共用显示缓存条目")
	# 同一个倍率再来一次必须命中显示缓存，不能每帧重新缩放。
	service.policy = {"display_scale": 0.5}
	var again: Image = service.call("_gpu_display", 1, image)
	_check(again == half, "同键第二次取到同一个对象（显示缓存生效）")
	service.free()
