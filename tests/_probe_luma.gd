extends SceneTree
## 诊断：示范工程某一帧的平均亮度（判断截图里预览为什么是黑的）。
## godot --headless --path . --script res://tests/_probe_luma.gd

const PROJECT := "res://examples/demo/示范工程.fxproj"


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	root.add_child(packed.instantiate())
	for i in range(20):
		await process_frame
	var shell: FxShell = null
	for child in root.get_children():
		if child is FxShell:
			shell = child as FxShell
			break
	var actions: Object = shell.service("document") as Object
	await actions.call("open_path_async", PROJECT)
	for i in range(120):
		await process_frame
		if (shell.store.doc.get("nodes", []) as Array).size() >= 100:
			break
	var render: Object = shell.service("render")
	for t in [0.0, 0.5, 1.0, 1.9]:
		var image: Image = render.call("render_once", t)
		if image == null:
			print("LUMA t=%.2f null" % t)
			continue
		var data := image.get_data()
		var sum := 0
		var step := maxi(4, data.size() / 4096)
		var n := 0
		for i in range(0, data.size(), step):
			sum += int(data[i])
			n += 1
		print("LUMA t=%.2f size=%s mean=%.1f" % [t, str(image.get_size()), float(sum) / float(maxi(n, 1))])
	FxPluginHost.shutdown()
	quit(0)
