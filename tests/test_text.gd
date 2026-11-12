extends SceneTree
## 外部字体自测：同步栅格化、中文、描边、字符串关键帧。
## 运行：godot --headless --path . --script res://tests/test_text.gd

var failures: Array[String] = []
var out_dir := "user://graph_test"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("== 外部字体自测 ==")
	var font_path := OS.get_system_font_path("Microsoft YaHei", 400, 100, false)
	if font_path.is_empty() or not FileAccess.file_exists(font_path):
		font_path = "C:/Windows/Fonts/msyh.ttc"
	if not FileAccess.file_exists(font_path):
		font_path = "C:/Windows/Fonts/arial.ttf"
	_check(FileAccess.file_exists(font_path), "找到测试字体：%s" % font_path)
	var font := FxFontLibrary.font(font_path)
	_check(font != null, "外部字体加载成功")
	_check(not FxFontLibrary.system_font_candidates().is_empty(), "能枚举系统字体候选")

	var doc := FxGraphDoc.create("文字自测")
	FxGraphDoc.set_canvas(doc, 256, 128)
	FxGraphDoc.set_timeline(doc, 30, 1.0, true)
	FxGraphDoc.add_node(doc, "image.text", "txt", Vector2(0, 0), {
		"font": font_path, "text": "幻像工坊", "size": 36, "color": "#ffffff",
		"align": "center", "outline": 2, "outline_color": "#101020", "line_spacing": 1.2,
	})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(320, 0), {
		"layers": [{"name": "字", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
	})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "txt", "image", "out", "layer_0")
	var runner := FxGraphRunner.new()
	var image: Image = runner.run(doc, 0.0).get("image")
	_check(image is Image and _opaque(image) > 300, "中文文字非空（%d 像素）" % _opaque(image))
	image.save_png(out_dir.path_join("text_zh.png"))

	var txt := FxGraphDoc.node(doc, "txt")
	txt["params"]["outline"] = 0
	var no_outline: Image = runner.run(doc, 0.0).get("image")
	_check(_opaque(no_outline) < _opaque(image), "描边增加覆盖像素（%d → %d）" % [_opaque(image), _opaque(no_outline)])
	no_outline.save_png(out_dir.path_join("text_zh_no_outline.png"))

	txt["params"]["outline"] = 2
	txt["params"]["text"] = {"track": [[0.0, "幻"], [0.5, "幻像工坊"], [1.0, "幻像工坊!"]], "interp": "linear"}
	var early: Image = runner.run(doc, 0.2).get("image")
	var late: Image = runner.run(doc, 0.8).get("image")
	_check(_opaque(early) < _opaque(late), "字符串轨道随 t 变化（%d → %d）" % [_opaque(early), _opaque(late)])
	late.save_png(out_dir.path_join("text_track.png"))

	var empty_doc := FxGraphDoc.create("无字体")
	FxGraphDoc.set_canvas(empty_doc, 64, 64)
	FxGraphDoc.add_node(empty_doc, "image.text", "t", Vector2(0, 0), {"font": "", "text": "Hi"})
	empty_doc["output"] = "t"
	var empty_result: Dictionary = runner.run(empty_doc, 0.0)
	_check(empty_result.get("image") is Image, "缺少字体不崩溃，仍返回图像")

	print("----")
	if failures.is_empty():
		print("字体自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _opaque(image: Image) -> int:
	var count := 0
	if image == null:
		return 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.2:
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
