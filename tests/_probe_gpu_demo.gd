extends SceneTree
## 真实工程单帧成本对比（唯一基准：examples/demo/示范工程.fxproj）。
## 关/开 render.gpu_ops，各测若干帧完整求值，验证 GPU 确实参与了预览求值。
const PROJECT := "res://examples/demo/示范工程.fxproj"

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("GPUDEMO_SKIP 无头无设备")
		quit(0); return
	FxPluginHost.ensure()
	await process_frame
	var loaded := FxProjectArchive.read_zip(PROJECT)
	if not bool(loaded.get("ok", false)):
		print("GPUDEMO_FAIL 加载失败"); quit(1); return
	var doc: Dictionary = loaded.get("doc", {})
	# 预热：编译 SPIR-V，别把一次性开销算进稳态。
	var warm_img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	warm_img.fill(Color(0.3, 0.6, 0.9, 1.0))
	FxGpuCompute.run(warm_img, null, 4, 0, 0, 1.0, Vector2i.ZERO,
		PackedInt32Array([2, 0, 100, 1000, 700, 330]))
	await process_frame
	var results := {}
	for use_gpu in [false, true]:
		FxSettings.set_value("render.gpu_ops", use_gpu)
		var times: Array[float] = []
		for k in range(4):
			var runner := _runner()
			var t0 := Time.get_ticks_usec()
			runner.run(doc, float(k) / 30.0)
			times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		var avg := 0.0
		for t in times:
			avg += t
		results["gpu" if use_gpu else "cpu"] = avg / float(times.size())
	FxSettings.set_value("render.gpu_ops", true)
	print("GPUDEMO device=", FxGpuDevice.state_text(),
		" nodes=", (doc.get("nodes", []) as Array).size(),
		" cpu_ms=%.1f gpu_ms=%.1f speedup=%.2fx bridge_calls=%d fallbacks=%d" % [
			results["cpu"], results["gpu"],
			results["cpu"] / maxf(results["gpu"], 0.001),
			FxGpuCompute.bridged_calls(), FxGpuCompute.bridge_fallbacks()])
	print("GPUDEMO_PASS=", results["gpu"] < results["cpu"] and results["cpu"] > 100.0)
	FxGpuCompute.reset()
	FxPluginHost.shutdown()
	quit(0)

func _runner() -> FxGraphRunner:
	var r := FxGraphRunner.new()
	r.quality = 1
	r.operator_quality = 1.0
	r.options = FxQualityPolicy.resolve({
		"playing": false, "width": 192, "height": 108, "node_count": 103,
		"t": 0.0, "paused_quality": 1, "seed": 1,
	})
	r.capture_previews = false
	r.static_cache_enabled = false
	return r
