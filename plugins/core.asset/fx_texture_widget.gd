class_name FxTextureWidget
extends RefCounted
## 外部纹理参数控件（kind = "texture"）。
##
## 一行里完成：路径输入 + 浏览 + 缩略图。缩略图直接来自 FxTextureLibrary，
## 因此「文件是否存在、尺寸多少」一眼可见，不用先跑一遍图。

const FILTERS := "*.png,*.webp,*.jpg,*.jpeg,*.bmp,*.tga,*.svg"


static func build(ctx: Dictionary) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var thumb := TextureRect.new()
	thumb.custom_minimum_size = Vector2(28, 22)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(thumb)

	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 22)
	edit.placeholder_text = "图片路径（可拖入 / 浏览）"
	edit.text = String(ctx["get"].call())
	line.add_child(edit)

	var browse := Button.new()
	browse.text = "…"
	browse.tooltip_text = "选择纹理文件"
	browse.custom_minimum_size = Vector2(24, 22)
	browse.add_theme_font_size_override("font_size", 11)
	line.add_child(browse)

	var refresh := func() -> void:
		var path := String(ctx["get"].call()).strip_edges()
		var info := FxTextureLibrary.probe(path)
		if bool(info.get("ok", false)):
			var size: Vector2i = info.get("size", Vector2i.ZERO)
			thumb.texture = FxTextureLibrary.texture(path)
			var hint := "%d × %d" % [size.x, size.y]
			# 精灵表节点直接报「切出来多少帧」，不用接输出节点才知道数。
			var node_get: Callable = ctx.get("node_get", Callable())
			var live: Dictionary = node_get.call() if node_get.is_valid() else ctx.get("node", {})
			var frames := _sheet_hint(live, size)
			if not frames.is_empty():
				hint += "  " + frames
			thumb.tooltip_text = hint
			edit.tooltip_text = hint
			edit.add_theme_color_override("font_color", FxUiKit.TEXT)
		else:
			thumb.texture = null
			thumb.tooltip_text = "未找到纹理" if not path.is_empty() else ""
			if not path.is_empty():
				edit.add_theme_color_override("font_color", FxUiKit.DANGER)
			else:
				edit.add_theme_color_override("font_color", FxUiKit.TEXT)

	var commit := func() -> void:
		ctx["set"].call(edit.text.strip_edges())
		refresh.call()
	edit.text_submitted.connect(func(_text: String) -> void: commit.call())
	edit.focus_exited.connect(func() -> void: commit.call())
	browse.pressed.connect(func() -> void:
		var host: Control = ctx.get("host")
		if host == null:
			return
		var dialog := FileDialog.new()
		FxUiKit.style_window(dialog)
		dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		dialog.access = FileDialog.ACCESS_FILESYSTEM
		dialog.use_native_dialog = true
		dialog.add_filter(FILTERS, "图片")
		dialog.title = "导入纹理"
		host.add_child(dialog)
		dialog.file_selected.connect(func(path: String) -> void:
			edit.text = path
			commit.call()
			dialog.queue_free()
		)
		dialog.canceled.connect(func() -> void: dialog.queue_free())
		FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.6])
	)

	var sync := func() -> void:
		if not edit.has_focus():
			edit.text = String(ctx["get"].call())
			refresh.call()
	refresh.call()
	return {"control": line, "sync": sync}


## 精灵表节点的参数行提示：4 × 4 = 16 帧，单元 32 × 32。
## 只在这类节点上生成，普通纹理节点返回空串。
static func _sheet_hint(node: Dictionary, size: Vector2i) -> String:
	if node.is_empty() or String(node.get("type", "")) != "image.sheet":
		return ""
	var params: Dictionary = node.get("params", {})
	var grid := FxTextureLibrary.grid_of(size,
		String(_value(params, "mode", "grid")),
		int(FxTracks.number(_value(params, "columns", 4), 4)),
		int(FxTracks.number(_value(params, "rows", 1), 1)),
		_to_vec2i(_value(params, "cell", [32, 32])),
		int(FxTracks.number(_value(params, "margin", 0), 0)),
		int(FxTracks.number(_value(params, "spacing", 0), 0)))
	var cell: Vector2i = grid.get("cell", Vector2i.ZERO)
	return "%d × %d = %d 帧，单元 %d × %d" % [
		int(grid.get("cols", 1)), int(grid.get("rows", 1)), int(grid.get("count", 1)),
		cell.x, cell.y,
	]


## 参数可能被打了关键帧（{track: [...]})，这里只关心它的静态值。
static func _value(params: Dictionary, key: String, fallback: Variant) -> Variant:
	var raw: Variant = params.get(key, fallback)
	if FxTracks.has_track(raw):
		return FxTracks.sample(raw, 0.0)
	return raw


static func _to_vec2i(raw: Variant) -> Vector2i:
	if raw is Vector2i:
		return raw
	if raw is Vector2:
		return Vector2i(int(round(raw.x)), int(round(raw.y)))
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2i(int(round(float((raw as Array)[0]))), int(round(float((raw as Array)[1]))))
	return Vector2i(32, 32)

