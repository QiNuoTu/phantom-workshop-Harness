extends SceneTree
## pixelfx 素材节点自测：素材扫描、取帧、动画、调色板重映射。
## 运行：godot --headless --path . --script res://tests/test_pixelfx.gd

var failures: Array[String] = []
var out_dir := "user://graph_test"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("== pixelfx 素材节点自测 ==")
	var all := FxAssetLibrary.all()
	_check(all.size() >= 200, "素材库扫描到 %d 套特效" % all.size())
	var campfire := FxAssetLibrary.entry("fire/campfire")
	_check(not campfire.is_empty(), "存在 fire/campfire")
	_check(int(campfire.get("frame_count", 0)) == 90, "campfire 有 90 帧")
	_check(int(campfire.get("fps", 0)) == 30, "campfire 帧率 30")

	var doc := FxGraphDoc.create("pixelfx 自测")
	FxGraphDoc.set_canvas(doc, 128, 128)
	FxGraphDoc.set_timeline(doc, 30, 1.0, true)
	FxGraphDoc.add_node(doc, "image.pixelfx", "fx", Vector2(0, 0), {
		"asset": "fire/campfire", "scale": 1.0, "loop": true,
	})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(320, 0), {
		"layers": [{"name": "火", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
	})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "fx", "image", "out", "layer_0")
	_check(FxGraphDoc.validate(doc).is_empty(), "文档校验通过")

	var runner := FxGraphRunner.new()
	var at0: Image = runner.run(doc, 0.0).get("image")
	var at_half: Image = runner.run(doc, 0.5).get("image")
	_check(at0 is Image and _opaque(at0) > 200, "第 0 帧非空（%d 像素）" % _opaque(at0))
	_check(at0 is Image and at_half is Image and at0.get_data() != at_half.get_data(), "0s 与 0.5s 是不同帧")
	at_half.save_png(out_dir.path_join("pixelfx_campfire.png"))
	var previews: Dictionary = runner.run(doc, 0.5).get("previews", {})
	_check(previews.has("fx"), "素材节点有预览")

	var fx_node := FxGraphDoc.node(doc, "fx")
	fx_node["params"]["palette"] = "#100018,#3a0f6b,#ff3b8d,#ffd166"
	fx_node["params"]["palette_amount"] = 1.0
	var recolored: Image = runner.run(doc, 0.5).get("image")
	_check(recolored is Image and at_half is Image and recolored.get_data() != at_half.get_data(), "调色板重映射改变画面")
	recolored.save_png(out_dir.path_join("pixelfx_recolored.png"))

	var rotated_node := FxGraphDoc.node(doc, "fx")
	rotated_node["params"]["palette"] = ""
	rotated_node["params"]["angle"] = 25.0
	rotated_node["params"]["offset"] = [12, -8]
	var rotated: Image = runner.run(doc, 0.5).get("image")
	_check(rotated is Image and _opaque(rotated) > 100, "旋转/位移后仍有内容")
	rotated.save_png(out_dir.path_join("pixelfx_rotated.png"))

	print("----")
	if failures.is_empty():
		print("pixelfx 自测全部通过")
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
			if image.get_pixel(x, y).a > 0.5:
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
