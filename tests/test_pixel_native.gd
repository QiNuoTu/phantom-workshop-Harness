extends SceneTree
## 像素内核扩展（GDExtension）自测。
##
## 这套测试只回答一个问题：**原生路径算出来的字节，和 GDScript 路径一模一样吗**。
## 做法是把 `FxNativeBridge.set_enabled(false/true)` 各跑一遍同一算子，再比 `get_data()`。
## 比的是真实现 —— 不是我在测试里另写一份参考实现（那样只能证明两份代码不同，
## 证明不了谁对）。
##
## 扩展没构建好时整套**跳过**并退出 0：它是可选加速层，缺席不该让回归变红，
## 但缺席这件事必须打印出来，不能静默降级。
##
## 运行：godot --headless --path . --script res://tests/test_pixel_native.gd

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	print("== 像素内核扩展自测 ==")
	if not FxNativeBridge.available():
		print("  跳过：原生内核不可用（未构建 / 加载失败 / 插件停用 / FX_NATIVE=0）")
		print("  构建：bash plugins/pixels.native/build.sh template_debug")
		print("  结果：0 条断言")
		quit(0)
		return

	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(37, 23)
	ctx.t = 0.4
	var source := _sample_image(ctx.canvas)

	_test_hue(ctx, source)
	_test_tint(ctx, source)
	_test_transform(ctx, source)
	_test_bloom(ctx, source)
	_test_mask(ctx, source)
	_test_wave(ctx, source)
	_test_blend(source)
	_test_outline(ctx, source)
	_test_box_blur(ctx, source)
	_test_levels(ctx, source)
	_test_threshold(ctx, source)
	_test_ramp(ctx, source)
	_test_invert(ctx, source)
	_test_shadow(ctx, source)
	_test_recolor(source)
	_test_recipe()
	_test_generators(ctx)
	_test_stats()

	print("  结果：%d 条断言 · %s" % [checks,
		"全部通过" if failures.is_empty() else "%d 条失败" % failures.size()])
	for item in failures:
		print("    FAIL: %s" % item)
	quit(0 if failures.is_empty() else 1)


# ---------------- 各算子 ----------------

## 色相是唯一允许 ±1 的算子：HSV 往返在 float 里做（引擎 Color 的位宽），
## 双精度与单精度在 `int(x*255+0.5)` 的边界上会翻一格。实测 7844 个字节里约 7 个
## 差 1（0.1%），肉眼不可见；如果哪天变成几十，那就是公式错了，不是精度。
## 其余的算子都要求**逐字节**一致 —— 放宽会掩盖真 bug。
func _test_hue(ctx: FxEvalContext, source: Image) -> void:
	_compare("色相 +60°", func() -> Dictionary:
		return FxOpsColor.hue(ctx, {}, null, {"image": source},
			{"hue": 60.0, "saturation": 0.0, "value": 0.0}), 1)
	_compare("色相 −200° + 饱和 0.3", func() -> Dictionary:
		return FxOpsColor.hue(ctx, {}, null, {"image": source},
			{"hue": -200.0, "saturation": 0.3, "value": 0.0}), 1)
	_compare("明度 −0.25（暗一档）", func() -> Dictionary:
		return FxOpsColor.hue(ctx, {}, null, {"image": source},
			{"hue": 0.0, "saturation": 0.0, "value": -0.25}), 1)


func _test_tint(ctx: FxEvalContext, source: Image) -> void:
	_compare("着色 0.6", func() -> Dictionary:
		return FxOpsImage.tint(ctx, {}, null, {"image": source},
			{"color": "#ff7a2a", "amount": 0.6, "preserve_luma": false}))
	_compare("着色 + 保亮度", func() -> Dictionary:
		return FxOpsImage.tint(ctx, {}, null, {"image": source},
			{"color": "#3fa9ff", "amount": 1.0, "preserve_luma": true}))


func _test_transform(ctx: FxEvalContext, source: Image) -> void:
	for wrap in ["transparent", "clamp", "repeat"]:
		_compare("变换（旋转 17° · 缩放 0.8/1.2 · wrap=%s）" % wrap,
			func() -> Dictionary:
				return FxOpsImage.transform(ctx, {}, null, {"image": source}, {
					"offset": [3.0, -2.0], "scale": [0.8, 1.2], "rotation": 17.0,
					"anchor": [0.5, 0.5], "wrap": wrap,
				}))


