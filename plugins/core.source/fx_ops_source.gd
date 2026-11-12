class_name FxOpsSource
extends RefCounted
## 图像来源算子：纯色、棋盘、噪声、图片文件。
##
## 每个算子只拿 (ctx, node, def, inputs, params)：
##   · 不认识上游是谁，也不认识下游；
##   · 输出尺寸统一由 ctx.canvas 决定，画布改了不用改算子。

static func ops() -> Dictionary:
	return {
		&"image.solid": func(ctx, node, d, inputs, params): return solid(ctx, node, d, inputs, params),
		&"image.checker": func(ctx, node, d, inputs, params): return checker(ctx, node, d, inputs, params),
		&"image.noise": func(ctx, node, d, inputs, params): return noise(ctx, node, d, inputs, params),
		&"image.file": func(ctx, node, d, inputs, params): return file_image(ctx, node, d, inputs, params),
	}


static func solid(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var color := FxPortType.as_color(params.get("color", "#202636"), Color(0.12, 0.15, 0.21))
	return {"image": FxImageUtil.new_canvas(ctx.canvas, color)}


static func checker(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var cell := clampi(FxPortType.as_int(params.get("cell", 8), 8), 1, 512)
	var color_a := FxPortType.as_color(params.get("color_a", "#1b1f2a"), Color(0.1, 0.12, 0.16))
	var color_b := FxPortType.as_color(params.get("color_b", "#2f3746"), Color(0.18, 0.22, 0.27))
	var offset := FxPortType.as_vec2(params.get("offset", [0, 0]), Vector2.ZERO)
	var image := FxImageUtil.new_canvas(ctx.canvas)
	var width := ctx.canvas.x
	var height := ctx.canvas.y
	for y in range(0, height, cell):
		for x in range(0, width, cell):
			var cx := int(floor((float(x) + offset.x) / float(cell)))
			var cy := int(floor((float(y) + offset.y) / float(cell)))
			var color := color_b if (cx + cy) % 2 == 0 else color_a
			image.fill_rect(Rect2i(x, y, mini(cell, width - x), mini(cell, height - y)), color)
	return {"image": image}


static func noise(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var cell := clampi(FxPortType.as_int(params.get("cell", 2), 2), 1, 128)
	var density := clampf(FxPortType.as_number(params.get("density", 0.5), 0.5), 0.0, 1.0)
	var color_a := FxPortType.as_color(params.get("color_a", "#101018"), Color(0.06, 0.06, 0.09))
	var color_b := FxPortType.as_color(params.get("color_b", "#f0f0f0"), Color(0.94, 0.94, 0.94))
	var seed_offset := FxPortType.as_int(params.get("seed", 1), 1) + ctx.node_seed(String(node.get("id", "")))
	var image := FxImageUtil.new_canvas(ctx.canvas)
	var width := ctx.canvas.x
	var height := ctx.canvas.y
	for y in range(0, height, cell):
		for x in range(0, width, cell):
			var bx := int(float(x) / float(cell))
			var by := int(float(y) / float(cell))
			var r := FxMath.h01(bx + seed_offset * 131, by + seed_offset * 17)
			var color := color_b if r < density else color_a
			image.fill_rect(Rect2i(x, y, mini(cell, width - x), mini(cell, height - y)), color)
	return {"image": image}


static func file_image(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var path := FxPortType.as_string(params.get("path", ""), "")
	var fit := FxPortType.as_string(params.get("fit", "contain"), "contain")
	var background := FxPortType.as_color(params.get("background", "#00000000"), Color(0, 0, 0, 0))
	var canvas := FxImageUtil.new_canvas(ctx.canvas, background)
	var source := ctx.load_image(path)
	if source == null:
		return {"image": canvas}
	var fitted := FxImageUtil.fit_image(source, ctx.canvas, fit)
	FxImageUtil.blend_image(canvas, fitted, Vector2.ZERO, "normal", 1.0)
	return {"image": canvas}
