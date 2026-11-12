class_name FxCommandPalette
extends Control
## 命令面板（插件 editor.palette 提供，Ctrl+P）。
##
## 演示“窗口 + 命令”两类贡献：列表同时聚合命令、面板与窗口，
## 输入即过滤，回车执行。插件新增命令后自动出现在这里，不需要改这个类。

const WINDOW_ID := "editor.palette"

var shell: FxShell
var _search: LineEdit
var _list: ItemList
var _entries: Array[Dictionary] = []


static func create(ctx: Dictionary) -> Control:
	var panel := FxCommandPalette.new()
	panel.setup(ctx)
	return panel


func setup(ctx: Dictionary) -> void:
	shell = ctx.get("shell")
	name = "CommandPalette"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	refresh()


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	_search = LineEdit.new()
	_search.placeholder_text = "输入命令、面板或窗口名称…"
	_search.custom_minimum_size.y = 30
	_search.add_theme_font_size_override("font_size", 13)
	root.add_child(_search)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.add_theme_font_size_override("font_size", 12)
	root.add_child(_list)
	root.add_child(FxUiKit.label("↑↓ 选择 · Enter 执行 · Esc 关闭", 10, FxUiKit.MUTED))

	_search.text_changed.connect(func(_text: String) -> void: _refresh_list())
	_search.text_submitted.connect(func(_text: String) -> void: _activate_first())
	_list.item_activated.connect(_activate)
	FxUiKit.focus_later(_search)


func refresh() -> void:
	_entries.clear()
	for item in shell.command_entries():
		var entry: Dictionary = item
		_entries.append({
			"kind": "command",
			"id": String(entry.get("id", "")),
			"label": String(entry.get("label", entry.get("id", ""))),
			"category": String(entry.get("category", "命令")),
			"shortcut": String(entry.get("shortcut", "")),
		})
	for panel_id in shell.panel_specs.keys():
		var spec: Dictionary = shell.panel_specs[panel_id]
		_entries.append({
			"kind": "panel",
			"id": String(panel_id),
			"label": String(spec.get("title", panel_id)),
			"category": "面板",
			"shortcut": "",
		})
	for item in FxPluginHost.window_entries():
		var win: Dictionary = item
		_entries.append({
			"kind": "window",
			"id": String(win.get("id", "")),
			"label": String(win.get("title", win.get("id", ""))),
			"category": "窗口",
			"shortcut": "",
		})
	_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("category", "")) < String(b.get("category", ""))
	)
	_refresh_list()


func _refresh_list() -> void:
	_list.clear()
	var needle := _search.text.strip_edges().to_lower()
	var shown := 0
	for entry in _entries:
		var haystack := "%s %s %s" % [String(entry.get("label", "")),
			String(entry.get("id", "")), String(entry.get("category", ""))]
		if not needle.is_empty() and not haystack.to_lower().contains(needle):
			continue
		var text := "%s   ·   %s" % [FxI18n.text(String(entry.get("label", ""))),
			String(entry.get("category", ""))]
		var shortcut := String(entry.get("shortcut", ""))
		if not shortcut.is_empty():
			text += "      %s" % shortcut
		var index := _list.add_item(text)
		_list.set_item_metadata(index, entry)
		shown += 1
	if shown > 0:
		_list.select(0)


func _activate_first() -> void:
	if _list.item_count > 0:
		_activate(0)


func _activate(index: int) -> void:
	var meta: Variant = _list.get_item_metadata(index)
	if not meta is Dictionary:
		return
	var entry: Dictionary = meta
	match String(entry.get("kind", "")):
		"panel":
			shell.open_panel(String(entry.get("id", "")))
		"window":
			shell.open_window(String(entry.get("id", "")))
		_:
			shell.run_command(String(entry.get("id", "")))
	_close()


func _close() -> void:
	if shell != null:
		shell.close_window(WINDOW_ID)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()


# ================= 命令入口 =================

static func cmd_open(ctx: Dictionary) -> void:
	ctx["shell"].open_window(WINDOW_ID)
