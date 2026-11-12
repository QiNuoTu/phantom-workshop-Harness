class_name FxDockArea
extends VBoxContainer
## 停靠区默认实现：顶部是面板标签（带关闭按钮），下面只显示当前面板。
##
## 这是「可替换贡献」的默认版本：插件通过 dock_factories() 提供另一个
## FxDockArea 子类，就能换成完全不同的停靠容器（例如 VSplit 多栏、
## TabContainer、可拖拽 dock），外壳只依赖这里列出的方法。
##
## 面板实例常驻，切换只改 visible，画布滚动/时间轴位置都不会丢；
## 折叠时只留一条 30px 的细条，不销毁任何面板。

signal panel_focused(panel_id: String)
## 用户点了标签上的 ×；外壳负责延迟调用 set_panel_visible(false)，
## 避免在按钮信号派发过程中释放发射者。
signal panel_close_requested(panel_id: String)
signal collapse_changed(area: String, collapsed: bool)
## 用户点了标签上的 ⧉；外壳把面板实例从本容器取出，挂进可自由拖动的浮动窗口。
signal panel_detach_requested(panel_id: String)
## 用户想把面板开成系统原生窗口；外壳调 detach_panel(id, true)。
signal panel_native_requested(panel_id: String)
## 面板标题菜单里的一项注入功能被点选；外壳负责把 command 转成 run_command。
signal panel_feature_requested(panel_id: String, command: String)

var area: String = "center"
var collapsed: bool = false

var _bar: HBoxContainer
var _bar_wrap: PanelContainer
var _content: PanelContainer
var _empty: Label
var _collapse_bar: Button
var _entries: Array[Dictionary] = []
var _current: String = ""
var _expanded_min_size: Vector2 = Vector2.ZERO
var _expanded_stretch: float = 1.0
## 右键菜单实例：内容区右键与标签右键共用，弹出前按目标面板重填。
var _ctx_menu: PopupMenu


func _init(area_id: String = "center") -> void:
	area = area_id
	add_theme_constant_override("separation", 0)
	custom_minimum_size = Vector2(0, 0)


func _ready() -> void:
	if _bar != null:
		return
	# 标签条带一层底板 + 内边距：像 IDE 的标签栏，而不是浮在画布上的按钮。
	_bar_wrap = PanelContainer.new()
	_bar_wrap.add_theme_stylebox_override("panel", FxUiKit.chrome_style("dock_bar"))
	add_child(_bar_wrap)
	var bar_margin := MarginContainer.new()
	bar_margin.add_theme_constant_override("margin_left", 4)
	bar_margin.add_theme_constant_override("margin_right", 4)
	bar_margin.add_theme_constant_override("margin_top", 3)
	bar_margin.add_theme_constant_override("margin_bottom", 0)
	_bar_wrap.add_child(bar_margin)
	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 3)
	_bar.custom_minimum_size.y = 28
	bar_margin.add_child(_bar)

	_collapse_bar = FxUiKit.flat_button("▸", "展开此停靠区", 10)
	_collapse_bar.clip_text = true
	_collapse_bar.custom_minimum_size = Vector2(28, 30)
	_collapse_bar.visible = false
	_collapse_bar.pressed.connect(func() -> void: set_collapsed(false))
	add_child(_collapse_bar)

	_content = PanelContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.clip_contents = true
	add_child(_content)

	_empty = FxUiKit.wrapped("这个区域还没有面板。\n插件可以通过 panels() 注册。", 11, FxUiKit.MUTED)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_content.add_child(_empty)

	_ctx_menu = PopupMenu.new()
	_ctx_menu.name = "PanelMenu"
	_ctx_menu.id_pressed.connect(func(id: int) -> void:
		_on_panel_menu_id(id, _ctx_menu)
	)
	add_child(_ctx_menu)
	# 面板内容区的空白处右键也出这张菜单（子控件自己吃掉的事件不会到这里）。
	_content.gui_input.connect(func(event: InputEvent) -> void:
		if not (event is InputEventMouseButton):
			return
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed or _current.is_empty():
			return
		show_panel_menu(_current, get_global_mouse_position())
		get_viewport().set_input_as_handled()
	)
	_rebuild_bar()


## 外壳传入展开态的最小尺寸与伸展比例；折叠时由本类负责压缩。
func configure(min_size: Vector2, stretch_ratio: float = 1.0) -> void:
	_expanded_min_size = min_size
	_expanded_stretch = maxf(stretch_ratio, 0.01)
	if not collapsed:
		custom_minimum_size = _expanded_min_size
		size_flags_stretch_ratio = _expanded_stretch


