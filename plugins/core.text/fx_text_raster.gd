class_name FxTextRaster
extends RefCounted
## 外部字体 → Image 的同步栅格化。
##
## 为什么不用 SubViewport + Label：执行器是同步纯函数（任意 t 可直接求值），
## 等一帧再取纹理会把“求值”变成异步，预览、导出、单测都会分叉。
## 这里直接用 TextServer 整形，取 FontFile 的字形图集，按字形 alpha 逐点落色。
##
## 支持：多行、左/中/右对齐、行距、描边、整体偏移、任意外部字体。
## 不支持：复杂脚本的连字/双向排版（TextServer 的 glyph 位置仍然正确，但本实现按行 LTR 排）。

const CACHE_LIMIT := 24

static var _cache: Dictionary = {}
static var _order: Array[String] = []


static func rasterize(font_path: String, text: String, font_size: int, color: Color,
		align: String = "center", offset: Vector2 = Vector2.ZERO, line_spacing: float = 1.1,
		outline: int = 0, outline_color: Color = Color.BLACK, canvas: Vector2i = Vector2i(128, 128),
		alpha: float = 1.0, box_width: int = 0) -> Image:
	var size := clampi(font_size, 4, 256)
	var key := "%s|%s|%d|%s|%s|%s|%.3f|%d|%s|%dx%d|%.3f|%d" % [
		font_path, text, size, color.to_html(), align, str(offset), line_spacing,
		outline, outline_color.to_html(), canvas.x, canvas.y, alpha, box_width,
	]
	if _cache.has(key):
		return _cache[key] as Image
	var image := _build(font_path, text, size, color, align, offset, line_spacing,
		outline, outline_color, canvas, alpha, box_width)
	_cache[key] = image
	_order.append(key)
	while _order.size() > CACHE_LIMIT:
		var oldest: String = _order.pop_front()
		_cache.erase(oldest)
	return image


