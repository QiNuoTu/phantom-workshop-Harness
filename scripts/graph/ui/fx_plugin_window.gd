class_name FxPluginWindow
extends Control
## 插件浮动窗口：标题栏拖动、**八向自由缩放**、双击标题最大化、关闭与重新停靠。
##
## 内容完全由插件工厂创建；这个类只提供「窗口壳」，不认识任何具体面板。
## 用 Control 而不是 PanelContainer 作为根：Container 会强制排版所有子节点，
## 缩放边条与内容裁剪就没法做了。
##
## 自适应要点：
##   · 内容始终铺满窗口（anchors + SIZE_EXPAND_FILL），拖动边条即时重排；
##   · 内容最小尺寸不再撑破窗口，超出部分被裁剪，面板内部自己用 ScrollContainer；
##   · 窗口最小 260×160，交给外壳持久化位置与尺寸（layout.cfg）。

signal close_requested
## 拖动/缩放结束后发出，外壳据此持久化自由布局（§6.1 把外部位置重化进边界）。
signal geometry_changed(window_id: String, rect: Rect2)
## 标题栏上的「重新停靠」：分离出来的面板要能回到原来的停靠区。
signal redock_requested(window_id: String)

const TITLE_H := 32.0
const MIN_SIZE := Vector2(260, 160)
const EDGE := 6.0
const CORNER := 15.0

var window_id: String = ""
var content: Control = null

var _drag_offset: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _resizing: bool = false
var _resize_dir: Vector2i = Vector2i.ZERO
var _resize_start: Vector2 = Vector2.ZERO
var _resize_origin: Rect2 = Rect2()
var _restore_rect: Rect2 = Rect2()
var _maximized: bool = false
var _title_label: Label
var _max_button: Button


func setup(p_id: String, title: String, p_content: Control, size: Vector2i) -> void:
	window_id = p_id
	content = p_content
	name = "window_" + p_id
	custom_minimum_size = MIN_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 10

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.clip_contents = true
	panel.add_theme_stylebox_override("panel",
		FxUiKit.window_style(FxUiKit.PANEL_ALT, FxUiKit.BORDER, 8))
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	panel.add_child(root)

	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = TITLE_H
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	var bar_style := FxUiKit.solid_panel_style(FxUiKit.BAR, FxUiKit.BORDER, 8)
	bar_style.corner_radius_bottom_left = 0
	bar_style.corner_radius_bottom_right = 0
	bar_style.border_width_bottom = 0
	bar.add_theme_stylebox_override("panel", bar_style)
	root.add_child(bar)
	var bar_row := HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 4)
	bar.add_child(bar_row)
	var dot := FxUiKit.label("●", 9, FxUiKit.ACCENT)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar_row.add_child(dot)
	_title_label = FxUiKit.strong(title, 12)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar_row.add_child(_title_label)
	# 分离出来的面板多一个「重新停靠」；普通窗口也有，但外壳只对前者响应。
	var redock := FxUiKit.flat_button("⤓", "重新停靠到原来的区域", 13)
	redock.custom_minimum_size = Vector2(26, 24)
	redock.pressed.connect(func() -> void: redock_requested.emit(window_id))
	bar_row.add_child(redock)
	_max_button = FxUiKit.flat_button("□", "最大化 / 还原（双击标题栏）", 12)
	_max_button.custom_minimum_size = Vector2(26, 24)
	_max_button.pressed.connect(toggle_maximize)
	bar_row.add_child(_max_button)
	var close := FxUiKit.flat_button("×", "关闭", 14)
	close.custom_minimum_size = Vector2(26, 24)
	close.pressed.connect(func() -> void: close_requested.emit())
	bar_row.add_child(close)
	bar.gui_input.connect(_on_title_input)

	var body := MarginContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.clip_contents = true
	body.add_theme_constant_override("margin_left", 6)
	body.add_theme_constant_override("margin_right", 6)
	body.add_theme_constant_override("margin_top", 6)
	body.add_theme_constant_override("margin_bottom", 6)
	root.add_child(body)
	if content != null:
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		body.add_child(content)

	_add_handles()

	if size.x > 0 and size.y > 0:
		custom_minimum_size = Vector2(maxi(size.x, int(MIN_SIZE.x)), maxi(size.y, int(MIN_SIZE.y)))