func set_collapsed(value: bool) -> void:
	if collapsed == value:
		return
	collapsed = value
	if _bar != null:
		_bar.visible = not collapsed and _visible_count() > 1
	if _bar_wrap != null:
		_bar_wrap.visible = not collapsed and _visible_count() > 1
	if _content != null:
		_content.visible = not collapsed
	if _collapse_bar != null:
		_collapse_bar.visible = collapsed
		# 侧栏收成 28px 竖条，底栏收成 30px 横条；文字过长会把 Button 撑宽。
		_collapse_bar.text = "▸ 展开停靠区（%d 个面板）" % _entries.size() if area == "bottom" else "▸"
		_collapse_bar.tooltip_text = "展开 %s 停靠区 · %d 个面板" % [area, _entries.size()]
	if collapsed:
		custom_minimum_size = Vector2(0, 30) if area == "bottom" else Vector2(28, 0)
		size_flags_stretch_ratio = 0.01
	else:
		custom_minimum_size = _expanded_min_size
		size_flags_stretch_ratio = _expanded_stretch
		_rebuild_bar()
	collapse_changed.emit(area, collapsed)


func is_collapsed() -> bool:
	return collapsed


func add_panel(panel_id: String, title: String, control: Control, order: int = 0,
		visible: bool = true) -> void:
	if control == null:
		return
	if has_panel(panel_id):
		remove_panel(panel_id)
	control.visible = false
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.add_child(control)
	_entries.append({
		"id": panel_id,
		"title": title,
		"control": control,
		"order": order,
		"visible": visible,
	})
	_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0))
	)
	_rebuild_bar()
	if visible and _current.is_empty():
		show_panel(panel_id)


## 分离：把面板实例原样交给外壳，不销毁、不重建，画布缩放/滚动状态都保留。
## 返回 null 表示这个面板不在本区域。
func detach(panel_id: String) -> Control:
	var index := _find(panel_id)
	if index < 0:
		return null
	var entry: Dictionary = _entries[index]
	var control: Control = entry.get("control")
	if control != null and control.get_parent() == _content:
		_content.remove_child(control)
	_entries.remove_at(index)
	if _current == panel_id:
		_current = ""
		_show_first_visible()
	_rebuild_bar()
	return control


func remove_panel(panel_id: String) -> void:
	for i in range(_entries.size()):
		var entry: Dictionary = _entries[i]
		if String(entry.get("id", "")) != panel_id:
			continue
		var control: Control = entry.get("control")
		if control != null:
			_content.remove_child(control)
			control.queue_free()
		_entries.remove_at(i)
		if _current == panel_id:
			_current = ""
		_rebuild_bar()
		if _current.is_empty():
			_show_first_visible()
		return


func clear_all() -> void:
	for entry in _entries:
		var control: Control = entry.get("control")
		if control != null:
			_content.remove_child(control)
			control.queue_free()
	_entries.clear()
	_current = ""
	_empty.visible = true
	_rebuild_bar()


func has_panel(panel_id: String) -> bool:
	return _find(panel_id) >= 0


func panel(panel_id: String) -> Control:
	var index := _find(panel_id)
	return _entries[index].get("control") if index >= 0 else null


func entries() -> Array[Dictionary]:
	return _entries.duplicate()


func current_id() -> String:
	return _current


func set_panel_visible(panel_id: String, visible: bool) -> void:
	var index := _find(panel_id)
	if index < 0:
		return
	(_entries[index] as Dictionary)["visible"] = visible
	if visible:
		show_panel(panel_id)
	elif _current == panel_id:
		_current = ""
		_show_first_visible()
	_rebuild_bar()


func is_panel_visible(panel_id: String) -> bool:
	var index := _find(panel_id)
	if index < 0:
		return false
	return bool((_entries[index] as Dictionary).get("visible", true))


func show_panel(panel_id: String) -> void:
	var index := _find(panel_id)
	if index < 0:
		return
	var entry: Dictionary = _entries[index]
	entry["visible"] = true
	_current = panel_id
	for item in _entries:
		var control: Control = item.get("control")
		if control != null:
			control.visible = String(item.get("id", "")) == panel_id
	_empty.visible = false
	if collapsed:
		set_collapsed(false)
	_rebuild_bar()
	panel_focused.emit(panel_id)


func visible_ids() -> Array[String]:
	var out: Array[String] = []
	for entry in _entries:
		if bool(entry.get("visible", true)):
			out.append(String(entry.get("id", "")))
	return out


func _show_first_visible() -> void:
	var first := ""
	for entry in _entries:
		if bool(entry.get("visible", true)):
			first = String(entry.get("id", ""))
			break
	if first.is_empty():
		for entry in _entries:
			var control: Control = entry.get("control")
			if control != null:
				control.visible = false
		_empty.visible = true
		return
	show_panel(first)


func _find(panel_id: String) -> int:
	for i in range(_entries.size()):
		if String((_entries[i] as Dictionary).get("id", "")) == panel_id:
			return i
	return -1


func _visible_count() -> int:
	var count := 0
	for entry in _entries:
		if bool(entry.get("visible", true)):
			count += 1
	return count


