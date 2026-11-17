extends SceneTree
## 三条路径的成本对照：纯 GDScript / 原生内核（GDExtension）/ GPU compute。
##
## 必须开窗跑：compute 要真实的 RenderingDevice，`--headless` 是 dummy 驱动。
##   godot --path . --script res://tests/_bench_gpu_ops.gd
##
## 三个开关分别控制一条路径：
##   FxNativeBridge.set_enabled(false)       → 关原生内核算
##   FxSettings.set_value("render.gpu_ops", false) → 关 GPU 算子在位
## 两边都关 = 上一轮优化后的纯 GDScript（含行内并行），作为基线。

const ROUNDS := 5
const SIZES := [Vector2i(192, 108), Vector2i(512, 512)]


func _initialize() -> void:
	print("== 加速路径对照（GPU / 原生内核 / 纯 GDScript）==")
	print("GPU 设备：%s" % FxGpuDevice.state_text())
	print("原生内核：%s" % ("可用" if FxNativeBridge.available() else "不可用（未构建）"))
	if not FxGpuDevice.available():
		print("无图形设备，无法对照 —— 开窗再跑。")
		quit(0)
		return

	for size in SIZES:
		var source := _sample_image(size)
		var ctx := FxEvalContext.new()
		ctx.canvas = size
		ctx.t = 0.5
		print("-- 画布 %dx%d（%d 像素）--" % [size.x, size.y, size.x * size.y])

		_row("泛光 bloom", size, [
			["GDScript", func() -> void: _bloom_once(ctx, source, false, false)],
			["原生内核", func() -> void: _bloom_once(ctx, source, true, false)],
			["GPU", func() -> void: _bloom_once(ctx, source, true, true)],
		])
		_row("色相 hue", size, [
			["GDScript", func() -> void: _hue_once(ctx, source, false, false)],
			["原生内核", func() -> void: _hue_once(ctx, source, true, false)],
			["GPU", func() -> void: _hue_once(ctx, source, true, true)],
		])
		_row("波纹 wave", size, [
			["GDScript", func() -> void: _wave_once(ctx, source, false, false)],
			["原生内核", func() -> void: _wave_once(ctx, source, true, false)],
			["GPU", func() -> void: _wave_once(ctx, source, true, true)],
		])
		_row("变换 transform", size, [
			["GDScript", func() -> void: _transform_once(ctx, source, false)],
			["原生内核", func() -> void: _transform_once(ctx, source, true)],
		])
		_row("遮罩 mask", size, [
			["GDScript", func() -> void: _mask_once(ctx, source, false)],
			["原生内核", func() -> void: _mask_once(ctx, source, true)],
		])
	quit(0)


# ---------------- 单次执行 ----------------

func _apply(native: bool, gpu: bool) -> void:
	FxNativeBridge.set_enabled(native)
	FxSettings.set_value("render.gpu_ops", gpu)


func _bloom_once(ctx: FxEvalContext, source: Image, native: bool, gpu: bool) -> void:
	_apply(native, gpu)
	FxGpuOps.bloom(ctx, {}, null, {"image": source},
		{"threshold": 0.6, "amount": 1.2, "radius": 4})


func _hue_once(ctx: FxEvalContext, source: Image, native: bool, gpu: bool) -> void:
	_apply(native, gpu)
	FxGpuOps.hue(ctx, {}, null, {"image": source},
		{"hue": 45.0, "saturation": 0.15, "value": 0.05})


func _wave_once(ctx: FxEvalContext, source: Image, native: bool, gpu: bool) -> void:
	_apply(native, gpu)
	FxGpuOps.wave(ctx, {}, null, {"image": source},
		{"amplitude": 6.0, "frequency": 0.07, "speed": 2.0, "axis": "y"})


## 变换与遮罩没有 GPU 版（要按坐标重采样 / 要读第二张图），只有原生内核这一档。
func _transform_once(ctx: FxEvalContext, source: Image, native: bool) -> void:
	_apply(native, false)
	FxOpsImage.transform(ctx, {}, null, {"image": source},
		{"offset": [3.0, -2.0], "scale": [0.8, 1.2], "rotation": 17.0,
			"anchor": [0.5, 0.5], "wrap": "clamp"})


func _mask_once(ctx: FxEvalContext, source: Image, native: bool) -> void:
	_apply(native, false)
	FxOpsComposite.mask(ctx, {}, null, {"image": source, "mask": source},
		{"channel": "alpha", "invert": false, "softness": 0.3, "opacity": 0.8})


# ---------------- 计时 ----------------

func _row(label: String, _size: Vector2i, variants: Array) -> void:
	var times: Array[float] = []
	for item in variants:
		var fn: Callable = (item as Array)[1]
		fn.call()   # 预热：shader 编译 / 首次分配不算进结果
		var samples: Array[float] = []
		for i in range(ROUNDS):
			var start := Time.get_ticks_usec()
			fn.call()
			samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
		samples.sort()
		times.append(samples[samples.size() / 2])
	var parts: Array[String] = []
	for i in range(variants.size()):
		parts.append("%s %.2f ms" % [String((variants[i] as Array)[0]), times[i]])
	var line := "  %s：%s" % [label, " · ".join(PackedStringArray(parts))]
	if times.size() >= 2 and times[1] > 0.001:
		line += " → 原生 %.1f×" % (times[0] / times[1])
	if times.size() >= 3 and times[2] > 0.001:
		line += " · GPU %.1f×" % (times[0] / times[2])
	print(line)
	# 恢复默认，别把设置带进下一项。
	FxNativeBridge.set_enabled(true)
	FxSettings.set_value("render.gpu_ops", true)


func _sample_image(size: Vector2i) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in range(size.y):
		for x in range(size.x):
			var fx := float(x) / maxf(float(size.x), 1.0)
			var fy := float(y) / maxf(float(size.y), 1.0)
			img.set_pixel(x, y, Color(fx, fy, 0.5 + 0.5 * sin(fx * 9.0),
				0.4 + 0.6 * fy))
	return img
