extends SceneTree
## GUI 探针：GPU 算子在工作线程里通过渲染线程桥生效，且与 CPU 逐像素一致。
var worker_result: Image = null
var thread: Thread = null

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("GPU_WORKER_SKIP 无头")
		quit(0); return
	FxPluginHost.ensure()
	await process_frame
	var src := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	src.fill(Color(0, 0, 0, 0))
	for y in range(16, 48):
		for x in range(16, 48):
			src.set_pixel(x, y, Color(0.4, 0.7, 0.9, 1.0))
	var params := {"color": "#ffb454", "thickness": 2, "mode": "outside", "threshold": 0.1}
	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(64, 64)
	ctx.t = 0.0
	var cpu: Dictionary = FxOpsComposite.outline(ctx, {}, null, {"image": src.duplicate()}, params)
	var cpu_img: Image = cpu.get("image")
	var color := FxPortType.as_color(params["color"], Color(1, 0.7, 0.33))
	var main_gpu := FxGpuCompute.outline_bridged(src.duplicate(), 2, false, 0.1, color)
	print("GPU_WORKER device=", FxGpuDevice.state_text(), " active=", FxGpuOps.active())
	print("GPU_WORKER main_diff=", _diff(cpu_img, main_gpu))
	# 工作线程：走渲染线程桥
	thread = Thread.new()
	thread.start(Callable(self, "_worker").bind(src.duplicate(), color))
	for i in range(600):
		await process_frame
		if not thread.is_alive(): break
	thread.wait_to_finish()
	print("GPU_WORKER worker_diff=", _diff(cpu_img, worker_result),
		" bridge_calls=", FxGpuCompute.bridged_calls(),
		" fallbacks=", FxGpuCompute.bridge_fallbacks())
	print("GPU_WORKER_PASS=", _diff(cpu_img, main_gpu) < 0.01
		and _diff(cpu_img, worker_result) < 0.01
		and FxGpuCompute.bridged_calls() > 0
		and FxGpuCompute.bridge_fallbacks() == 0)
	FxGpuCompute.reset()
	FxPluginHost.shutdown()
	quit(0)

func _worker(src: Image, color: Color) -> void:
	worker_result = FxGpuCompute.outline_bridged(src, 2, false, 0.1, color)

func _diff(a: Image, b: Image) -> float:
	if a == null or b == null or a.get_size() != b.get_size():
		return 999.0
	var ab := a.get_data(); var bb := b.get_data()
	var total := 0
	for i in range(0, ab.size(), 4):
		total += absi(int(ab[i]) - int(bb[i])) + absi(int(ab[i+1]) - int(bb[i+1])) \
			+ absi(int(ab[i+2]) - int(bb[i+2])) + absi(int(ab[i+3]) - int(bb[i+3]))
	return float(total) / float(ab.size() * 255.0)