func _rebuild_bar() -> void:
	if _bar == null:
		return
	for child in _bar.get_children():
		_bar.remove_child(child)
		child.queue_free()
	_bar.visible = not collapsed and _visible_count() > 1
	if _bar_wrap != null:
		_bar_wrap.visible = _bar.visible
	if not _bar.visible:
		return
	for entry in _entries:
		if not bool(entry.get("visible", true)):
			continue
		var panel_id := String(entry.get("id", ""))
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 0)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var active := panel_id == _current
		var tab := Button.new()
		tab.text = String(entry.get("title", panel_id))
		tab.toggle_mode = true
		tab.focus_mode = Control.FOCUS_NONE
		tab.clip_text = true
		tab.set_pressed_no_signal(active)
		tab.custom_minimum_size = Vector2(0, 26)
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.add_theme_font_size_override("font_size", 11)
		tab.add_theme_stylebox_override("normal", FxUiKit.tab_style(false))
		tab.add_theme_stylebox_override("hover", FxUiKit.tab_style(active, true))
		tab.add_theme_stylebox_override("pressed", FxUiKit.tab_style(true))
		tab.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		tab.add_theme_color_override("font_color", FxUiKit.MUTED)
		tab.add_theme_color_override("font_hover_color", FxUiKit.TEXT_STRONG)
		tab.add_theme_color_override("font_pressed_color", FxUiKit.ACCENT)
		tab.toggled.connect(func(pressed: bool) -> void:
			if pressed:
				show_panel(panel_id)
		)
		cell.add_child(tab)
		# 每个面板（插件注册的或随软件发布的）都有同一套标题菜单，
		# 右键标签也能叫出同一张表 —— 停靠区的「右键菜单」就是它。
		var actions := MenuButton.new()
		actions.text = "⋯"
		actions.flat = true
		actions.tooltip_text = "面板操作与插件注入功能"
		actions.custom_minimum_size = Vector2(22, 26)
		actions.add_theme_font_size_override("font_size", 12)
		var popup := actions.get_popup()
		_fill_panel_menu(popup, panel_id)
		popup.id_pressed.connect(func(id: int) -> void:
			_on_panel_menu_id(id, popup)
		)
		cell.add_child(actions)
		tab.gui_input.connect(_on_tab_gui_input.bind(panel_id))
		cell.gui_input.connect(_on_tab_gui_input.bind(panel_id))
		_bar.add_child(cell)
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(fill)
	var fold := FxUiKit.flat_button("−", "折叠此停靠区", 12)
	fold.custom_minimum_size = Vector2(22, 26)
	fold.pressed.connect(func() -> void: set_collapsed(true))
	_bar.add_child(fold)


# ---------- 面板菜单：⋯ 按钮、标签右键、内容区右键共用 ----------

## 这张表是「每个窗口都有右键菜单」的落点：分离、独立窗口、插件功能、关闭。
func _fill_panel_menu(popup: PopupMenu, panel_id: String) -> void:
	popup.clear()
	popup.add_item("⧉ 分离为浮动窗口")
	popup.set_item_metadata(popup.item_count - 1, {"detach": panel_id})
	popup.add_item("⇱ 开成独立系统窗口")
	popup.set_item_metadata(popup.item_count - 1, {"native": panel_id})
	popup.add_separator()
	var injected := FxPanelBroker.menu_features(panel_id)
	for feature in injected:
		popup.add_item(String(feature.get("label", "")))
		popup.set_item_metadata(popup.item_count - 1, {
			"feature": String(feature.get("command", "")), "panel": panel_id,
		})
	if not injected.is_empty():
		popup.add_separator()
	popup.add_item("− 折叠此停靠区")
	popup.set_item_metadata(popup.item_count - 1, {"collapse": area})
	popup.add_item("× 关闭此面板")
	popup.set_item_metadata(popup.item_count - 1, {"close": panel_id})


func _on_panel_menu_id(id: int, popup: PopupMenu) -> void:
	var data: Variant = popup.get_item_metadata(id)
	if not data is Dictionary:
		return
	var meta: Dictionary = data
	if meta.has("detach"):
		panel_detach_requested.emit(String(meta["detach"]))
	elif meta.has("native"):
		panel_native_requested.emit(String(meta["native"]))
	elif meta.has("collapse"):
		set_collapsed(true)
	elif meta.has("close"):
		panel_close_requested.emit(String(meta["close"]))
	elif meta.has("feature"):
		panel_feature_requested.emit(String(meta["panel"]), String(meta["feature"]))


func _on_tab_gui_input(event: InputEvent, panel_id: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return
	show_panel_menu(panel_id, get_global_mouse_position())
	get_viewport().set_input_as_handled()


## 在指定屏幕坐标弹出面板菜单（右键、外部调用都用它）。
func show_panel_menu(panel_id: String, at: Vector2) -> void:
	_fill_panel_menu(_ctx_menu, panel_id)
	_ctx_menu.position = Vector2i(at)
	_ctx_menu.reset_size()
	_ctx_menu.popup()
