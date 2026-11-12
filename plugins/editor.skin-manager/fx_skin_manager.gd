class_name FxSkinManagerWindow
extends Control
## 皮肤管理器（由 smalltailqwq/dsh-client-ui-skin-deep-whale-manager 移植概念）。
##
## 对应原 Web 插件：
##   · 发现所有带有效皮肤声明的插件 → 这里读 FxPluginHost.skin_entries()；
##   · 官方默认与已安装皮肤互斥切换 → 单选列表 + shell.apply_skin()；
##   · 启动兜底：多套同时启用时原子回退默认 → _validate_exclusive()；
##   · 版本化协议 v2 的选项（开关/滑杆/颜色/下拉/复选组/时段）与 visibleWhen
##     → _rebuild_form() 按声明渲染，值由 shell 按 skinId 持久化；
##   · 皮肤自己持有并清理状态 → FxSkin.apply_options() / build_decoration()，
##     管理器不认识任何皮肤内部实现。

var shell: FxShell
var _list: VBoxContainer
var _form: VBoxContainer
var _status: Label
var _current_id: String = "default"
var _conditional: Array[Dictionary] = []


static func create(ctx: Dictionary) -> Control:
	var panel := FxSkinManagerWindow.new()
	panel.shell = ctx.get("shell") as FxShell
	panel._build()
	panel._validate_exclusive()
	panel._rebuild_list()
	panel._rebuild_form()
	return panel


static func cmd_open(ctx: Dictionary) -> void:
	var shell: FxShell = ctx.get("shell") as FxShell
	if shell != null:
		shell.open_window("skin.manager.window")


func _build() -> void:
	custom_minimum_size = Vector2(760, 520)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)
	var columns := HSplitContainer.new()
	margin.add_child(columns)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	left.custom_minimum_size.x = 240
	columns.add_child(left)
	left.add_child(FxUiKit.strong("已安装皮肤", 12))
	var list_scroll := ScrollContainer.new()
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(list_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_list)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	right.custom_minimum_size.x = 360
	columns.add_child(right)
	right.add_child(FxUiKit.strong("皮肤选项（协议 v2）", 12))
	var form_scroll := ScrollContainer.new()
	form_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(form_scroll)
	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 4)
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form_scroll.add_child(_form)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	right.add_child(tools)
	var reset := FxUiKit.button("恢复默认选项", 10, 24)
	reset.pressed.connect(func() -> void:
		if shell != null:
			shell.reset_skin_options(_current_id)
			_rebuild_form()
	)
	tools.add_child(reset)
	_status = FxUiKit.label("", 10, FxUiKit.MUTED)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools.add_child(_status)


## 原子回退：同一时刻只允许一套皮肤处于 active。
func _validate_exclusive() -> void:
	var active := 0
	for entry in FxPluginHost.skin_entries():
		if bool(entry.get("active", false)):
			active += 1
	if active <= 1 or shell == null:
		return
	shell.apply_skin("default")
	_status.text = "检测到 %d 套皮肤同时启用，已回退官方默认" % active


func _rebuild_list() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if shell != null:
		_current_id = shell.current_skin_id()
	_add_skin_row("default", "官方默认", "基座内置", "")
	for entry in FxPluginHost.skin_entries():
		_add_skin_row(String(entry.get("id", "")), String(entry.get("name", "")),
			String(entry.get("author", "插件")), str(entry.get("protocol", "")))


func _add_skin_row(id: String, title: String, author: String, protocol: String) -> void:
	if id.is_empty():
		return
	var row := Button.new()
	row.text = ("● " if id == _current_id else "○ ") + title
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.tooltip_text = "%s · %s%s" % [id, author,
		" · v" + protocol if not protocol.is_empty() else ""]
	row.custom_minimum_size = Vector2(0, 30)
	row.pressed.connect(func() -> void: _select_skin(id))
	_list.add_child(row)


