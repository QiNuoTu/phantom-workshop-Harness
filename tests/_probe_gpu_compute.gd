extends SceneTree
func _initialize() -> void:
	FxPluginHost.ensure()
	print("设备 ", FxGpuDevice.state_text(), " compute=", FxGpuCompute.available())
	var src := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in range(32):
		for x in range(32):
			src.set_pixel(x, y, Color(float(x % 8) / 7.0, float(y % 8) / 7.0, 0.3, 1.0))
	var identity := FxGpuCompute.run(src, null, 0, 0, 0, 1.0, Vector2i(1, 0))
	print("identity ", _diff(src, identity))
	var cpu_blur := FxOpsImage._box_blur(src, 3)
	var gpu_blur := FxGpuCompute.blur(src, 3)
	print("blur r3 差 ", _diff(cpu_blur, gpu_blur))
	var top := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	top.fill(Color(0.9, 0.2, 0.4, 0.6))
	var cpu_mix: Image = src.duplicate()
	FxImageUtil.blend_image(cpu_mix, top, Vector2.ZERO, "normal", 0.35)
	var gpu_mix := FxGpuCompute.mix(src, top, 0.35, 0)
	print("mix α.35 差 ", _diff(cpu_mix, gpu_mix))
	FxGpuCompute.reset()
	FxPluginHost.shutdown()
	quit(0)

func _diff(a: Image, b: Image) -> String:
	if a == null or b == null or a.get_size() != b.get_size():
		return "null/尺寸不符"
	var total := 0.0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) + absf(ca.a - cb.a)
			n += 1
	return "%.5f (%d 点)" % [total / float(n * 4), n]
