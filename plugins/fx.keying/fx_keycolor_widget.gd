extends RefCounted
## 「键色」参数控件：比内置颜色控件多一排**常用键色色块**。
##
## 为什么值得单独一种控件：美工调绿幕时 90% 的动作是「点一下绿色」，
## 而标准取色器要先开弹窗、切到绿、确认。一排色块把这件事变成一次点击，
## 同时保留取色器供非标键色（布料反光、蓝幕偏紫）使用。
##
## 控件契约与内置控件一致（见 FxWidgetRegistry 的文档注释）：
##   返回 { control: Control, sync: Callable }
##   写入一律走 ctx["set"]，不直接改文档。

## 常用键色。顺序即显示顺序：最常用的绿、蓝打头。
const PRESETS := [
	{"value": "#00ff00", "tip": "标准绿幕"},
	{"value": "#0047ff", "tip": "标准蓝幕"},
	{"value": "#87ceeb", "tip": "天空蓝"},
	{"value": "#ffffff", "tip": "白底"},
	{"value": "#000000", "tip": "黑底"},
	{"value": "#ff00ff", "tip": "品红"},
]


static func build(ctx: Dictionary) -> Dictionary:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(top)

	var picker := ColorPickerButton.new()
	picker.custom_minimum_size = Vector2(30, 22)
	picker.edit_alpha = false
	picker.tooltip_text = "自定义键色"
	top.add_child(picker)

	var hex := LineEdit.new()
	hex.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hex.custom_minimum_size = Vector2(0, 22)
	hex.placeholder_text = "#rrggbb"
	top.add_child(hex)

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 3)
	column.add_child(chips)
	var chip_buttons: Array[Button] = []
	for item in PRESETS:
		var button := Button.new()
		button.custom_minimum_size = Vector2(18, 14)
		button.tooltip_text = String(item.get("tip", ""))
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_stylebox_override("normal", _chip_style(String(item.get("value", "#ffffff"))))
		button.add_theme_stylebox_override("hover", _chip_style(String(item.get("value", "#ffffff"))))
		button.add_theme_stylebox_override("pressed", _chip_style(String(item.get("value", "#ffffff"))))
		var value := String(item.get("value", "#ffffff"))
		button.pressed.connect(func() -> void: ctx["set"].call(value))
		chips.add_child(button)
		chip_buttons.append(button)

	var sync := func() -> void:
		var color := FxValue.as_color(ctx["get"].call(), Color.WHITE)
		picker.set_block_signals(true)
		picker.color = color
		picker.set_block_signals(false)
		picker.tooltip_text = "自定义键色 · 当前 #" + color.to_html(false)
		if not hex.has_focus():
			hex.text = "#" + color.to_html(false)
	sync.call()

	picker.color_changed.connect(func(color: Color) -> void:
		hex.text = "#" + color.to_html(false)
		ctx["set"].call(color.to_html())
	)
	var commit := func() -> void:
		var token := hex.text.strip_edges()
		if token.is_empty():
			return
		if not token.begins_with("#"):
			token = "#" + token
		var parsed := Color.from_string(token, Color(-1, -1, -1, -1))
		if parsed.r < 0.0:
			return
		picker.color = parsed
		ctx["set"].call(parsed.to_html())
	hex.text_submitted.connect(func(_text: String) -> void: commit.call())
	hex.focus_exited.connect(func() -> void: commit.call())
	return {"control": column, "sync": sync}


static func _chip_style(hex: String) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	var color := Color.from_string(hex, Color.WHITE)
	style.bg_color = color
	style.set_corner_radius_all(3)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.22)
	return style