func _select_skin(id: String) -> void:
	if shell == null or id == _current_id:
		return
	_current_id = id
	shell.apply_skin(id)
	_rebuild_list()
	_rebuild_form()
	_status.text = "已切换到 " + id


func _schema_for(skin_id: String) -> Array:
	for entry in FxPluginHost.skin_entries():
		if String(entry.get("id", "")) == skin_id:
			var raw: Variant = entry.get("options", [])
			return raw.duplicate(true) if raw is Array else []
	return []


func _value_for(key: String, spec: Dictionary) -> Variant:
	if shell == null:
		return spec.get("default")
	var saved: Dictionary = shell.skin_options(_current_id)
	return saved.get(key, spec.get("default"))


func _rebuild_form() -> void:
	_conditional.clear()
	for child in _form.get_children():
		_form.remove_child(child)
		child.queue_free()
	_add_preview()
	var schema := _schema_for(_current_id)
	if schema.is_empty():
		_form.add_child(FxUiKit.wrapped(
			"「%s」没有声明自定义选项。皮肤可以在 skins() 里通过 options 协议 v2 暴露开关、滑杆、颜色与条件显示项。" % _current_id,
			11, FxUiKit.MUTED))
		return
	for raw in schema:
		if raw is Dictionary:
			_add_option(raw as Dictionary)



## 皮肤若声明 preview_texture，就从外部资源根加载效果预览图。
## 预览图只是数据，不进 PCK；删除素材包后这一块自动消失。
func _add_preview() -> void:
	var entry := _entry_for(_current_id)
	var root := String(entry.get("texture_root", ""))
	var filename := String(entry.get("preview_texture", ""))
	if root.is_empty() or filename.is_empty():
		return
	var loaded := FxSkinTextureLibrary.load_set(root, {"preview": filename})
	var tex: Variant = loaded.get("preview")
	if not tex is Texture2D:
		return
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = Vector2(0, 150)
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.tooltip_text = "皮肤效果预览（外部资源根，非商业许可素材）"
	_form.add_child(rect)
	_form.add_child(FxUiKit.wrapped("效果预览 · 外部贴图包 · 见 NOTICE.md 署名与许可",
		9, FxUiKit.MUTED))
	_form.add_child(FxUiKit.hsep(false))


func _entry_for(skin_id: String) -> Dictionary:
	for item in FxPluginHost.skin_entries():
		var entry: Dictionary = item
		if String(entry.get("id", "")) == skin_id:
			return entry
	return {}


