extends SceneTree
## GUI 探针（必须带显示跑）：验证 GPU 通道真的在显卡上跑了一遍，且结果与 CPU 公式一致。
##   godot --path . --script res://tests/_probe_gpu.gd
##
## 注意：用纯黑白条纹验锐化会「全无变化」（饱和像素被 clamp 回原值），
## 以前只数「改了多少像素」还把「读回上一帧的黑图」误判成成功；这里改用中间调，
## 并同时核对 identity 与手工算出的锐化结果。

func _initialize() -> void:
	print("== GPU 渲染服务器 · 设备 ==")
	print(FxGpuDevice.describe())
	var source := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	for y in range(96):
		for x in range(96):
			var v := 0.35 + 0.25 * sin(float(x) * 0.18) + 0.15 * cos(float(y) * 0.13)
			source.set_pixel(x, y, Color(v, v * 0.8, 1.0 - v, 1.0))
	var identity := FxGpuComposer.compose(source, 0.0)
	var identity_ok := identity.get_pixel(40, 40) == source.get_pixel(40, 40)
	var composed := FxGpuComposer.compose(source, 1.2)
	var changed := 0
	var max_error := 0.0
	if composed != null and composed.get_size() == source.get_size():
		for y in range(1, 95):
			for x in range(1, 95):
				var center := source.get_pixel(x, y)
				var blur := (source.get_pixel(x - 1, y - 1).r
					+ source.get_pixel(x + 1, y - 1).r
					+ source.get_pixel(x - 1, y + 1).r
					+ source.get_pixel(x + 1, y + 1).r) * 0.25
				var expected := clampf(center.r + (center.r - blur) * 1.2, 0.0, 1.0)
				var actual := composed.get_pixel(x, y).r
				max_error = maxf(max_error, absf(expected - actual))
				if absf(center.r - actual) > 0.002:
					changed += 1
	print("IDENTITY_EXACT=", identity_ok, " CHANGED_PIXELS=", changed,
		" MAX_ERROR=", "%.5f" % max_error)
	print("GPU_PASS=", FxGpuDevice.available() and identity_ok and changed > 0 and max_error < 0.01)
	FxGpuCompute.reset()
	FxPluginHost.shutdown()
	quit(0)
