extends SceneTree
## GPU 算子基准（必须带显示跑）：同名 op 覆盖后，真实图求值耗时对比。
##   godot --path . --script res://tests/bench_gpu_ops.gd
##
## 只量「求值一帧」，不量界面/纹理上屏；两种后端都用新建的执行器，避免静态缓存串味。

var _doc: Dictionary = {}


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	_doc = _build_doc("image.blur", {"radius": 8})
	_run_pair("blur r8 · 256²")
	_doc = _build_doc("image.mix", {"mode": "normal", "amount": 0.35})
	_run_pair("mix normal α.35 · 256²")
	FxSettings.reset("render.backend")
	FxGpuComposer.reset()
	FxPluginHost.shutdown()
	quit(0)


func _build_doc(op_node: String, params: Dictionary) -> Dictionary:
	var doc := FxGraphDoc.create("gpu bench")
	FxGraphDoc.set_canvas(doc, 256, 256)
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2.ZERO, {"size": 16})
	FxGraphDoc.add_node(doc, "image.solid", "src2", Vector2.ZERO, {"color": "#c04080c0"})
	FxGraphDoc.add_node(doc, op_node, "op", Vector2.ZERO, params)
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2.ZERO, {})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "src", "image", "op", "image")
	FxGraphDoc.connect_ports(doc, "src2", "image", "op", "a")
	FxGraphDoc.connect_ports(doc, "src2", "image", "op", "b")
	FxGraphDoc.connect_ports(doc, "op", "image", "out", "background")
	return doc


func _run_pair(label: String) -> void:
	print("== %s ==" % label)
	var cpu := _measure("cpu.standard")
	var gpu := _measure("gpu.standard")
	print("CPU %s: %.2f ms/frame" % [label, cpu["ms"]])
	print("GPU %s: %.2f ms/frame" % [label, gpu["ms"]])
	print("加速比 %.2fx · 像素平均差 %.4f" % [
		float(cpu["ms"]) / maxf(float(gpu["ms"]), 0.001), _diff(cpu["image"], gpu["image"]),
	])


func _measure(backend: String) -> Dictionary:
	FxSettings.set_value("render.backend", backend)
	FxRenderBroker.invalidate()
	var runner := FxGraphRunner.new()
	runner.quality = 1
	runner.capture_previews = false
	# 静态缓存会把同一张图的第二次求值直接跳过，量到的是查表而不是算子。
	runner.static_cache_enabled = false
	runner.options = {"operator_quality": 1.0, "max_blur_radius": 32,
		"blur_fast_path": false, "operator_quality_threshold": 0.999}
	# 预热：着色器首帧要编译，不能算进稳态耗时。
	var warm: Dictionary = runner.call("run", _doc, 0.0)
	var rounds := 8
	var begin := Time.get_ticks_usec()
	for i in range(rounds):
		runner.invalidate_cache()
		warm = runner.call("run", _doc, 0.0)
	var ms := float(Time.get_ticks_usec() - begin) / 1000.0 / float(rounds)
	var image: Variant = warm.get("image")
	print("  %s 输出 %s · 步数 %s" % [backend,
		image.get_size() if image is Image else "null", warm.get("stats", {}).get("steps", "?")])
	return {"ms": ms, "image": image}


func _diff(a: Variant, b: Variant) -> float:
	if not (a is Image) or not (b is Image):
		return -1.0
	var ia := a as Image
	var ib := b as Image
	if ia.get_size() != ib.get_size():
		return -1.0
	var total := 0.0
	var samples := 0
	for y in range(0, ia.get_height(), 16):
		for x in range(0, ia.get_width(), 16):
			var ca := ia.get_pixel(x, y)
			var cb := ib.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) + absf(ca.a - cb.a)
			samples += 1
	return total / float(maxi(samples * 4, 1))