## 八向缩放条：四条边 + 四个角。角放最后，压在边之上。
func _add_handles() -> void:
	for dir in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
		_add_handle(dir)
	for dir in [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		_add_handle(dir)


func _add_handle(dir: Vector2i) -> void:
	var handle := Control.new()
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = _cursor_for(dir)
	var is_corner := dir.x != 0 and dir.y != 0
	var w := CORNER if is_corner else EDGE
	var h := CORNER if is_corner else EDGE
	if dir.x < 0:
		handle.anchor_left = 0.0
		handle.anchor_right = 0.0
		handle.offset_left = 0.0
		handle.offset_right = w
	elif dir.x > 0:
		handle.anchor_left = 1.0
		handle.anchor_right = 1.0
		handle.offset_left = -w
		handle.offset_right = 0.0
	else:
		handle.anchor_left = 0.0
		handle.anchor_right = 1.0
		handle.offset_left = 0.0
		handle.offset_right = 0.0
	if dir.y < 0:
		handle.anchor_top = 0.0
		handle.anchor_bottom = 0.0
		handle.offset_top = 0.0
		handle.offset_bottom = h
	elif dir.y > 0:
		handle.anchor_top = 1.0
		handle.anchor_bottom = 1.0
		handle.offset_top = -h
		handle.offset_bottom = 0.0
	else:
		handle.anchor_top = 0.0
		handle.anchor_bottom = 1.0
		handle.offset_top = 0.0
		handle.offset_bottom = 0.0
	handle.gui_input.connect(_on_handle_input.bind(dir))
	add_child(handle)


func _cursor_for(dir: Vector2i) -> Control.CursorShape:
	if dir.x != 0 and dir.y != 0:
		return Control.CURSOR_FDIAGSIZE if dir.x * dir.y > 0 else Control.CURSOR_BDIAGSIZE
	if dir.x != 0:
		return Control.CURSOR_HSIZE
	return Control.CURSOR_VSIZE


## 打开时的默认尺寸：用清单声明的 size 作首选，但最多占父容器的 84%，
## 这样小窗口不会撑爆、大屏幕也不会开出一个空荡荡的巨窗。
func present(bounds: Rect2) -> void:
	var target := bounds.size * 0.84
	var preferred := custom_minimum_size
	if preferred.x <= MIN_SIZE.x or preferred.y <= MIN_SIZE.y:
		preferred = target
	size = Vector2(
		clampf(preferred.x, MIN_SIZE.x, maxf(MIN_SIZE.x, target.x)),
		clampf(preferred.y, MIN_SIZE.y, maxf(MIN_SIZE.y, target.y))
	)
	position = bounds.position + (bounds.size - size) * 0.5
	_clamp_to(bounds)


func present_at(rect: Rect2) -> void:
	size = Vector2(maxf(MIN_SIZE.x, rect.size.x), maxf(MIN_SIZE.y, rect.size.y))
	position = rect.position
	_clamp_to(Rect2(Vector2.ZERO, (get_parent() as Control).size) if get_parent() is Control else rect)


func _clamp_to(bounds: Rect2) -> void:
	# 至少留 96px 让标题栏可抓；窗口比画布大时也允许部分越界，不强行缩小。
	position.x = clampf(position.x, bounds.position.x + 8.0 - size.x + 96.0,
		maxf(bounds.position.x + 8.0, bounds.end.x - 96.0))
	position.y = clampf(position.y, bounds.position.y + 4.0,
		maxf(bounds.position.y + 4.0, bounds.end.y - TITLE_H - 4.0))


func geometry() -> Rect2:
	return Rect2(position, size)


func is_maximized() -> bool:
	return _maximized


## 双击标题栏 / 点标题栏按钮：铺满父容器，再点还原。
func toggle_maximize() -> void:
	var parent := get_parent() as Control
	if parent == null:
		return
	if _maximized:
		_maximized = false
		position = _restore_rect.position
		size = _restore_rect.size
		_max_button.text = "□"
	else:
		_restore_rect = Rect2(position, size)
		_maximized = true
		position = parent.position + Vector2(6, 6)
		size = parent.size - Vector2(12, 12)
		_max_button.text = "❐"
	geometry_changed.emit(window_id, geometry())


## 把内容从窗口壳里取出但不释放，供「重新停靠」时挂回 FxDockArea。
func release_content() -> Control:
	if content == null or not is_instance_valid(content):
		return null
	var old_parent := content.get_parent()
	if old_parent != null:
		old_parent.remove_child(content)
	var detached: Control = content
	content = null
	return detached


func raise() -> void:
	move_to_front()
	z_index = 20


func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_popup_window_menu()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed and mb.double_click:
			toggle_maximize()
			return
		if mb.pressed:
			var parent := get_parent() as Control
			var mouse_local := parent.get_local_mouse_position() if parent != null else Vector2.ZERO
			_dragging = true
			_maximized = false
			_drag_offset = mouse_local - position
			raise()
		else:
			_dragging = false
		return


## 标题栏右键：窗口自己那点操作（停靠 / 最大化 / 关闭）。
## 用临时菜单而不是常驻实例 —— 浮动窗口数量不定，多一个节点就多一份状态。
func _popup_window_menu() -> void:
	var menu := PopupMenu.new()
	menu.add_item("⤓ 重新停靠到原来的区域")
	menu.add_item("□ 最大化 / 还原")
	menu.add_separator()
	menu.add_item("× 关闭此窗口")
	menu.id_pressed.connect(func(id: int) -> void:
		match id:
			0:
				redock_requested.emit(window_id)
			1:
				toggle_maximize()
			2:
				close_requested.emit()
		menu.queue_free()
	)
	menu.close_requested.connect(menu.queue_free)
	add_child(menu)
	menu.position = DisplayServer.mouse_get_position()
	menu.reset_size()
	menu.popup()


func _on_handle_input(event: InputEvent, dir: Vector2i) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		var parent := get_parent() as Control
		_resizing = true
		_resize_dir = dir
		_maximized = false
		_resize_start = parent.get_local_mouse_position() if parent != null else Vector2.ZERO
		_resize_origin = Rect2(position, size)
		raise()
	else:
		_resizing = false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and (_dragging or _resizing):
			_dragging = false
			_resizing = false
			geometry_changed.emit(window_id, geometry())
		return
	if not (event is InputEventMouseMotion):
		return
	if not _dragging and not _resizing:
		return
	var parent := get_parent() as Control
	if parent == null:
		return
	var mouse_local := parent.get_local_mouse_position()
	if _dragging:
		var bounds := Rect2(Vector2.ZERO, parent.size)
		var next := mouse_local - _drag_offset
		next.x = clampf(next.x, 4.0, maxf(4.0, bounds.size.x - size.x - 4.0))
		next.y = clampf(next.y, 4.0, maxf(4.0, bounds.size.y - size.y - 4.0))
		position = next
	elif _resizing:
		var delta := mouse_local - _resize_start
		var next_rect := _resize_origin
		if _resize_dir.x < 0:
			next_rect.size.x = maxf(MIN_SIZE.x, _resize_origin.size.x - delta.x)
			next_rect.position.x = _resize_origin.end.x - next_rect.size.x
		elif _resize_dir.x > 0:
			next_rect.size.x = maxf(MIN_SIZE.x, _resize_origin.size.x + delta.x)
		if _resize_dir.y < 0:
			next_rect.size.y = maxf(MIN_SIZE.y, _resize_origin.size.y - delta.y)
			next_rect.position.y = _resize_origin.end.y - next_rect.size.y
		elif _resize_dir.y > 0:
			next_rect.size.y = maxf(MIN_SIZE.y, _resize_origin.size.y + delta.y)
		position = next_rect.position
		size = next_rect.size
