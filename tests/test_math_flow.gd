extends SceneTree
## 控制流 + 数值节点自测：循环索引 → 数值运算 → 位移；比较 → 分支 → 累积。
## 运行：godot --headless --path . --script res://tests/test_math_flow.gd

var failures: Array[String] = []
var out_dir := "user://graph_test"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("== 数值 / 分支 / 循环自测 ==")
	var doc := _build_doc("greater_equal", 2.0)
	_check(FxGraphDoc.validate(doc).is_empty(), "图校验通过")
	var runner := FxGraphRunner.new()
	var result := runner.run(doc, 0.0)
	var image: Image = result.get("image")
	_check(image is Image, "输出图像")
	var two_squares := _opaque(image) if image is Image else 0
	_check(two_squares > 300, "两次累积有明显内容（%d 像素）" % two_squares)
	var loop_out: Dictionary = runner.ctx.outputs.get("loop", {})
	_check(FxPortType.as_int(loop_out.get("iterations", 0), 0) == 4, "循环执行 4 次")
	var mul_out: Dictionary = runner.ctx.outputs.get("mul", {})
	_check(is_equal_approx(FxPortType.as_number(mul_out.get("number", -1), -1), 48.0), "末次索引 × 16 = 48（实际 %s）" % str(mul_out.get("number")))
	var cmp_out: Dictionary = runner.ctx.outputs.get("cmp", {})
	_check(FxPortType.as_bool(cmp_out.get("result", false), false), "比较 3 >= 2 为真")
	if image is Image:
		image.save_png(out_dir.path_join("flow_two.png"))

	# 把阈值降到 -1：每次都为真，四次累积都应该发生。
	var doc_all := _build_doc("greater_equal", -1.0)
	var all_result := FxGraphRunner.new().run(doc_all, 0.0)
	var four_squares := _opaque(all_result.get("image"))
	_check(four_squares > two_squares, "条件放宽后累积次数增加（%d → %d）" % [two_squares, four_squares])
	(all_result.get("image") as Image).save_png(out_dir.path_join("flow_four.png"))

	print("----")
	if failures.is_empty():
		print("数值/控制流自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _build_doc(compare_op: String, compare_b: float) -> Dictionary:
	var doc := FxGraphDoc.create("控制流自测")
	FxGraphDoc.set_canvas(doc, 128, 128)
	FxGraphDoc.set_timeline(doc, 30, 1.0, false)
	FxGraphDoc.add_node(doc, "image.solid", "solid", Vector2(0, 0), {"color": "#ffcf6b"})
	FxGraphDoc.add_node(doc, "flow.index", "idx", Vector2(0, 160), {})
	FxGraphDoc.add_node(doc, "math.number", "mul", Vector2(220, 160), {
		"op": "multiply", "b": 16.0,
	})
	FxGraphDoc.add_node(doc, "image.transform", "xf", Vector2(440, 0), {
		"scale": [0.25, 0.25],
	})
	FxGraphDoc.add_node(doc, "logic.compare", "cmp", Vector2(220, 300), {
		"op": compare_op, "b": compare_b,
	})
	FxGraphDoc.add_node(doc, "flow.for", "loop", Vector2(0, 440), {"first": 0, "last": 3, "step": 1})
	FxGraphDoc.add_node(doc, "flow.branch", "branch", Vector2(440, 440), {})
	FxGraphDoc.add_node(doc, "image.accumulate", "acc", Vector2(660, 0), {"mode": "normal"})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(880, 0), {
		"layers": [{"name": "累积", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
	})
	doc["output"] = "out"
	var links := [
		["solid", "image", "xf", "image"],
		["idx", "index", "mul", "a"],
		["mul", "number", "xf", "offset"],
		["xf", "image", "acc", "image"],
		["idx", "index", "cmp", "a"],
		["cmp", "result", "branch", "condition"],
		["loop", "body", "branch", "exec"],
		["branch", "true", "acc", "exec"],
		["acc", "image", "out", "layer_0"],
	]
	for c in links:
		var err := FxGraphDoc.connect_ports(doc, String(c[0]), String(c[1]), String(c[2]), String(c[3]))
		if err != FxGraphDoc.LINK_OK:
			push_error("连线失败：%s → %s (%d)" % [c[0], c[2], err])
	return doc


func _opaque(image: Variant) -> int:
	if not image is Image:
		return 0
	var count := 0
	for y in range((image as Image).get_height()):
		for x in range((image as Image).get_width()):
			if (image as Image).get_pixel(x, y).a > 0.5:
				count += 1
	return count


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
