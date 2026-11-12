class_name FxDemoGraph
extends RefCounted
## 示例文档：只在首次启动、且用户没有打开文件时装载。
##
## 这段内容属于 editor.document 插件，不属于基座：
## 删掉这个插件，软件就是一张空白工作台，而不是“内置一个示例”。


static func build() -> Dictionary:
	var doc := FxGraphDoc.create("示例 · 图像流")
	FxGraphDoc.set_canvas(doc, 128, 128)
	FxGraphDoc.set_timeline(doc, 30, 1.0, true)

	FxGraphDoc.add_node(doc, "image.solid", "bg", Vector2(20, 340), {
		"color": "#0b1018",
	})
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2(20, 15), {
		"cell": 16, "color_a": "#ff3b5c", "color_b": "#111722",
	})
	FxGraphDoc.add_node(doc, "image.blur", "blur", Vector2(350, 15), {
		"radius": {"track": [[0.0, 0.0], [0.5, 2.5], [1.0, 0.0]], "interp": "ease"},
	})
	FxGraphDoc.add_node(doc, "image.tint", "tint", Vector2(680, 15), {
		"color": "#7dffb0",
		"amount": {"track": [[0.0, 0.1], [0.5, 0.45], [1.0, 0.1]], "interp": "ease"},
	})
	FxGraphDoc.add_node(doc, "image.pixelfx", "fx", Vector2(350, 340), {
		"asset": "fire/campfire", "scale": 0.72, "offset": [0, 26],
	})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(690, 340), {
		"layers": [
			{"name": "底色", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true},
			{"name": "辉光", "blend": "add",
				"opacity": {"track": [[0.0, 0.15], [0.5, 0.5], [1.0, 0.15]], "interp": "ease"},
				"offset": [3, 3], "visible": true},
			{"name": "火焰", "blend": "normal", "opacity": 0.9, "offset": [0, 0], "visible": true},
		],
		"background_color": "#00000000",
	})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "src", "image", "blur", "image")
	FxGraphDoc.connect_ports(doc, "blur", "image", "tint", "image")
	FxGraphDoc.connect_ports(doc, "tint", "image", "out", "layer_0")
	FxGraphDoc.connect_ports(doc, "tint", "image", "out", "layer_1")
	FxGraphDoc.connect_ports(doc, "bg", "image", "out", "background")
	FxGraphDoc.connect_ports(doc, "fx", "image", "out", "layer_2")
	return doc
