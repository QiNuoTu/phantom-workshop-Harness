class_name FxWelcomeWindow
extends AcceptDialog
## 欢迎页：最近打开 / 新建 / 加载，以及「下次是否再显示」开关。
##
## 只是个门面：真正的新建、打开、最近列表都由 FxDocumentActions 提供，
## 这样换存储格式或换最近列表的存法不会影响这一页。

var actions: FxDocumentActions = null
var _recent: VBoxContainer
var _show_toggle: CheckBox


static func create(p_actions: FxDocumentActions) -> FxWelcomeWindow:
	var dialog := FxWelcomeWindow.new()
	FxUiKit.style_window(dialog)
	dialog.title = "欢迎使用幻像工坊"
	dialog.actions = p_actions
	dialog.min_size = Vector2i(560, 420)
	dialog.ok_button_text = "继续当前工程"
	dialog._build()
	return dialog


func _build() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 24
	root.offset_top = 24
	root.offset_right = -24
	root.offset_bottom = -60
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var title := Label.new()
	title.text = FxI18n.text("幻像工坊")
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG)
	root.add_child(title)
	var sub := Label.new()
	sub.text = "%s · 宿主版本 %s" % [FxI18n.text("插件化特效工作台"), FxProjectArchive.HOST_VERSION]
	sub.add_theme_font_size_override("font_size", 11)
	sub.add_theme_color_override("font_color", FxUiKit.MUTED)
	root.add_child(sub)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	var new_btn := Button.new()
	new_btn.text = "新建工程"
	new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_btn.pressed.connect(_on_new)
	buttons.add_child(new_btn)
	var open_btn := Button.new()
	open_btn.text = "加载工程…"
	open_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_btn.pressed.connect(_on_open)
	buttons.add_child(open_btn)
	root.add_child(buttons)

	root.add_child(HSeparator.new())
	var recent_title := Label.new()
	recent_title.text = "最近打开"
	recent_title.add_theme_font_size_override("font_size", 13)
	recent_title.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG)
	root.add_child(recent_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_recent = VBoxContainer.new()
	_recent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recent.add_theme_constant_override("separation", 3)
	scroll.add_child(_recent)

	_show_toggle = CheckBox.new()
	_show_toggle.text = "启动时显示欢迎页"
	_show_toggle.button_pressed = actions.show_welcome_enabled() if actions != null else true
	_show_toggle.toggled.connect(func(value: bool) -> void:
		if actions != null:
			actions.set_show_welcome(value)
	)
	root.add_child(_show_toggle)
	_refresh_recent()


func _refresh_recent() -> void:
	for child in _recent.get_children():
		child.queue_free()
	if actions == null:
		return
	var entries: Array = actions.recent_files()
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "（还没有打开过工程）"
		empty.add_theme_color_override("font_color", FxUiKit.MUTED)
		_recent.add_child(empty)
		return
	for item in entries:
		var entry: Dictionary = item
		var path := String(entry.get("path", ""))
		var button := Button.new()
		button.text = "%s   %s" % [path.get_file(), String(entry.get("at", ""))]
		button.tooltip_text = path
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.clip_text = true
		var act: FxDocumentActions = actions
		button.pressed.connect(func() -> void:
			_dismiss_then(func() -> void:
				if act != null:
					act.open_path_async(path)
			)
		)
		_recent.add_child(button)


func _on_new() -> void:
	# 必须先取到本地变量：这一页会在下面被 queue_free()，
	# 延后执行的闭包再去读 self.actions 就已经没有 self 了。
	var act: FxDocumentActions = actions
	_dismiss_then(func() -> void:
		if act != null:
			act.new_document()
	)


func _on_open() -> void:
	var act: FxDocumentActions = actions
	_dismiss_then(func() -> void:
		if act != null:
			act.open_popup()
	)


## 先关自己，等两帧再干后面的事。
##
## 欢迎页本身就是个内嵌窗口：同一帧里既销毁它、又弹出下一个窗口（文件对话框等），
## viewport 的 subwindow 列表会在「摘掉旧的」和「登记新的」之间错位，
## 报 `_sub_window_grab_focus: index == -1`。拆成「关 → 等两帧 → 开」最稳。
## 关闭只走 destroy（FxUiKit.dismiss），不能先 hide()：hide 本身就是那个报错的来源。
func _dismiss_then(action: Callable) -> void:
	FxUiKit.dismiss(self)
	FxUiKit.defer(action)