func _test_bloom(ctx: FxEvalContext, source: Image) -> void:
	_compare("泛光（阈值 0.6 · 强度 1.3 · 半径 4）", func() -> Dictionary:
		return FxOpsComposite.bloom(ctx, {}, null, {"image": source},
			{"threshold": 0.6, "amount": 1.3, "radius": 4}))


func _test_mask(ctx: FxEvalContext, source: Image) -> void:
	var mask_image := _sample_image(ctx.canvas)
	for channel in ["alpha", "luma"]:
		_compare("遮罩（%s · 反相 · 柔化 0.4 · 不透明度 0.8）" % channel,
			func() -> Dictionary:
				return FxOpsComposite.mask(ctx, {}, null,
					{"image": source, "mask": mask_image},
					{"channel": channel, "invert": true, "softness": 0.4, "opacity": 0.8}))


func _test_wave(ctx: FxEvalContext, source: Image) -> void:
	for axis in ["x", "y", "both"]:
		_compare("波纹（轴向 %s）" % axis, func() -> Dictionary:
			return FxOpsDistort.wave(ctx, {}, null, {"image": source},
				{"amplitude": 6.0, "frequency": 0.07, "speed": 2.0, "axis": axis}))


func _test_blend(source: Image) -> void:
	# 六种混合模式逐一对一遍：这是全管线最核心的原语（每层合成、阴影、遮罩、
	# 文字都走它），出错的代价最大。
	for mode in ["add", "multiply", "screen", "overlay", "subtract"]:
		var base := FxImageUtil.new_canvas(Vector2i(41, 29))
		base.fill(Color(0.2, 0.3, 0.4, 1.0))
		var canvas := FxImageUtil.new_canvas(Vector2i(41, 29))
		FxNativeBridge.set_enabled(false)
		canvas.fill(Color(0.2, 0.3, 0.4, 1.0))
		FxImageUtil.blend_image(canvas, source, Vector2(2, 3), mode, 0.7)
		var without := canvas.get_data()
		FxNativeBridge.set_enabled(true)
		FxImageUtil.blend_image(base, source, Vector2(2, 3), mode, 0.7)
		var with_native := base.get_data()
		_check(without == with_native, "混合模式 %s：与 GDScript 逐字节一致" % mode)


func _test_outline(ctx: FxEvalContext, source: Image) -> void:
	for mode in ["outside", "inside"]:
		_compare("描边（%s · 半径 2）" % mode, func() -> Dictionary:
			return FxOpsComposite.outline(ctx, {}, null, {"image": source},
				{"color": "#ffb454", "thickness": 2, "mode": mode, "threshold": 0.1}))
	_compare("描边（半径 5 · 阈值 0.4）", func() -> Dictionary:
		return FxOpsComposite.outline(ctx, {}, null, {"image": source},
			{"color": "#3fa9ff", "thickness": 5, "mode": "outside", "threshold": 0.4}))


## 精确路径的盒式模糊。两趟都把中间结果量化回字节，所以这里没有容差余地。
func _test_box_blur(ctx: FxEvalContext, source: Image) -> void:
	# ctx.quality=1 且 operator_quality=1.0 → blur 走精确（_box_blur）路径。
	for radius in [1, 3, 8]:
		_compare("盒式模糊（半径 %d）" % radius, func() -> Dictionary:
			return FxOpsImage.blur(ctx, {}, null, {"image": source}, {"radius": radius}))


func _test_levels(ctx: FxEvalContext, source: Image) -> void:
	_compare("色阶（亮度 0.1 · 对比 1.4 · 伽马 0.8）", func() -> Dictionary:
		return FxOpsImage.levels(ctx, {}, null, {"image": source},
			{"brightness": 0.1, "contrast": 1.4, "gamma": 0.8}))


func _test_threshold(ctx: FxEvalContext, source: Image) -> void:
	for channel in ["alpha", "luma"]:
		_compare("阈值（%s · 柔化 0.1）" % channel, func() -> Dictionary:
			return FxOpsImage.threshold(ctx, {}, null, {"image": source},
				{"cutoff": 0.45, "softness": 0.1, "channel": channel, "color": "#ffcc66"}))
	_compare("阈值（硬边 · alpha）", func() -> Dictionary:
		return FxOpsImage.threshold(ctx, {}, null, {"image": source},
			{"cutoff": 0.5, "softness": 0.0, "channel": "alpha", "color": "#ffffff"}))


func _test_ramp(ctx: FxEvalContext, source: Image) -> void:
	_compare("渐变映射（中点 0.4 · 强度 0.8）", func() -> Dictionary:
		return FxOpsColor.ramp(ctx, {}, null, {"image": source}, {
			"shadow": "#101a30", "mid": "#4cc2ff", "highlight": "#ffe6a7",
			"midpoint": 0.4, "amount": 0.8,
		}))


func _test_invert(ctx: FxEvalContext, source: Image) -> void:
	_compare("反相", func() -> Dictionary:
		return FxOpsImage.invert(ctx, {}, null, {"image": source}, {}))


## 阴影是「alpha 着色层 → 引擎缩放模糊 → 平移 → 叠回」，
## 只有第一段是逐像素脚本循环，剩下的交给引擎 C++。
func _test_shadow(ctx: FxEvalContext, source: Image) -> void:
	for blur in [0, 3]:
		_compare("阴影（模糊 %d · 偏移 6,6）" % blur, func() -> Dictionary:
			return FxOpsComposite.shadow(ctx, {}, null, {"image": source},
				{"offset": [6.0, 6.0], "color": "#000000aa", "blur": blur, "opacity": 0.6}))


## 生成器没有输入图：比的是同一组参数下的整张输出。
## pixelfx 的调色板重映射（就地改写，所以两份副本各跑一边再比）。
func _test_recolor(source: Image) -> void:
	var palette: Array[Color] = [Color("#101a30"), Color("#4cc2ff"), Color("#ffe6a7")]
	for amount in [1.0, 0.5]:
		FxNativeBridge.set_enabled(false)
		var plain: Image = source.duplicate()
		FxOpsAsset._recolor(plain, palette, amount, Color("#ff7a2a"), 0.4, 0.8)
		FxNativeBridge.set_enabled(true)
		var native: Image = source.duplicate()
		FxOpsAsset._recolor(native, palette, amount, Color("#ff7a2a"), 0.4, 0.8)
		_check(plain.get_data() == native.get_data(),
			"调色板重映射（强度 %.1f）：与 GDScript 逐字节一致" % amount)


## 配方引擎里有两段逐像素脚本：收尾合成（颜色缓冲 + 加性光）与色差后处理。
## 用一个最小配方跑两次 render()，比的是**同一个引擎实例**的两种路径。
func _test_recipe() -> void:
	var recipe := {
		"width": 43, "height": 31, "duration": 1.0, "fps": 30, "loop": true, "seed": 7,
		"palette": ["#101820", "#ff7a2a", "#ffe6a7"],
		"layers": [
			{"type": "ring", "t0": 0.0, "life": 0.7, "radius": [4.0, 22.0], "width": 2.0},
			{"type": "flash", "t0": 0.0, "life": 0.4},
		],
		"post": {"mode": "chromatic", "amount": 1.0, "chroma_px": 2.0},
	}
	var engine := VfxEngine.new()
	engine.configure(recipe, {})
	FxNativeBridge.set_enabled(false)
	var plain: Image = engine.render(0.25)
	FxNativeBridge.set_enabled(true)
	var native: Image = engine.render(0.25)
	_check(plain.get_data() == native.get_data(),
		"配方渲染（合成 + 色差）：与 GDScript 逐字节一致")


