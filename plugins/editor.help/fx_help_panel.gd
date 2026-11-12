class_name FxHelpPanel
extends Control
## 快捷键 / 关于窗口（插件 editor.help 提供）。
##
## 快捷键表直接从命令注册表生成：插件新增带 shortcut 的命令，这里自动出现。

var shell: FxShell


static func create(ctx: Dictionary) -> Control:
	var panel := FxHelpPanel.new()
	panel.setup(ctx)
	return panel


func setup(ctx: Dictionary) -> void:
	shell = ctx.get("shell")
	name = "HelpPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	scroll.add_child(root)

	root.add_child(FxUiKit.strong("幻像工坊 · 插件化工作台", 16))
	root.add_child(FxUiKit.wrapped(
		"基座只保留文档上下文、图执行器、渲染管线与插件宿主；" +
		"画布、时间轴、预览、导出、节点、参数控件全部来自 plugins/ 下的插件。",
		11, FxUiKit.MUTED))
	root.add_child(HSeparator.new())
	root.add_child(FxUiKit.strong("快捷键", 13))
	for item in _shortcuts():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var key := FxUiKit.label(String(item.get("shortcut", "")), 11, FxUiKit.ACCENT)
		key.custom_minimum_size.x = 120
		row.add_child(key)
		row.add_child(FxUiKit.label(String(item.get("label", "")), 11, FxUiKit.TEXT))
		root.add_child(row)

	root.add_child(HSeparator.new())
	root.add_child(FxUiKit.strong("插件", 13))
	root.add_child(FxUiKit.wrapped(FxPluginHost.summary(), 11, FxUiKit.TEXT))
	root.add_child(FxUiKit.wrapped(
		"用户插件目录：%s\n便携插件目录：<exe 同级>/plugins" % ProjectSettings.globalize_path("user://plugins"),
		10, FxUiKit.MUTED))
	var buttons := HBoxContainer.new()
	var manager := FxUiKit.button("插件中心", 11, 26)
	manager.pressed.connect(func() -> void:
		if shell != null:
			shell.open_window("plugin.hub.window")
	)
	buttons.add_child(manager)
	var palette := FxUiKit.button("命令面板", 11, 26)
	palette.pressed.connect(func() -> void:
		if shell != null:
			shell.open_window("editor.palette")
	)
	buttons.add_child(palette)
	root.add_child(buttons)


func _shortcuts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item in shell.command_entries():
		var entry: Dictionary = item
		if String(entry.get("shortcut", "")).is_empty():
			continue
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("shortcut", "")) < String(b.get("shortcut", ""))
	)
	return out


static func cmd_open(ctx: Dictionary) -> void:
	ctx["shell"].open_window("editor.help.window")
