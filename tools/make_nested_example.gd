extends SceneTree
## 生成「工程嵌套」示例：examples/nested_child.fxgraph（子工程）
## 与 examples/nested_host.fxgraph（把它当节点用的外层工程）。
## 运行：godot --headless --path . --script res://tools/make_nested_example.gd

const CHILD := "res://examples/nested_child.fxgraph"
const HOST := "res://examples/nested_host.fxgraph"


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()

	# 子工程：形状 → 关键帧模糊 → 染色，自己的画布与时间轴。
	var child := FxGraphDoc.create("脉冲光斑")
	FxGraphDoc.set_canvas(child, 96, 96)
	FxGraphDoc.set_timeline(child, 30, 1.0, true)
	FxGraphDoc.add_node(child, "image.shape", "shape", Vector2(0, 0), {
		"shape": "circle", "color": "#ff7040", "background": "#00000000",
		"size": 0.34, "feather": 0.18, "center": [0.5, 0.5],
	})
	FxGraphDoc.add_node(child, "image.blur", "blur", Vector2(240, 0), {
		"radius": {"track": [[0.0, 2.0], [0.5, 9.0], [1.0, 2.0]], "interp": "ease"},
	})
	FxGraphDoc.add_node(child, "image.tint", "tint", Vector2(480, 0), {"color": "#ffd166", "amount": 0.5})
	var child_out := FxGraphDoc.add_node(child, "output.final", "out", Vector2(720, 0), {})
	if not child_out.is_empty():
		child["output"] = String(child_out.get("id", "out"))
	FxGraphDoc.connect_ports(child, "shape", "image", "blur", "image")
	FxGraphDoc.connect_ports(child, "blur", "image", "tint", "image")
	FxGraphDoc.connect_ports(child, "tint", "image", "out", "layer_0")
	var err := FxGraphDoc.save(child, CHILD)
	print("子工程写入 %s：%s" % [CHILD, error_string(err)])

	# 外层工程：把子工程当节点用，时间倍率 2 让光斑呼吸更急。
	var host := FxGraphDoc.create("嵌套示例")
	FxGraphDoc.set_canvas(host, 128, 128)
	FxGraphDoc.set_timeline(host, 30, 2.0, true)
	FxGraphDoc.add_node(host, "graph.subgraph", "sub", Vector2(0, 0), {
		"path": CHILD, "fit": "contain", "time_scale": 2.0,
	})
	FxGraphDoc.add_node(host, "image.mix", "mix", Vector2(420, 0), {"mode": "add", "amount": 1.0})
	var host_out := FxGraphDoc.add_node(host, "output.final", "out", Vector2(720, 0), {})
	if not host_out.is_empty():
		host["output"] = String(host_out.get("id", "out"))
	FxGraphDoc.connect_ports(host, "sub", "image", "mix", "a")
	FxGraphDoc.connect_ports(host, "sub", "image", "mix", "b")
	FxGraphDoc.connect_ports(host, "mix", "image", "out", "layer_0")
	err = FxGraphDoc.save(host, HOST)
	print("外层工程写入 %s：%s" % [HOST, error_string(err)])

	var runner := FxGraphRunner.new()
	var image: Image = runner.run(host, 0.35).get("image")
	print("渲染结果：%s" % ("null" if image == null else "%d×%d" % [image.get_width(), image.get_height()]))
	FxPluginHost.shutdown()
	quit(0 if image != null else 1)