func _add_option(spec: Dictionary) -> void:
	var key := String(spec.get("key", ""))
	if key.is_empty():
		return
	var value: Variant = _value_for(key, spec)
	var kind := String(spec.get("type", "boolean"))
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 2)
	_form.add_child(card)
	var label := FxUiKit.label(String(spec.get("label", key)), 11, FxUiKit.TEXT)
	card.add_child(label)
	match kind:
		"boolean":
			var check := CheckBox.new()
			check.text = "启用"
			check.button_pressed = bool(value)
			check.toggled.connect(func(pressed: bool) -> void: _set_option(key, pressed))
			card.add_child(check)
		"slider":
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			card.add_child(row)
			var slider := HSlider.new()
			slider.min_value = float(spec.get("min", 0.0))
			slider.max_value = float(spec.get("max", 100.0))
			slider.step = float(spec.get("step", 1.0))
			slider.value = float(value)
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(slider)
			var readout := FxUiKit.label("%.1f" % float(value), 10, FxUiKit.ACCENT)
			row.add_child(readout)
			slider.value_changed.connect(func(v: float) -> void:
				readout.text = "%.1f" % v
				_set_option(key, v)
			)
		"color":
			var picker := ColorPickerButton.new()
			picker.color = Color(String(value)) if Color.html_is_valid(String(value)) else Color.WHITE
			picker.custom_minimum_size = Vector2(0, 26)
			picker.color_changed.connect(func(c: Color) -> void:
				_set_option(key, "#" + c.to_html(false))
			)
			card.add_child(picker)
		"select":
			var option := OptionButton.new()
			var items: Array = spec.get("options", [])
			for i in range(items.size()):
				var item: Dictionary = items[i]
				option.add_item(String(item.get("label", "")), i)
				option.set_item_metadata(i, String(item.get("value", "")))
				if String(item.get("value", "")) == String(value):
					option.select(i)
			option.item_selected.connect(func(i: int) -> void:
				_set_option(key, option.get_item_metadata(i))
			)
			card.add_child(option)
		"checkbox-group":
			var group := HBoxContainer.new()
			group.add_theme_constant_override("separation", 8)
			card.add_child(group)
			var chosen: Array = value.duplicate() if value is Array else []
			var items2: Array = spec.get("options", [])
			for item2 in items2:
				if not item2 is Dictionary:
					continue
				var option_value := String((item2 as Dictionary).get("value", ""))
				var box := CheckBox.new()
				box.text = String((item2 as Dictionary).get("label", option_value))
				box.button_pressed = chosen.has(option_value)
				box.toggled.connect(func(pressed: bool) -> void:
					var current: Array = _value_for(key, spec)
					var next: Array = current.duplicate() if current is Array else []
					if pressed:
						if not next.has(option_value):
							next.append(option_value)
					else:
						next.erase(option_value)
					_set_option(key, next)
				)
				group.add_child(box)
		"visibility-schedule":
			card.add_child(_schedule_controls(key, value))
		_:
			card.add_child(FxUiKit.wrapped("未知控件类型：" + kind, 10, FxUiKit.DANGER))
	if spec.has("visibleWhen"):
		_conditional.append({"control": card, "when": spec["visibleWhen"]})
	_refresh_visibility()


func _schedule_controls(key: String, value: Variant) -> Control:
	var state: Dictionary = value.duplicate(true) if value is Dictionary else {}
	var ranges: Array = state.get("ranges", [])
	var start := 9.0
	var end := 18.0
	if not ranges.is_empty() and ranges[0] is Array:
		start = float((ranges[0] as Array)[0])
		end = float((ranges[0] as Array)[1])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var enabled := CheckBox.new()
	enabled.text = "按时段收起"
	enabled.button_pressed = bool(state.get("enabled", false))
	row.add_child(enabled)
	var from := SpinBox.new()
	from.min_value = 0.0
	from.max_value = 23.0
	from.value = start
	from.prefix = "从"
	row.add_child(from)
	var to := SpinBox.new()
	to.min_value = 0.0
	to.max_value = 23.0
	to.value = end
	to.prefix = "到"
	row.add_child(to)
	var commit := func() -> void:
		_set_option(key, {
			"enabled": enabled.button_pressed, "outside": "visible",
			"ranges": [[int(from.value), int(to.value)]],
		})
	enabled.toggled.connect(func(_pressed: bool) -> void: commit.call())
	from.value_changed.connect(func(_v: float) -> void: commit.call())
	to.value_changed.connect(func(_v: float) -> void: commit.call())
	return row


func _set_option(key: String, value: Variant) -> void:
	if shell == null:
		return
	shell.set_skin_option(_current_id, key, value)
	_refresh_visibility()


## visibleWhen：按另一选项的当前值决定是否显示（对应原协议的 anyOf 单键形式）。
func _refresh_visibility() -> void:
	for raw in _conditional:
		var entry: Dictionary = raw
		var control: Control = entry.get("control")
		var when: Dictionary = entry.get("when", {})
		if control == null or when.is_empty():
			continue
		var watch_key := String(when.get("key", ""))
		var allowed: Array = when.get("values", [])
		var actual: Variant = null
		for spec in _schema_for(_current_id):
			if String(spec.get("key", "")) == watch_key:
				actual = _value_for(watch_key, spec)
				break
		control.visible = allowed.has(actual)
