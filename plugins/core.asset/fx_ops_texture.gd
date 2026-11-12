class_name FxOpsTexture
extends RefCounted
## 外部纹理 / 序列帧节点。
##
## 输入是**文件路径**（绝对路径、res:// 或相对资源根），
## 输出是普通 Image —— 下游节点不需要知道它来自 PNG 还是精灵表切片。
## 缩放/适配/偏移都在这里完成，纹理本身由 FxTextureLibrary 缓存。

static func ops() -> Dictionary:
	return {
		&"image.texture": func(ctx, node, d, inputs, params): return texture(ctx, node, d, inputs, params),
		&"image.sheet": func(ctx, node, d, inputs, params): return sheet(ctx, node, d, inputs, params),
	}


static func texture(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var path := FxPortType.as_string(params.get("path", ""), "")
	var source := FxTextureLibrary.image(path)
	if source == null:
		if not path.strip_edges().is_empty():
			ctx.warn("纹理读不到：%s" % path)
		return {"image": FxImageUtil.new_canvas(ctx.canvas)}
	return {"image": _place(ctx, source, params)}


static func sheet(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var path := FxPortType.as_string(params.get("path", ""), "")
	var source := FxTextureLibrary.image(path)
	if source == null:
		if not path.strip_edges().is_empty():
			ctx.warn("精灵表读不到：%s" % path)
		return _sheet_out(FxImageUtil.new_canvas(ctx.canvas), 0, 0, Vector2i.ZERO, {})
	var grid := grid_params(source.get_size(), params)
	var total := int(grid.get("count", 1))
	var start := FxPortType.as_int(params.get("frame", 0), 0)
	var fps := clampf(FxPortType.as_number(params.get("fps", 0.0), 0.0), 0.0, 120.0)
	var loop := FxPortType.as_bool(params.get("loop", true), true)
	# 起始帧 + 时间推进：fps = 0 时只显示起始帧，> 0 时按时间顺序播。
	var index := start
	if fps > 0.0:
		index += int(floor(ctx.t * fps))
	var frame_index := posmod(index, total) if loop else clampi(index, 0, total - 1)
	var cell: Vector2i = grid.get("cell", Vector2i.ZERO)
	var frame := FxTextureLibrary.sheet_frame_at(source, grid, frame_index)
	if frame == null:
		ctx.warn("序列帧切片失败：%s（%d×%d，单元 %d×%d）" % [path,
			int(grid.get("cols", 1)), int(grid.get("rows", 1)), cell.x, cell.y])
		return _sheet_out(FxImageUtil.new_canvas(ctx.canvas), total, frame_index, cell, grid)
	return _sheet_out(_place(ctx, frame, params), total, frame_index, cell, grid)


## 精灵表参数 → 网格描述。mode：grid = 填列/行，size = 填单元像素尺寸。
## margin / spacing 是真实精灵表常见的留白与间隔，不设会切歪。
static func grid_params(size: Vector2i, params: Dictionary) -> Dictionary:
	var mode := FxPortType.as_string(params.get("mode", "grid"), "grid")
	var cell_raw := FxPortType.as_vec2(params.get("cell", [0, 0]), Vector2.ZERO)
	var cell := Vector2i(int(round(cell_raw.x)), int(round(cell_raw.y)))
	return FxTextureLibrary.grid_of(size, mode,
		FxPortType.as_int(params.get("columns", 4), 4),
		FxPortType.as_int(params.get("rows", 1), 1),
		cell,
		FxPortType.as_int(params.get("margin", 0), 0),
		FxPortType.as_int(params.get("spacing", 0), 0))


## 精灵表节点的输出：图像 + 总帧数 / 当前帧号 / 单元尺寸 / 列 / 行。
## 这些是「接下游要用的关键参数」，不是调试信息，所以都做成独立端口。
static func _sheet_out(image: Image, total: int, index: int, cell: Vector2i,
		grid: Dictionary) -> Dictionary:
	return {
		"image": image,
		"count": float(total),
		"index": float(index),
		"cell": Vector2(cell),
		"cols": float(int(grid.get("cols", 1))),
		"rows": float(int(grid.get("rows", 1))),
	}


## 把纹理放到画布上：fit 决定「原始 / 适应 / 铺满 / 拉伸」，再乘 scale 与 offset。
static func _place(ctx: FxEvalContext, source: Image, params: Dictionary) -> Image:
	var canvas := FxImageUtil.new_canvas(ctx.canvas)
	var fit := FxPortType.as_string(params.get("fit", "native"), "native")
	var scale := clampf(FxPortType.as_number(params.get("scale", 1.0), 1.0), 0.01, 32.0)
	var offset := FxPortType.as_vec2(params.get("offset", [0, 0]), Vector2.ZERO)
	var alpha := clampf(FxPortType.as_number(params.get("alpha", 1.0), 1.0), 0.0, 1.0)

	var layer: Image = source.duplicate()
	var src := Vector2(float(layer.get_width()), float(layer.get_height()))
	var target := src
	match fit:
		"contain":
			var k := minf(float(canvas.get_width()) / maxf(src.x, 1.0),
				float(canvas.get_height()) / maxf(src.y, 1.0))
			target = src * k * scale
		"cover":
			var k2 := maxf(float(canvas.get_width()) / maxf(src.x, 1.0),
				float(canvas.get_height()) / maxf(src.y, 1.0))
			target = src * k2 * scale
		"stretch":
			target = Vector2(float(canvas.get_width()), float(canvas.get_height())) * scale
		_:
			target = src * scale
	var pixel_target := Vector2i(maxi(1, int(round(target.x))), maxi(1, int(round(target.y))))
	if pixel_target != layer.get_size():
		layer.resize(pixel_target.x, pixel_target.y, Image.INTERPOLATE_LANCZOS)
	if alpha < 0.999:
		_apply_alpha(layer, alpha)
	var center := Vector2(ctx.canvas) * 0.5 + offset
	var position := Vector2i(int(round(center.x - float(pixel_target.x) * 0.5)),
		int(round(center.y - float(pixel_target.y) * 0.5)))
	FxImageUtil.blend_image(canvas, layer, position, "normal", 1.0)
	return canvas


static func _apply_alpha(image: Image, alpha: float) -> void:
	image.convert(Image.FORMAT_RGBA8)
	var data := image.get_data()
	for i in range(3, data.size(), 4):
		data[i] = int(round(float(data[i]) * alpha))
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data)
