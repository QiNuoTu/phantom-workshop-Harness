class_name FxRecipeWidget
extends RefCounted
## kind = "recipe" 的参数控件：摘要 + 编辑 + 导入。
##
## 由 core.recipe 插件通过 param_kinds() 注册，属于“UI 也能插件化”的示例。
## 参数值始终是**完整 JSON 文本**，所以 .fxgraph 是自包含的，
## 不依赖外部配方文件；导入只是把文件内容读进参数。

static func build(ctx: Dictionary) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var summary := Label.new()
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.clip_text = true
	summary.custom_minimum_size = Vector2(0, 22)
	summary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	summary.add_theme_font_size_override("font_size", 11)
	summary.add_theme_color_override("font_color", FxUiKit.TEXT)
	row.add_child(summary)

	var edit := Button.new()
	edit.text = "编辑"
	edit.tooltip_text = "打开配方 JSON 编辑器"
	edit.custom_minimum_size = Vector2(40, 22)
	edit.add_theme_font_size_override("font_size", 10)
	row.add_child(edit)

	var import := Button.new()
	import.text = "导入"
	import.tooltip_text = "从 .json 文件导入配方"
	import.custom_minimum_size = Vector2(40, 22)
	import.add_theme_font_size_override("font_size", 10)
	row.add_child(import)

	var sync := func() -> void:
		summary.text = _summary(String(ctx["get"].call()))
		summary.tooltip_text = summary.text
	sync.call()

	edit.pressed.connect(func() -> void:
		var host: Node = ctx.get("host")
		if host == null:
			return
		var dialog := FxRecipeDialog.new()
		FxUiKit.style_window(dialog)
		host.add_child(dialog)
		dialog.setup(String(ctx["get"].call()))
		dialog.recipe_confirmed.connect(func(text: String) -> void:
			ctx["set"].call(text)
			sync.call()
		)
		FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.72])
	)
	import.pressed.connect(func() -> void:
		var host: Node = ctx.get("host")
		if host == null:
			return
		var dialog := FileDialog.new()
		FxUiKit.style_window(dialog)
		dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		dialog.access = FileDialog.ACCESS_FILESYSTEM
		dialog.use_native_dialog = true
		dialog.add_filter("*.json", "VfxEngine 配方")
		host.add_child(dialog)
		dialog.file_selected.connect(func(path: String) -> void:
			var text := FileAccess.get_file_as_string(path)
			if JSON.parse_string(text) is Dictionary:
				ctx["set"].call(text)
				sync.call()
			dialog.queue_free()
		)
		dialog.canceled.connect(func() -> void: dialog.queue_free())
		FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.6])
	)
	return {"control": row, "sync": sync}


static func _summary(text: String) -> String:
	if text.strip_edges().is_empty():
		return "默认：火焰喷发（点“编辑”修改）"
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return "（配方 JSON 无效）"
	var recipe: Dictionary = parsed
	return "%s · %d×%d · %d 层" % [
		String(recipe.get("name", "未命名")),
		int(recipe.get("width", 96)),
		int(recipe.get("height", 96)),
		(recipe.get("layers", []) as Array).size(),
	]