func _test_generators(ctx: FxEvalContext) -> void:
	for mode in ["linear", "radial", "angle"]:
		_compare("渐变（%s）" % mode, func() -> Dictionary:
			return FxOpsGenerators.gradient(ctx, {}, null, {},
				{"mode": mode, "color_a": "#102040", "color_b": "#ffb454",
				"angle": 32.0, "scale": 1.2, "softness": 0.2}))
	for kind in ["circle", "ring", "rect", "diamond", "triangle", "star"]:
		_compare("形状（%s）" % kind, func() -> Dictionary:
			return FxOpsGenerators.shape(ctx, {}, null, {},
				{"shape": kind, "color": "#ffcc66", "background": "#00000000",
				"size": 0.6, "feather": 0.02, "sides": 5, "rotation": 18.0}))
	# 噪声走 FxMath.h01（int64 环绕 + 算术右移），是唯一一处依赖整数哈希的图元。
	for cell in [2, 5]:
		_compare("噪声（格 %d 像素）" % cell, func() -> Dictionary:
			return FxOpsSource.noise(ctx, {"id": "n"}, null, {},
				{"cell": cell, "density": 0.5, "color_a": "#101018", "color_b": "#f0f0f0",
				"seed": 1}))
	_compare("放射光（12 条 · t=0.4）", func() -> Dictionary:
		return FxOpsVfx.rays(ctx, {}, null, {},
			{"count": 12, "length": 0.9, "width": 0.12, "speed": 0.5, "intensity": 1.0}))
	_compare("冲击波（t=0.4）", func() -> Dictionary:
		return FxOpsVfx.shockwave(ctx, {}, null, {},
			{"radius": 0.75, "width": 0.08, "speed": 1.0, "intensity": 1.0}))
	# 星场走的是稀疏光点叠加（paint_blobs），重叠处要按顺序累积。
	_compare("星场（80 颗 · 带辉光）", func() -> Dictionary:
		return FxOpsGenerators.starfield(ctx, {}, null, {},
			{"count": 80, "seed": 3, "size": 1.4, "glow": 2.5}))
	_compare("火花（48 粒 · t=0.4）", func() -> Dictionary:
		return FxOpsVfx.sparks(ctx, {}, null, {},
			{"count": 48, "speed": 0.6, "gravity": 0.5, "size": 1.6, "life": 1.0}))


func _test_stats() -> void:
	var data := FxNativeBridge.stats()
	_check(bool(data.get("available", false)), "扩展实例可用")
	_check(int(data.get("calls", 0)) > 0,
		"调用计数在涨（%d 次）" % int(data.get("calls", 0)))
	_check(int(data.get("misses", 0)) == 0,
		"没有静默回落（misses=%d）" % int(data.get("misses", 0)))


# ---------------- 工具 ----------------

## 关键：两边跑的是**同一段算子代码**，只差 bridge 的开关。
## `tolerance` 默认为 0（逐字节），只有色相用 1（见 _test_hue 的说明）。
func _compare(label: String, op: Callable, tolerance: int = 0) -> void:
	FxNativeBridge.set_enabled(false)
	var without: Variant = (op.call() as Dictionary).get("image")
	FxNativeBridge.set_enabled(true)
	var with_native: Variant = (op.call() as Dictionary).get("image")
	if not (without is Image) or not (with_native is Image):
		_check(false, "%s：两侧都要产出图" % label)
		return
	var a := without as Image
	var b := with_native as Image
	_check(a.get_size() == b.get_size(), "%s：尺寸一致" % label)
	if tolerance <= 0:
		_check(a.get_data() == b.get_data(), "%s：与 GDScript 逐字节一致" % label)
	else:
		var da := a.get_data()
		var db := b.get_data()
		var worst := 0
		for i in range(da.size()):
			worst = maxi(worst, absi(int(da[i]) - int(db[i])))
		_check(worst <= tolerance,
			"%s：与 GDScript 的差 ≤ %d（实测最大 %d）" % [label, tolerance, worst])


func _sample_image(size: Vector2i) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in range(size.y):
		for x in range(size.x):
			img.set_pixel(x, y, Color(
				float((x * 7 + y * 3) % 256) / 255.0,
				float((x * 3 + y * 11) % 256) / 255.0,
				float((x * 5 + y * 5) % 256) / 255.0,
				0.25 + 0.75 * float((x + y) % 16) / 15.0))
	return img


func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  ok  %s" % label)
	else:
		print("  FAIL: %s" % label)
		failures.append(label)
