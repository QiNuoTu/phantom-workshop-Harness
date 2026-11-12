class_name FxGraphPathWidget
extends RefCounted
## 子图路径控件（kind = "graph"）。
##
## 一行内完成：路径输入 + 浏览 + 健康检查。检查直接用 FxOpsSubgraph.doc_of()，
## 所以「文件在不在、是不是图文档、里面有几个节点 / 画布多大 / 多长时间」
## 在参数行上就能看到，不用先跑一遍。

static func build(ctx: Dictionary) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 22)
	edit.placeholder_text = "子图文件（.fxgraph）"
	edit.text = String(ctx["get"].call())
	line.add_child(edit)

	var browse := Button.new()
	browse.text = "…"
	browse.tooltip_text = "选择子图文件"
	browse.custom_minimum_size = Vector2(24, 22)
	browse.add_theme_font_size_override("font_size", 11)
	line.add_child(browse)

	var refresh := func() -> void:
		var path := String(ctx["get"].call()).strip_edges()
		if path.is_empty():
			edit.add_theme_color_override("font_color", FxUiKit.TEXT)
			edit.tooltip_text = "留空则不渲染任何内容"
			return
		if not FileAccess.file_exists(path) and FxResourceRoot.resolve(path).is_empty():
			edit.add_theme_color_override("font_color", FxUiKit.DANGER)
			edit.tooltip_text = "找不到这个文件"
			return
		var doc := FxOpsSubgraph.doc_of(path)
		if doc.is_empty():
			edit.add_theme_color_override("font_color", FxUiKit.DANGER)
			edit.tooltip_text = "不是合法的图文档"
			return
		var canvas := FxGraphDoc.canvas(doc)
		var timeline := FxGraphDoc.timeline(doc)
		var nodes: int = (doc.get("nodes", []) as Array).size()
		var output := String(doc.get("output", ""))
		edit.add_theme_color_override("font_color", FxUiKit.TEXT)
		edit.tooltip_text = "%d 个节点 · %d×%d · %.2fs @ %dfps%s" % [
			nodes, canvas.x, canvas.y, float(timeline.get("duration", 1.0)),
			int(timeline.get("fps", 30)),
			"" if not output.is_empty() else " · 没有输出节点",
		]

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
		dialog.add_filter("*.fxgraph,*.fxgraph.json,*.json ; 图文档")
		dialog.title = "选择子图"
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
