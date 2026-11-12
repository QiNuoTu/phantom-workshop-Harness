class_name FxOpsText
extends RefCounted
## 文字节点：外部字体 → Image。参数与 FxTextRaster 一一对应，节点本身不碰字体细节。

static func ops() -> Dictionary:
	return {
		&"image.text": func(ctx, node, d, inputs, params): return text_node(ctx, node, d, inputs, params),
	}


static func text_node(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var font_path := FxPortType.as_string(params.get("font", ""), "")
	var text := FxPortType.as_string(params.get("text", ""), "")
	if text.is_empty():
		return {"image": FxImageUtil.new_canvas(ctx.canvas)}
	var size := clampi(FxPortType.as_int(params.get("size", 24), 24), 4, 256)
	var color := FxPortType.as_color(params.get("color", "#ffffff"), Color.WHITE)
	var align := FxPortType.as_string(params.get("align", "center"), "center")
	var offset := FxPortType.as_vec2(params.get("offset", [0, 0]), Vector2.ZERO)
	var spacing := clampf(FxPortType.as_number(params.get("line_spacing", 1.1), 1.1), 0.5, 4.0)
	var outline := clampi(FxPortType.as_int(params.get("outline", 0), 0), 0, 8)
	var outline_color := FxPortType.as_color(params.get("outline_color", "#000000"), Color.BLACK)
	var alpha := clampf(FxPortType.as_number(params.get("alpha", 1.0), 1.0), 0.0, 1.0)
	var box_width := clampi(FxPortType.as_int(params.get("box_width", 0), 0), 0, 4096)
	if font_path.is_empty():
		ctx.warn("文字节点 %s 还没有选择字体" % String(node.get("id", "")))
		return {"image": FxImageUtil.new_canvas(ctx.canvas)}
	return {
		"image": FxTextRaster.rasterize(font_path, text, size, color, align, offset,
			spacing, outline, outline_color, ctx.canvas, alpha, box_width)
	}
