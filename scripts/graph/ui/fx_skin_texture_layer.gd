class_name FxSkinTextureLayer
extends Control
## 通用皮肤贴图渲染层：把 FxSkin.texture_layers 的声明画出来。
##
## 皮肤插件只写数据（哪个贴图、贴在哪、透明度多少），不写 draw 代码；
## 因此「皮肤支持贴图」是基座能力，任何插件都能用，且换贴图不用换渲染器。
##
## layer = "back"  画在底板与面板之间（背景 / 立绘，靠半透明面板透出）
## layer = "front" 画在面板之上、浮动窗口之下（蕾丝 / 纹章 / 角饰）
## mode  = cover | fit | tile_x | stretch
## anchor= full | top | bottom | center | bottom_left | bottom_right |
##         bottom_center | top_left | top_right | top_center

var skin: FxSkin
var front: bool = false


func setup(p_skin: FxSkin, p_front: bool) -> void:
	skin = p_skin
	front = p_front
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	queue_redraw()


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	if skin == null:
		return
	for raw in skin.texture_layout():
		if not raw is Dictionary:
			continue
		var layer: Dictionary = raw
		if not bool(layer.get("visible", true)):
			continue
		var is_front := String(layer.get("layer", "back")) == "front"
		if is_front != front:
			continue
		var tex := skin.texture(String(layer.get("texture", "")))
		if tex == null:
			continue
		var alpha := clampf(float(layer.get("opacity", 1.0)), 0.0, 1.0)
		if alpha <= 0.001:
			continue
		var modulate := Color(1, 1, 1, alpha)
		var rect := _rect_for(layer, tex)
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		var mode := String(layer.get("mode", "cover"))
		match mode:
			"stretch":
				draw_texture_rect(tex, rect, false, modulate)
			"fit":
				draw_texture_rect(tex, _fit_rect(tex, rect), false, modulate)
			"tile_x":
				_draw_tiled(tex, rect, modulate)
			_:
				_draw_cover(tex, rect, modulate)


func _draw_cover(tex: Texture2D, rect: Rect2, modulate: Color) -> void:
	var tex_size := tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var scale := maxf(rect.size.x / tex_size.x, rect.size.y / tex_size.y)
	var src_w := rect.size.x / scale
	var src_h := rect.size.y / scale
	var src := Rect2((tex_size.x - src_w) * 0.5, (tex_size.y - src_h) * 0.5,
		src_w, src_h)
	draw_texture_rect_region(tex, rect, src, modulate)


func _fit_rect(tex: Texture2D, rect: Rect2) -> Rect2:
	var tex_size := tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return rect
	var scale := minf(rect.size.x / tex_size.x, rect.size.y / tex_size.y)
	var w := tex_size.x * scale
	var h := tex_size.y * scale
	return Rect2(rect.position.x + (rect.size.x - w) * 0.5,
		rect.position.y + (rect.size.y - h) * 0.5, w, h)


func _draw_tiled(tex: Texture2D, rect: Rect2, modulate: Color) -> void:
	var tex_size := tex.get_size()
	if tex_size.y <= 0.0:
		return
	var unit_w := maxf(1.0, tex_size.x * rect.size.y / tex_size.y)
	var x := rect.position.x
	while x < rect.position.x + rect.size.x:
		draw_texture_rect(tex, Rect2(x, rect.position.y, unit_w, rect.size.y),
			false, modulate)
		x += unit_w


func _rect_for(layer: Dictionary, tex: Texture2D) -> Rect2:
	var w := size.x
	var h := size.y
	if w <= 1.0 or h <= 1.0:
		return Rect2()
	var anchor := String(layer.get("anchor", "full"))
	var scale := clampf(float(layer.get("scale", 1.0)), 0.05, 4.0)
	var offset := _offset(layer)
	if anchor == "full":
		return Rect2(offset.x, offset.y, w, h)
	if anchor == "top" or anchor == "bottom":
		var band := clampf(float(layer.get("height_px", 40.0)) * scale, 1.0, h * 0.5)
		var y := 0.0 if anchor == "top" else h - band
		return Rect2(offset.x, y + offset.y, w, band)
	var tex_size := tex.get_size()
	var ratio := 1.0
	if tex_size.y > 0.0 and tex_size.x > 0.0:
		ratio = tex_size.x / tex_size.y
	var target_h := h * clampf(float(layer.get("height_ratio", 0.8)), 0.02, 2.0) * scale
	var target_w := target_h * ratio
	if layer.has("width_ratio"):
		target_w = w * clampf(float(layer.get("width_ratio", 0.2)), 0.01, 2.0) * scale
	var x := 0.0
	var y := 0.0
	match anchor:
		"bottom_left", "top_left": x = 0.0
		"bottom_right", "top_right": x = w - target_w
		"bottom_center", "top_center", "center": x = (w - target_w) * 0.5
		_: x = (w - target_w) * 0.5
	if anchor.begins_with("bottom"):
		y = h - target_h
	elif anchor.begins_with("top"):
		y = 0.0
	else:
		y = (h - target_h) * 0.5
	return Rect2(x + offset.x, y + offset.y, target_w, target_h)


func _offset(layer: Dictionary) -> Vector2:
	var raw: Variant = layer.get("offset", [0, 0])
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO
