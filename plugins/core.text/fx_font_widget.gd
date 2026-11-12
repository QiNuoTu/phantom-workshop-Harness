class_name FxFontWidget
extends RefCounted
## 外部字体参数控件（由 core.text 插件注册，kind = "font"）。

static func build(ctx: Dictionary) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 22)
	edit.placeholder_text = "TTF / OTF / TTC 路径"
	edit.text = String(ctx["get"].call())
	line.add_child(edit)
	var browse := Button.new()
	browse.text = "…"
	browse.tooltip_text = "选择字体文件"
	browse.custom_minimum_size = Vector2(24, 22)
	browse.add_theme_font_size_override("font_size", 11)
	line.add_child(browse)

	var commit := func() -> void:
		ctx["set"].call(edit.text.strip_edges())
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
		dialog.add_filter("*.ttf,*.otf,*.ttc", "字体文件")
		host.add_child(dialog)
		dialog.file_selected.connect(func(path: String) -> void:
			var local := ProjectSettings.localize_path(path)
			edit.text = local
			ctx["set"].call(local)
			dialog.queue_free()
		)
		dialog.canceled.connect(func() -> void: dialog.queue_free())
		FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.6])
	)
	var sync := func() -> void:
		if not edit.has_focus():
			edit.text = String(ctx["get"].call())
	return {"control": line, "sync": sync}
