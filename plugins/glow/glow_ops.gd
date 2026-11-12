class_name FxGlowOps
extends RefCounted
## 示例插件的算子实现。
##
## 必须是**静态**函数：插件宿主只接受未绑定实例的 Callable，
## 这样静态注册表不会把插件对象留到引擎关闭阶段（headless 下会段错误）。

static func apply(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source: Variant = inputs.get("image")
	if not source is Image:
		return {"image": FxImageUtil.new_canvas(ctx.canvas)}
	var radius := clampi(int(params.get("radius", 4)), 1, 32)
	var amount := clampf(float(params.get("amount", 0.6)), 0.0, 1.0)
	var image := source as Image
	var out: Image = image.duplicate()
	# 快速模糊：缩到 1/(radius*0.9) 再放大，双向双线性（引擎 C++）。
	var factor := clampf(float(radius) * 0.9, 1.35, 12.0)
	var small := image.duplicate()
	small.resize(maxi(1, int(round(float(image.get_width()) / factor))),
		maxi(1, int(round(float(image.get_height()) / factor))), Image.INTERPOLATE_BILINEAR)
	small.resize(image.get_width(), image.get_height(), Image.INTERPOLATE_BILINEAR)
	FxImageUtil.blend_image(out, small, Vector2.ZERO, "screen", amount)
	return {"image": out}
