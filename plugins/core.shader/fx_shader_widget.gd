class_name FxShaderWidget
extends RefCounted
## 着色器参数控件（kind = "shader"）：路径输入 + 浏览 + 「有没有这段代码」提示。

const FILTERS := "*.gdshader,*.shader,*.glsl"


static func build(ctx: Dictionary) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var mark := Label.new()
	mark.custom_minimum_size = Vector2(14, 0)
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mark.add_theme_font_size_override("font_size", 11)
	line.add_child(mark)

	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 22)
	edit.placeholder_text = "拖入 .gdshader，或点右侧浏览"
	edit.text = String(ctx["get"].call())
	line.add_child(edit)

	var browse := Button.new()
	browse.text = "…"
	browse.tooltip_text = "选择 .gdshader 文件"
	browse.custom_minimum_size = Vector2(24, 22)
	browse.add_theme_font_size_override("font_size", 11)
	line.add_child(browse)

	var refresh := func() -> void:
		var path := String(ctx["get"].call()).strip_edges()
		if path.is_empty():
			mark.text = "∅"
			mark.add_theme_color_override("font_color", FxUiKit.MUTED)
			mark.tooltip_text = "没有选择文件：节点会用内置的直通着色器"
			return
		if not FileAccess.file_exists(path):
			mark.text = "!"
			mark.add_theme_color_override("font_color", FxUiKit.DANGER)
			mark.tooltip_text = "找不到这个着色器文件"
			return
		mark.text = "✓"
		mark.add_theme_color_override("font_color", FxUiKit.OK)
		mark.tooltip_text = "着色器文件已找到"

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
		dialog.use_native_dialog = FxUiKit.native_file_dialogs()
		dialog.add_filter(FILTERS, "Godot 着色器")
		dialog.add_filter("*.*", "所有文件")
		dialog.title = "选择着色器"
		host.add_child(dialog)
		dialog.file_selected.connect(func(path: String) -> void:
			edit.text = ProjectSettings.localize_path(path)
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
