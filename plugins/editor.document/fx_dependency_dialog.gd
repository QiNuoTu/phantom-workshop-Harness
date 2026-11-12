class_name FxDependencyDialog
extends AcceptDialog
## 纯文本工程加载后的「缺依赖」面板。
##
## 资源可以当场手动修复（重新选文件，回写对应参数）；插件没有运行时补法，
## 只能列出 id 让用户去装 —— 这点如实告诉用户，不做假按钮。

var doc: Dictionary = {}
var store: FxDocumentStore = null
var shell: Node = null
var _list: VBoxContainer
var _summary: Label


static func create(p_doc: Dictionary, p_store: FxDocumentStore, p_shell: Node) -> FxDependencyDialog:
	var dialog := FxDependencyDialog.new()
	FxUiKit.style_window(dialog)
	dialog.title = "工程依赖检查"
	dialog.doc = p_doc
	dialog.store = p_store
	dialog.shell = p_shell
	dialog.min_size = Vector2i(560, 360)
	dialog.ok_button_text = "知道了"
	dialog._build()
	return dialog


func _build() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16
	root.offset_top = 16
	root.offset_right = -16
	root.offset_bottom = -56
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_font_size_override("font_size", 12)
	root.add_child(_summary)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_list)
	_refresh()


func _refresh() -> void:
	for child in _list.get_children():
		child.queue_free()
	var deps := FxProjectArchive.scan_dependencies(doc)
	var missing_assets: Array = deps.get("missing_assets", [])
	var missing_plugins: Array = deps.get("missing_plugins", [])
	_summary.text = "缺少 %d 个资源、%d 个插件依赖。资源可手动重新指定；插件请安装后重新打开工程。" % [
		missing_assets.size(), missing_plugins.size(),
	]
	if missing_assets.is_empty() and missing_plugins.is_empty():
		_summary.text = "依赖齐全。"
		return

	if not missing_assets.is_empty():
		_list.add_child(_section("缺失资源（点「修复」重新指定文件）"))
		for item in missing_assets:
			var asset: Dictionary = item
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			var name_label := Label.new()
			name_label.text = "%s   %s.%s" % [String(asset.get("path", "")),
				String(asset.get("node", "")), String(asset.get("param", ""))]
			name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			name_label.clip_text = true
			name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			name_label.add_theme_font_size_override("font_size", 11)
			row.add_child(name_label)
			var fix := Button.new()
			fix.text = "修复…"
			fix.pressed.connect(_on_fix.bind(String(asset.get("node", "")),
				String(asset.get("param", "")), name_label))
			row.add_child(fix)
			_list.add_child(row)

	if not missing_plugins.is_empty():
		_list.add_child(_section("缺失插件（无法自动修复，请安装后重新打开）"))
		for item2 in missing_plugins:
			var plugin: Dictionary = item2
			var line := Label.new()
			line.text = "• " + String(plugin.get("id", ""))
			line.add_theme_color_override("font_color", FxUiKit.DANGER)
			_list.add_child(line)


func _on_fix(node_id: String, param_id: String, label: Label) -> void:
	var dialog := FileDialog.new()
	FxUiKit.style_window(dialog)
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		if FxProjectArchive.repair_asset(doc, node_id, param_id, path):
			label.text = path
			if store != null:
				store.apply_param(node_id, param_id, path)
			if shell != null and shell.has_method("status"):
				shell.status("已修复资源：%s" % path.get_file())
			_refresh.call_deferred()
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.6])


func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG)
	return label
