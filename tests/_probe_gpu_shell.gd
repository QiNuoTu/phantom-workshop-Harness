extends SceneTree
## GUI 探针：真实外壳切到 GPU 后端后仍能出图，且 GPU 算子确实生效。
func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	root.add_child(packed.instantiate())
	for i in range(12):
		await process_frame
	var shell: FxShell = root.get_node_or_null("FxShell") as FxShell
	if shell == null:
		for child in root.get_children():
			if child is FxShell:
				shell = child as FxShell
				break
	if shell == null:
		print("GPU_SHELL_FAIL 外壳未实例化")
		quit(1)
		return
	var render: FxRenderService = shell.service("render")
	FxSettings.set_value("render.backend", "gpu.standard")
	FxRenderBroker.invalidate()
	render.request_render()
	for i in range(240):
		await process_frame
		if String(render.last_stats().get("backend", "")) == "gpu.standard":
			break
	var stats: Dictionary = render.last_stats()
	var image: Image = render.last_image()
	print("GPU_SHELL backend=", String(stats.get("backend", "")),
		" gpu=", String(stats.get("gpu", "")),
		" used=", bool(stats.get("gpu_used", false)),
		" size=", image.get_size() if image != null else Vector2i.ZERO,
		" active=", FxGpuOps.active())
	print("GPU_SHELL_PASS=", image != null and FxGpuOps.active()
		and String(stats.get("backend", "")) == "gpu.standard")
	FxSettings.reset("render.backend")
	FxGpuCompute.reset()
	FxPluginHost.shutdown()
	quit(0)