static func _build(font_path: String, text: String, font_size: int, color: Color,
		align: String, offset: Vector2, line_spacing: float, outline: int,
		outline_color: Color, canvas: Vector2i, alpha: float, box_width: int) -> Image:
	var out := FxImageUtil.new_canvas(Vector2i(maxi(1, canvas.x), maxi(1, canvas.y)))
	var font := FxFontLibrary.font(font_path)
	if font == null:
		return out
	var rids := font.get_rids()
	if rids.is_empty():
		return out
	var rid: RID = rids[0]
	var ts: TextServer = TextServerManager.get_primary_interface()
	var size_vec := Vector2i(font_size, 0)
	var fonts: Array[RID] = [rid]
	var lines := text.split("\n", true)
	var shaped_lines: Array = []
	var max_line_width := 0.0
	var max_line_height := 1.0
	for line in lines:
		var shaped := ts.create_shaped_text(TextServer.DIRECTION_LTR, TextServer.ORIENTATION_HORIZONTAL)
		ts.shaped_text_add_string(shaped, line, fonts, font_size)
		ts.shaped_text_shape(shaped)
		var glyphs := ts.shaped_text_get_glyphs(shaped)
		var line_size := ts.shaped_text_get_size(shaped)
		var line_ascent := ts.shaped_text_get_ascent(shaped)
		var line_descent := ts.shaped_text_get_descent(shaped)
		ts.free_rid(shaped)
		shaped_lines.append({
			"glyphs": glyphs,
			"width": line_size.x,
			"ascent": line_ascent if line_ascent > 0.0 else font.get_ascent(font_size),
		})
		max_line_width = maxf(max_line_width, line_size.x)
		max_line_height = maxf(max_line_height, line_ascent + line_descent)

	var block_width := float(box_width) if box_width > 0 else max_line_width
	var line_height := maxf(1.0, max_line_height * maxf(0.5, line_spacing))
	var total_height := line_height * float(maxi(1, lines.size()))
	var origin := Vector2(canvas) * 0.5
	var block_left := origin.x - block_width * 0.5 + offset.x
	var top := origin.y - total_height * 0.5 + offset.y
	var atlas_cache: Dictionary = {}
	for li in range(shaped_lines.size()):
		var shaped_line: Dictionary = shaped_lines[li]
		var glyphs: Array = shaped_line.get("glyphs", [])
		var line_width := float(shaped_line.get("width", 0.0))
		var pen_x := block_left
		if align == "center":
			pen_x += (block_width - line_width) * 0.5
		elif align == "right":
			pen_x += block_width - line_width
		var baseline := top + float(shaped_line.get("ascent", 0.0)) + float(li) * line_height
		for raw_glyph in glyphs:
			var glyph: Dictionary = raw_glyph
			# 字形可能来自回退字体（缺字时 TextServer 换一个 font_rid），
			# 图集必须按字形自己的 rid 取，否则拿到的永远是空图。
			var glyph_rid: RID = glyph.get("font_rid", rid)
			var index := int(glyph.get("index", -1))
			if index < 0:
				continue
			ts.font_render_glyph(glyph_rid, size_vec, index)
			var tex_idx := ts.font_get_glyph_texture_idx(glyph_rid, size_vec, index)
			var entry: Dictionary = atlas_cache.get("%s|%d" % [str(glyph_rid), tex_idx], {})
			if entry.is_empty():
				var atlas: Image = ts.font_get_texture_image(glyph_rid, size_vec, tex_idx)
				entry = {
					"image": atlas,
					"alpha": atlas != null and _has_alpha(atlas.get_format()),
				}
				atlas_cache["%s|%d" % [str(glyph_rid), tex_idx]] = entry
			var atlas_image: Image = entry.get("image", null)
			if atlas_image == null:
				pen_x += float(glyph.get("advance", 0.0))
				continue
			var uv := ts.font_get_glyph_uv_rect(glyph_rid, size_vec, index)
			var region := atlas_image.get_region(Rect2i(int(uv.position.x), int(uv.position.y),
				int(uv.size.x), int(uv.size.y)))
			if region.get_width() <= 0 or region.get_height() <= 0:
				pen_x += float(glyph.get("advance", 0.0))
				continue
			var use_alpha: bool = bool(entry.get("alpha", true))
			var shaped_off: Vector2 = glyph.get("offset", Vector2.ZERO)
			var glyph_off := ts.font_get_glyph_offset(glyph_rid, size_vec, index)
			var at := Vector2(pen_x + shaped_off.x, baseline + shaped_off.y) + glyph_off
			if outline > 0:
				for oy in range(-outline, outline + 1):
					for ox in range(-outline, outline + 1):
						if ox * ox + oy * oy > outline * outline + 1:
							continue
						_blit(out, region, at + Vector2(ox, oy), outline_color, alpha, use_alpha)
			_blit(out, region, at, color, alpha, use_alpha)
			pen_x += float(glyph.get("advance", 0.0))
	return out


## 图集有没有独立的 alpha 通道。L8/R8 这类灰度图把覆盖率放在亮度里。
static func _has_alpha(format: int) -> bool:
	return format in [Image.FORMAT_LA8, Image.FORMAT_RGBA8, Image.FORMAT_RGBA4444,
		Image.FORMAT_RGBAF, Image.FORMAT_RGBAH]


static func _blit(canvas: Image, region: Image, at: Vector2, color: Color, alpha: float,
		use_alpha: bool = true) -> void:
	var ox := int(round(at.x))
	var oy := int(round(at.y))
	var cw := canvas.get_width()
	var ch := canvas.get_height()
	for y in range(region.get_height()):
		var dy := oy + y
		if dy < 0 or dy >= ch:
			continue
		for x in range(region.get_width()):
			var dx := ox + x
			if dx < 0 or dx >= cw:
				continue
			var src_px := region.get_pixel(x, y)
			var cover := src_px.a if use_alpha else src_px.get_luminance()
			var a := cover * clampf(alpha, 0.0, 1.0)
			if a <= 0.004:
				continue
			var src := Color(color.r, color.g, color.b, a)
			canvas.set_pixel(dx, dy, FxImageUtil.blend_pixel(canvas.get_pixel(dx, dy), src, "normal", 1.0))
