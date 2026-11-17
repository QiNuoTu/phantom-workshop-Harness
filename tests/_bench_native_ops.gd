extends SceneTree
## 本轮新增图元的 GDScript vs 原生内核对比。
##
## 每个算子都走**真实入口**（FxOps* 里的静态函数或公共工具），只切
## `FxNativeBridge.set_enabled()` 这一根开关 —— 这样测出来的就是「换成原生实现」
## 的净收益，不掺别的改动。
##
## 运行：godot --headless --path . --script res://tests/_bench_native_ops.gd

const ROUNDS := 5

var _ctx := FxEvalContext.new()


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	print("== 原生图元基准（%d 次取中位）==" % ROUNDS)
	for size in [Vector2i(192, 108), Vector2i(512, 512)]:
		_ctx.canvas = size
		_ctx.t = 0.4
		var source := _sample(size)
		print("\n-- 画布 %s --" % str(size))
		print("  %-26s %9s %9s %8s" % ["算子", "GDScript", "原生", "倍数"])
		_row("描边 outline", size, func() -> Dictionary:
			return FxOpsComposite.outline(_ctx, {}, null, {"image": source},
				{"color": "#ffb454", "thickness": 2, "mode": "outside", "threshold": 0.1}))
		_row("盒式模糊 blur(3)", size, func() -> Dictionary:
			return FxOpsImage.blur(_ctx, {}, null, {"image": source}, {"radius": 3}))
		_row("色阶 levels", size, func() -> Dictionary:
			return FxOpsImage.levels(_ctx, {}, null, {"image": source},
				{"brightness": 0.1, "contrast": 1.4, "gamma": 0.8}))
		_row("阈值 threshold(luma)", size, func() -> Dictionary:
			return FxOpsImage.threshold(_ctx, {}, null, {"image": source},
				{"cutoff": 0.45, "softness": 0.1, "channel": "luma", "color": "#ffcc66"}))
		_row("反相 invert", size, func() -> Dictionary:
			return FxOpsImage.invert(_ctx, {}, null, {"image": source}, {}))
		_row("渐变映射 ramp", size, func() -> Dictionary:
			return FxOpsColor.ramp(_ctx, {}, null, {"image": source},
				{"shadow": "#101a30", "mid": "#4cc2ff", "highlight": "#ffe6a7",
				"midpoint": 0.4, "amount": 0.8}))
		_row("阴影 shadow", size, func() -> Dictionary:
			return FxOpsComposite.shadow(_ctx, {}, null, {"image": source},
				{"offset": [6.0, 6.0], "color": "#000000aa", "blur": 3, "opacity": 0.6}))
		_row("渐变 gradient(radial)", size, func() -> Dictionary:
			return FxOpsGenerators.gradient(_ctx, {}, null, {},
				{"mode": "radial", "color_a": "#102040", "color_b": "#ffb454"}))
		_row("形状 shape(star)", size, func() -> Dictionary:
			return FxOpsGenerators.shape(_ctx, {}, null, {},
				{"shape": "star", "color": "#ffcc66", "sides": 5}))
		_row("星场 starfield(80)", size, func() -> Dictionary:
			return FxOpsGenerators.starfield(_ctx, {}, null, {}, {"count": 80}))
		_row("块噪声 noise(cell=2)", size, func() -> Dictionary:
			return FxOpsSource.noise(_ctx, {"id": "n"}, null, {},
				{"cell": 2, "density": 0.5, "seed": 1}))
		_row("放射光 rays(12)", size, func() -> Dictionary:
			return FxOpsVfx.rays(_ctx, {}, null, {}, {"count": 12}))
		_row("冲击波 shockwave", size, func() -> Dictionary:
			return FxOpsVfx.shockwave(_ctx, {}, null, {}, {"radius": 0.75}))
		_row("调色板 recolor", size, func() -> Image:
			var copy: Image = source.duplicate()
			FxOpsAsset._recolor(copy, [Color("#101a30"), Color("#4cc2ff"), Color("#ffe6a7")],
				1.0, Color("#ff7a2a"), 0.4, 0.8)
			return copy)
	quit(0)


func _row(label: String, _size: Vector2i, op: Callable) -> void:
	# 预热一次：首次调用包含着色器/线程池/缓存初始化，算进去会失真。
	FxNativeBridge.set_enabled(true)
	op.call()
	FxNativeBridge.set_enabled(false)
	var plain := _median(op)
	FxNativeBridge.set_enabled(true)
	var native := _median(op)
	var times := "%.2f×" % (plain / maxf(native, 0.001))
	print("  %-26s %8.2fms %8.2fms %8s" % [label, plain, native, times])


func _median(op: Callable) -> float:
	var samples: Array[float] = []
	for i in range(ROUNDS):
		var start := Time.get_ticks_usec()
		op.call()
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	samples.sort()
	return samples[samples.size() / 2]


func _sample(size: Vector2i) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in range(size.y):
		for x in range(size.x):
			img.set_pixel(x, y, Color(
				float((x * 7 + y * 3) % 256) / 255.0,
				float((x * 3 + y * 11) % 256) / 255.0,
				float((x * 5 + y * 5) % 256) / 255.0,
				0.25 + 0.75 * float((x + y) % 16) / 15.0))
	return img
