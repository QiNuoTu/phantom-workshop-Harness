class_name FxGpuOps
extends RefCounted
## GPU 算子：用同名 op 覆盖 CPU 实现，把最贵的逐像素循环交给 compute shader。
##
## 覆盖是**条件式**的（设备可用 + 设置 render.gpu_ops 打开），
## 与「当前选哪个整帧后端」无关：GPU 是逐算子的加速，不该只有切到
## gpu.standard 才生效。工作线程的预览/预渲染通过 FxGpuCompute.bridged()
## 把整批 compute 提交到渲染线程，主线程则直接执行，各自只做一次同步。
## 无图形设备 / 无头 / 编译失败 / 桥超时一律回落到原 CPU 算子。
##
## 停用 render.gpu 时 FxRegistry 的 LIFO 撤回会自动把 op 表恢复成 CPU 版本。

const MODES: Array[String] = ["normal", "add", "multiply", "screen", "overlay", "subtract"]


## 两重闸门：设备 + 开关。线程不再是限制 —— 工作线程走渲染线程桥。
static func active() -> bool:
	if not FxGpuDevice.available():
		return false
	return bool(FxSettings.typed_value("render.gpu_ops", true))


static func blur(ctx: FxEvalContext, node: Dictionary, def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	if not active():
		return FxOpsImage.blur(ctx, node, def, inputs, params)
	var source: Variant = inputs.get("image")
	if not source is Image:
		return FxOpsImage.blur(ctx, node, def, inputs, params)
	var image := source as Image
	var max_radius := clampi(ctx.int_option("max_blur_radius", 32), 1, 128)
	var radius := clampi(FxPortType.as_int(params.get("radius", 2), 2), 0, max_radius)
	if radius <= 0:
		return {"image": image.duplicate()}
	var out := FxGpuCompute.blur_bridged(image, radius)
	if out == null:
		return FxOpsImage.blur(ctx, node, def, inputs, params)
	return {"image": out}


static func mix(ctx: FxEvalContext, node: Dictionary, def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	if not active():
		return FxOpsImage.mix(ctx, node, def, inputs, params)
	var base: Variant = inputs.get("a")
	var top: Variant = inputs.get("b")
	if not (base is Image) or not (top is Image):
		return FxOpsImage.mix(ctx, node, def, inputs, params)
	# CPU 的 blend_rect 是按像素坐标叠放；两张图尺寸不同时语义不同，交给 CPU。
	if (base as Image).get_size() != (top as Image).get_size():
		return FxOpsImage.mix(ctx, node, def, inputs, params)
	var mode := FxPortType.as_string(params.get("mode", "normal"), "normal")
	var mode_id := MODES.find(mode)
	if mode_id < 0:
		return FxOpsImage.mix(ctx, node, def, inputs, params)
	var amount := clampf(FxPortType.as_number(params.get("amount", 1.0), 1.0), 0.0, 1.0)
	var out := FxGpuCompute.mix_bridged(base as Image, top as Image, amount, mode_id)
	if out == null:
		return FxOpsImage.mix(ctx, node, def, inputs, params)
	return {"image": out}


## 泛光：阈值趟 + 叠加趟在 GPU 上，中间两次缩放仍交给引擎（本来就是 C++）。
## 与 CPU 版逐字节可能差 1 LSB（浮点顺序不同），但它跑出来的是**唯一结果**：
## 缓存里存的就是 GPU 这一帧，不存在「同一帧两套像素」。
static func bloom(ctx: FxEvalContext, node: Dictionary, def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	if not active():
		return FxOpsComposite.bloom(ctx, node, def, inputs, params)
	var source: Variant = inputs.get("image")
	if not source is Image:
		return FxOpsComposite.bloom(ctx, node, def, inputs, params)
	var threshold := clampf(FxPortType.as_number(params.get("threshold", 0.7), 0.7), 0.0, 1.0)
	var amount := clampf(FxPortType.as_number(params.get("amount", 0.8), 0.8), 0.0, 3.0)
	var radius := clampi(FxPortType.as_int(params.get("radius", 4), 4), 1, 32)
	var out := FxGpuCompute.bloom_bridged(source as Image, threshold, amount, radius)
	if out == null:
		return FxOpsComposite.bloom(ctx, node, def, inputs, params)
	return {"image": out}


## 色相/饱和/明度：整张图逐像素查表，最典型的 GPU 活。
static func hue(ctx: FxEvalContext, node: Dictionary, def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	if not active():
		return FxOpsColor.hue(ctx, node, def, inputs, params)
	var source: Variant = inputs.get("image")
	if not source is Image:
		return FxOpsColor.hue(ctx, node, def, inputs, params)
	var shift := FxPortType.as_number(params.get("hue", 0.0), 0.0) / 360.0
	var sat := FxPortType.as_number(params.get("saturation", 0.0), 0.0)
	var val := FxPortType.as_number(params.get("value", 0.0), 0.0)
	var out := FxGpuCompute.hue_bridged(source as Image, shift, sat, val)
	if out == null:
		return FxOpsColor.hue(ctx, node, def, inputs, params)
	return {"image": out}


## 波纹位移：每个像素做一次 sin + 双线性采样，GPU 上几乎免费。
static func wave(ctx: FxEvalContext, node: Dictionary, def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	if not active():
		return FxOpsDistort.wave(ctx, node, def, inputs, params)
	var source: Variant = inputs.get("image")
	if not source is Image:
		return FxOpsDistort.wave(ctx, node, def, inputs, params)
	var amplitude := FxPortType.as_number(params.get("amplitude", 8.0), 8.0)
	var frequency := FxPortType.as_number(params.get("frequency", 0.08), 0.08)
	var speed := FxPortType.as_number(params.get("speed", 2.0), 2.0)
	var axis := FxPortType.as_string(params.get("axis", "y"), "y")
	var axis_mode := 0 if axis == "x" else (1 if axis == "both" else 2)
	var out := FxGpuCompute.wave_bridged(source as Image, amplitude,
		frequency * TAU, ctx.t * speed, axis_mode)
	if out == null:
		return FxOpsDistort.wave(ctx, node, def, inputs, params)
	return {"image": out}


## 描边（真实工程里最贵的单算子之一）：8 邻域 alpha 比较全在 GPU 上并行。
static func outline(ctx: FxEvalContext, node: Dictionary, def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	if not active():
		return FxOpsComposite.outline(ctx, node, def, inputs, params)
	var source: Variant = inputs.get("image")
	if not source is Image:
		return FxOpsComposite.outline(ctx, node, def, inputs, params)
	var color := FxPortType.as_color(params.get("color", "#ffb454"), Color(1, 0.7, 0.33))
	var thickness := clampi(FxPortType.as_int(params.get("thickness", 2), 2), 1, 16)
	var mode := FxPortType.as_string(params.get("mode", "outside"), "outside")
	var threshold := FxPortType.as_number(params.get("threshold", 0.1), 0.1)
	var out := FxGpuCompute.outline_bridged(source as Image, thickness,
		mode == "inside", threshold, color)
	if out == null:
		return FxOpsComposite.outline(ctx, node, def, inputs, params)
	return {"image": out}
