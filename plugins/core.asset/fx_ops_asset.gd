class_name FxOpsAsset
extends RefCounted
## pixelfx 序列帧节点：把 244 套手绘特效当成“会动的图像源”接进蓝图。
##
## 支持 pixelfx 的核心选项：帧率/循环/帧偏移/速度、缩放/旋转/镜像/轴心、
## 调色板 ramp 重映射、染色与透明度。输出仍是普通 Image，下游不需要知道它是序列帧。
##
## 不缓存整张 sheet 到节点里：FxAssetLibrary 做 LRU，节点每次只取当前帧的 region。

static func ops() -> Dictionary:
	return {
		&"image.pixelfx": func(ctx, node, d, inputs, params): return pixelfx(ctx, node, d, inputs, params),
	}


static func pixelfx(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var canvas := FxImageUtil.new_canvas(ctx.canvas)
	var asset_id := FxPortType.as_string(params.get("asset", ""), "")
	if asset_id.is_empty():
		ctx.warn("pixelfx 节点 %s 还没有选择素材" % String(node.get("id", "")))
		return {"image": canvas}
	if not FxAssetLibrary.has(asset_id):
		ctx.warn("素材不存在：%s" % asset_id)
		return {"image": canvas}

	var entry := FxAssetLibrary.entry(asset_id)
	var asset_fps := int(entry.get("fps", 30))
	var fps := FxPortType.as_int(params.get("fps", 0), 0)
	if fps <= 0:
		fps = asset_fps
	fps = clampi(fps, 1, 120)
	var speed := clampf(FxPortType.as_number(params.get("speed", 1.0), 1.0), -8.0, 8.0)
	var frame_offset := FxPortType.as_int(params.get("frame", 0), 0)
	var use_loop := FxPortType.as_bool(params.get("loop", true), true)
	var frame := int(floor(ctx.t * float(fps) * speed)) + frame_offset
	var sprite := FxAssetLibrary.frame_image(asset_id, frame, use_loop)
	if sprite == null:
		ctx.warn("素材取帧失败：%s" % asset_id)
		return {"image": canvas}

	var scale := maxf(0.01, FxPortType.as_number(params.get("scale", 1.0), 1.0))
	var offset := FxPortType.as_vec2(params.get("offset", [0, 0]), Vector2.ZERO)
	var angle := deg_to_rad(FxPortType.as_number(params.get("angle", 0.0), 0.0))
	var flip := FxPortType.as_bool(params.get("flip", false), false)
	var alpha := clampf(FxPortType.as_number(params.get("alpha", 1.0), 1.0), 0.0, 1.0)
	var tint := FxPortType.as_color(params.get("tint", "#ffffff"), Color.WHITE)
	var tint_amount := clampf(FxPortType.as_number(params.get("tint_amount", 0.0), 0.0), 0.0, 1.0)
	var palette := _parse_palette(FxPortType.as_string(params.get("palette", ""), ""))
	var palette_amount := clampf(FxPortType.as_number(params.get("palette_amount", 1.0), 1.0), 0.0, 1.0)

	var sprite_size := Vector2(float(sprite.get_width()), float(sprite.get_height()))
	var pivot := Vector2.ZERO
	var entry_pivot: Variant = entry.get("pivot", null)
	if entry_pivot is Vector2i:
		pivot = Vector2(entry_pivot)
	elif entry_pivot is Array and (entry_pivot as Array).size() >= 2:
		pivot = Vector2(float((entry_pivot as Array)[0]), float((entry_pivot as Array)[1]))
	else:
		pivot = sprite_size * 0.5
	var center := Vector2(ctx.canvas) * 0.5 + offset

	# 快路径：不旋转/不镜像。缩放交给引擎的 Image.resize（C++），
	# 调色/染色只处理这张小图，再用 blend_rect 一次贴到画布。
	if absf(angle) < 0.000001 and not flip:
		var target := Vector2i(maxi(1, int(round(sprite_size.x * scale))),
			maxi(1, int(round(sprite_size.y * scale))))
		var layer: Image = sprite.duplicate()
		if target != sprite.get_size():
			layer.resize(target.x, target.y, Image.INTERPOLATE_NEAREST)
		_recolor(layer, palette, palette_amount, tint, tint_amount, alpha)
		FxImageUtil.blend_image(canvas, layer, center - pivot * scale, "normal", 1.0)
		return {"image": canvas}

	var cos_a := cos(-angle)
	var sin_a := sin(-angle)
	# 只遍历变换后的包围盒，而不是整张画布。
	var corners := [
		Vector2(0, 0), Vector2(sprite_size.x, 0),
		Vector2(0, sprite_size.y), sprite_size,
	]
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for corner in corners:
		var local := (Vector2(corner) - pivot) * scale
		var rx0 := local.x * cos_a - local.y * sin_a
		var ry0 := local.x * sin_a + local.y * cos_a
		min_p = Vector2(minf(min_p.x, rx0), minf(min_p.y, ry0))
		max_p = Vector2(maxf(max_p.x, rx0), maxf(max_p.y, ry0))
	var box_pos := Vector2i(floori(center.x + min_p.x) - 1, floori(center.y + min_p.y) - 1)
	var box_end := Vector2i(ceili(center.x + max_p.x) + 1, ceili(center.y + max_p.y) + 1)
	box_pos.x = clampi(box_pos.x, 0, ctx.canvas.x - 1)
	box_pos.y = clampi(box_pos.y, 0, ctx.canvas.y - 1)
	box_end.x = clampi(box_end.x, 0, ctx.canvas.x)
	box_end.y = clampi(box_end.y, 0, ctx.canvas.y)
	for y in range(box_pos.y, box_end.y):
		for x in range(box_pos.x, box_end.x):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5) - center
			var rx := p.x * cos_a - p.y * sin_a
			var ry := p.x * sin_a + p.y * cos_a
			rx /= scale
			ry /= scale
			var sx := int(floor(rx + pivot.x))
			var sy := int(floor(ry + pivot.y))
			if sx < 0 or sy < 0 or sx >= sprite.get_width() or sy >= sprite.get_height():
				continue
			var color := sprite.get_pixel(sx, sy)
			if color.a <= 0.004:
				continue
			color = _recolor_pixel(color, palette, palette_amount, tint, tint_amount, alpha)
			canvas.set_pixel(x, y, color)
	return {"image": canvas}


