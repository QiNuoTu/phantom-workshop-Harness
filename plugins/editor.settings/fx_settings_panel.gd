class_name FxSettingsPanel
extends Control
## 统一「设置」窗口：左侧分组导航 + 右侧表单。
##
## 表单完全由 FxRegistry.settings 的声明生成，基座不认识任何一项设置；
## 插件增删设置项时这里自动跟上（声明式配置）。

var shell: Object = null
var _nav: VBoxContainer
var _body: VBoxContainer
var _scroll: ScrollContainer
var _title: Label
var _unsubscribe: Callable = Callable()
var _writing: bool = false
var _group: String = ""
var _nav_rows: Dictionary = {}


func setup(p_shell: Object) -> void:
	shell = p_shell
	name = "FxSettingsPanel"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	root.add_child(head)
	var title := FxUiKit.strong(FxI18n.text("设置"), 15)
	head.add_child(title)
	head.add_child(FxUiKit.spacer(0, true))
	var refresh := FxUiKit.button(FxI18n.text("刷新"), 11, 24)
	refresh.pressed.connect(rebuild)
	head.add_child(refresh)
	var reset := FxUiKit.button(FxI18n.text("全部恢复默认"), 11, 24)
	reset.pressed.connect(_on_reset_all)
	head.add_child(reset)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 10)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(columns)

	# 左：分组导航（固定宽度，窄窗口也不挤）。
	var nav_wrap := PanelContainer.new()
	nav_wrap.custom_minimum_size.x = 176
	nav_wrap.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(FxUiKit.PANEL, FxUiKit.BORDER_SOFT, 4))
	columns.add_child(nav_wrap)
	var nav_scroll := ScrollContainer.new()
	nav_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	nav_wrap.add_child(nav_scroll)
	_nav = VBoxContainer.new()
	_nav.add_theme_constant_override("separation", 2)
	_nav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_scroll.add_child(_nav)

	# 右：当前分组的表单。
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_child(right)
	_title = FxUiKit.strong("", 13)
	right.add_child(_title)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)

	rebuild()
	_unsubscribe = FxSettings.subscribe(Callable(self, "_on_remote_change"))
	FxSettings.apply_all()


func _exit_tree() -> void:
	if _unsubscribe.is_valid():
		_unsubscribe.call()
		_unsubscribe = Callable()


func _on_remote_change(_id: String, _value: Variant, _applies: String) -> void:
	# 只有「别人改的」才刷新表单；自己写值时不能在信号派发中销毁发射者。
	if not _writing:
		rebuild.call_deferred()


func _write(id: String, value: Variant) -> void:
	_writing = true
	FxSettings.set_value(id, value)
	_writing = false


func _on_reset_all() -> void:
	FxSettings.reset_all()
	rebuild()


func rebuild() -> void:
	if _nav == null or _body == null:
		return
	var groups := FxSettings.groups()
	if not groups.has(_group):
		_group = String(groups[0]) if not groups.is_empty() else ""
	_rebuild_nav(groups)
	_rebuild_body()


func _rebuild_nav(groups: Array) -> void:
	for child in _nav.get_children():
		_nav.remove_child(child)
		child.queue_free()
	_nav_rows.clear()
	for group in groups:
		var name := String(group)
		var button := Button.new()
		button.text = FxI18n.text(name)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(0, 28)
		button.add_theme_font_size_override("font_size", 11)
		var active := name == _group
		button.add_theme_stylebox_override("normal", _nav_style(active, false))
		button.add_theme_stylebox_override("hover", _nav_style(active, true))
		button.add_theme_stylebox_override("pressed", _nav_style(true, false))
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG if active else FxUiKit.TEXT)
		button.add_theme_color_override("font_hover_color", FxUiKit.TEXT_STRONG)
		button.pressed.connect(func() -> void: select_group(name))
		_nav.add_child(button)
		_nav_rows[name] = button


## 分组导航：选中项用左侧 3px 强调条 + 淡底（Qt 的侧边导航），不画整圈边框。
func _nav_style(active: bool, hover: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	if active:
		style.bg_color = Color(FxUiKit.ACCENT, 0.14)
		style.border_color = FxUiKit.ACCENT
		style.border_width_left = 3
	elif hover:
		style.bg_color = FxUiKit.PANEL_ALT
		style.border_color = Color(0, 0, 0, 0)
	else:
		style.bg_color = Color(0, 0, 0, 0)
		style.border_color = Color(0, 0, 0, 0)
	style.set_corner_radius_all(3)
	style.content_margin_left = 10.0
	style.content_margin_right = 8.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	return style


func select_group(group: String) -> void:
	if _group == group:
		return
	_group = group
	_rebuild_nav(FxSettings.groups())
	_rebuild_body()


func _rebuild_body() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	if _title != null:
		_title.text = FxI18n.text(_group)
	if _group.is_empty():
		_body.add_child(FxUiKit.wrapped(FxI18n.text("还没有任何设置项。"), 11, FxUiKit.MUTED))
		return
	for entry in FxSettings.group_entries(_group):
		_body.add_child(_build_row(entry))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(spacer)
	if _scroll != null:
		_scroll.scroll_vertical = 0


func _build_row(entry: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(FxUiKit.PANEL_ALT, FxUiKit.BORDER_SOFT, 4))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	card.add_child(box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)

	var id := String(entry.get("id", ""))
	var label := FxUiKit.label(FxI18n.text(str(entry.get("label", id))), 12)
	label.custom_minimum_size = Vector2(150, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var control := FxSettingWidgets.build(entry, Callable(self, "_write"))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)
	var owner := FxUiKit.label(String(entry.get("owner", "")), 10, FxUiKit.MUTED)
	owner.custom_minimum_size = Vector2(96, 0)
	owner.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	owner.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	owner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(owner)
	var description := String(entry.get("description", ""))
	if not description.is_empty():
		box.add_child(FxUiKit.wrapped(FxI18n.text(description), 10, FxUiKit.MUTED))
	return card
