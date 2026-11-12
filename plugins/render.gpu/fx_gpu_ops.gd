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