## 对整张小图做调色板重映射 / 染色 / 透明度，字节级处理。
static func _recolor(image: Image, palette: Array, palette_amount: float,
		tint: Color, tint_amount: float, alpha: float) -> void:
	var needs_palette := palette.size() >= 2 and palette_amount > 0.0
	var needs_tint := tint_amount > 0.0
	var needs_alpha := alpha < 0.999
	if not needs_palette and not needs_tint and not needs_alpha:
		return
	FxImageUtil._ensure_rgba(image)
	var data := image.get_data()
	for i in range(0, data.size(), 4):
		var a := data[i + 3]
		if a == 0:
			continue
		var r := float(data[i]) / 255.0
		var g := float(data[i + 1]) / 255.0
		var b := float(data[i + 2]) / 255.0
		var c := Color(r, g, b, float(a) / 255.0)
		c = _recolor_pixel(c, palette, palette_amount, tint, tint_amount, alpha)
		data[i] = int(round(c.r * 255.0))
		data[i + 1] = int(round(c.g * 255.0))
		data[i + 2] = int(round(c.b * 255.0))
		data[i + 3] = int(round(c.a * 255.0))
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data)


static func _recolor_pixel(color: Color, palette: Array, palette_amount: float,
		tint: Color, tint_amount: float, alpha: float) -> Color:
	if palette.size() >= 2 and palette_amount > 0.0:
		var l := clampf(FxImageUtil.luma(color), 0.0, 1.0)
		var index := clampi(int(round(l * float(palette.size() - 1))), 0, palette.size() - 1)
		var target: Color = palette[index]
		color = color.lerp(Color(target.r, target.g, target.b, color.a), palette_amount)
	if tint_amount > 0.0:
		color = color.lerp(Color(color.r * tint.r, color.g * tint.g, color.b * tint.b, color.a), tint_amount)
	color.a *= alpha
	return color


static func _parse_palette(text: String) -> Array[Color]:
	var out: Array[Color] = []
	for part in text.split(",", false):
		var token := part.strip_edges()
		if token.is_empty():
			continue
		if not token.begins_with("#"):
			token = "#" + token
		var parsed := Color.from_string(token, Color(-1, -1, -1, -1))
		if parsed.r >= 0.0:
			out.append(parsed)
	return out
