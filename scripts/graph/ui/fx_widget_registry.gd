class_name FxWidgetRegistry
extends RefCounted
## 参数控件工厂：kind -> 构建函数。
##
## 这是“一切皆插件”在 UI 侧的落点：节点定义只写 kind，具体长什么控件由插件决定。
## 基座只保留通用控件（数值/向量/布尔/颜色/枚举/字符串/路径）；
## asset / font / pixelfx / recipe 这类领域控件分别由对应插件注册。
##
## 构建函数签名：
##   func(ctx: Dictionary) -> Dictionary
## ctx:
##   param   Dictionary   参数元数据（id/label/kind/min/max/options/hint…）
##   get     Callable     取当前显示值（已按时间采样过轨道）
##   set     Callable     写值（value）—— 走可逆效果，不直接改文档
##   dialog  Callable     打开资源选择框（kind, on_pick）
##   host    Control      所在节点视图（用作对话框父节点/尺寸参考）
## 返回：
##   { control: Control, sync: Callable }  sync 用于时间变化时刷新控件显示。

static var _builders: Dictionary = {}
static var _ready: bool = false


static func ensure() -> void:
	if _ready:
		return
	_ready = true
	register("float", _build_number)
	register("number", _build_number)
	register("int", _build_number)
	register("integer", _build_number)
	register("vec2", _build_vec2)
	register("bool", _build_bool)
	register("color", _build_color)
	register("enum", _build_enum)
	register("string", _build_string)
	register("path", _build_string)
	# 导出目标：save = 选一个「要写的文件」，dir = 选一个目录。
	register("save", _build_string)
	register("dir", _build_string)


## 退出/重载时清空：构建器可能来自插件脚本，不能活过脚本类。
static func clear() -> void:
	_builders.clear()
	_ready = false


static func register(kind: String, builder: Callable) -> void:
	ensure()
	_builders[kind] = builder


static func has_builder(kind: String) -> bool:
	ensure()
	return _builders.has(kind)


static func kinds() -> Array[String]:
	ensure()
	var out: Array[String] = []
	for key in _builders.keys():
		out.append(String(key))
	out.sort()
	return out


static func build(kind: String, ctx: Dictionary) -> Dictionary:
	ensure()
	if _builders.has(kind):
		return _builders[kind].call(ctx)
	var label := Label.new()
	label.text = "（未知控件类型：%s）" % kind
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color("#8b949e"))
	return {"control": label, "sync": Callable()}


# ================= 内置控件 =================

static func _build_number(ctx: Dictionary) -> Dictionary:
	var param: Dictionary = ctx["param"]
	var kind := String(param.get("kind", "float"))
	var is_int := kind == "int" or kind == "integer"
	var minimum := float(param.get("min", -100000.0))
	var maximum := float(param.get("max", 100000.0))
	var step := 1.0 if is_int else maxf(0.0001, float(param.get("step", 0.01)))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(44, 14)
	line.add_child(slider)

	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	spin.custom_minimum_size = Vector2(58, 22)
	if is_int:
		spin.rounded = true
	if param.has("unit"):
		spin.suffix = String(param.get("unit"))
	line.add_child(spin)

	var fallback_get: Callable = ctx.get("fallback_get", Callable())
	## 声明了 display_fallback 的参数（例如「0 = 跟随画布宽」）：显示有效值，
	## 但文档里仍存 0；只有用户改到别的值才写成覆盖值。
	var effective := func() -> float:
		return float(fallback_get.call()) if fallback_get.is_valid() else 0.0
	var display := func() -> float:
		var raw: float = FxPortType.as_number(ctx["get"].call(), 0.0)
		if raw == 0.0 and fallback_get.is_valid():
			return effective.call()
		return raw
	var sync := func() -> void:
		var value: float = display.call()
		slider.set_value_no_signal(value)
		spin.set_value_no_signal(value)
		# SpinBox 还没入树时内部 LineEdit 的文本不会自动跟着 value 更新。
		var spin_line: LineEdit = spin.get_line_edit()
		if spin_line != null:
			spin_line.text = str(int(value)) if is_int else str(value)
		if fallback_get.is_valid():
			spin.tooltip_text = "当前跟随文档值 %d；改成别的值即覆盖，改回该值恢复跟随" % int(value)
	var commit := func(value: float) -> void:
		var stored: float = value
		if fallback_get.is_valid() and absf(value - effective.call()) < 0.0001:
			stored = 0.0
		if is_int:
			stored = float(int(roundf(stored)))
		ctx["set"].call(stored)
	slider.value_changed.connect(func(value: float) -> void:
		spin.set_value_no_signal(value)
		commit.call(value)
	)
	spin.value_changed.connect(func(value: float) -> void:
		slider.set_value_no_signal(value)
		commit.call(value)
	)
	sync.call()
	return {"control": line, "sync": sync}


static func _build_vec2(ctx: Dictionary) -> Dictionary:
	var param: Dictionary = ctx["param"]
	var minimum := float(param.get("min", -4096.0))
	var maximum := float(param.get("max", 4096.0))
	var step := maxf(0.0001, float(param.get("step", 1.0)))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sx := _spin(minimum, maximum, step, 0.0, "X ")
	var sy := _spin(minimum, maximum, step, 0.0, "Y ")
	sx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(sx)
	line.add_child(sy)

	var sync := func() -> void:
		var value := FxPortType.as_vec2(ctx["get"].call(), Vector2.ZERO)
		sx.set_value_no_signal(value.x)
		sy.set_value_no_signal(value.y)
	sx.value_changed.connect(func(_value: float) -> void:
		ctx["set"].call([sx.value, sy.value])
	)
	sy.value_changed.connect(func(_value: float) -> void:
		ctx["set"].call([sx.value, sy.value])
	)
	sync.call()
	return {"control": line, "sync": sync}


static func _build_bool(ctx: Dictionary) -> Dictionary:
	var check := CheckBox.new()
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.custom_minimum_size.y = 22
	check.add_theme_font_size_override("font_size", 11)
	check.text = "开"
	var sync := func() -> void:
		var value := FxPortType.as_bool(ctx["get"].call(), false)
		check.set_pressed_no_signal(value)
		check.text = "开" if value else "关"
	check.toggled.connect(func(pressed: bool) -> void:
		check.text = "开" if pressed else "关"
		ctx["set"].call(pressed)
	)
	sync.call()
	return {"control": check, "sync": sync}


static func _build_color(ctx: Dictionary) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var picker := ColorPickerButton.new()
	picker.custom_minimum_size = Vector2(30, 22)
	picker.edit_alpha = true
	line.add_child(picker)
	var hex := LineEdit.new()
	hex.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hex.custom_minimum_size = Vector2(0, 22)
	hex.placeholder_text = "#rrggbb"
	line.add_child(hex)

	var sync := func() -> void:
		var color := FxPortType.as_color(ctx["get"].call(), Color.WHITE)
		picker.set_block_signals(true)
		picker.color = color
		picker.set_block_signals(false)
		picker.tooltip_text = "#" + color.to_html(false)
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
	return {"control": line, "sync": sync}


static func _build_multiline(ctx: Dictionary, param: Dictionary) -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var edit := TextEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 46)
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.add_theme_font_size_override("font_size", 11)
	edit.placeholder_text = String(param.get("hint", ""))
	edit.text = String(ctx["get"].call())
	box.add_child(edit)
	var commit := func() -> void:
		ctx["set"].call(edit.text)
	edit.text_changed.connect(func() -> void: commit.call())
	var sync := func() -> void:
		if not edit.has_focus():
			var current := String(ctx["get"].call())
			if current != edit.text:
				edit.text = current
	return {"control": box, "sync": sync}


static func _build_enum(ctx: Dictionary) -> Dictionary:
	var param: Dictionary = ctx["param"]
	var options: Array = param.get("options", [])
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.custom_minimum_size = Vector2(0, 22)
	for i in range(options.size()):
		var item: Variant = options[i]
		var label := ""
		var value: Variant = item
		if item is Dictionary:
			value = (item as Dictionary).get("value", i)
			label = str((item as Dictionary).get("label", value))
		else:
			label = str(item)
		option.add_item(FxI18n.text(label), i)
		option.set_item_metadata(i, value)
	var sync := func() -> void:
		var raw: Variant = ctx["get"].call()
		var value := str(raw)
		# 先清掉上一次为「文档里有、候选表里没有」而临时加的那一项。
		if option.has_meta("dynamic_index"):
			var old_index := int(option.get_meta("dynamic_index"))
			if old_index >= 0 and old_index < option.item_count:
				option.remove_item(old_index)
			option.remove_meta("dynamic_index")
		for i in range(option.item_count):
			if str(option.get_item_metadata(i)) == value:
				option.select(i)
				return
		# 外部改过的文档或关键帧插值出的中间值可能不在候选里：
		# 如实显示当前值，而不是默默选中第一项造成「读数不对」。
		option.add_item(value)
		option.set_item_metadata(option.item_count - 1, raw)
		option.select(option.item_count - 1)
		option.set_meta("dynamic_index", option.item_count - 1)
		option.tooltip_text = "当前值不在预设候选中，已原样显示"
	option.item_selected.connect(func(index: int) -> void:
		if index >= 0 and index < options.size():
			ctx["set"].call(option.get_item_metadata(index))
	)
	sync.call()
	return {"control": option, "sync": sync}


static func _build_string(ctx: Dictionary) -> Dictionary:
	var param: Dictionary = ctx["param"]
	var kind := String(param.get("kind", "string"))
	# 多行文本（台词、说明、JSON 片段）用 TextEdit，单行仍用 LineEdit。
	if bool(param.get("multiline", false)):
		return _build_multiline(ctx, param)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 22)
	edit.placeholder_text = String(param.get("hint", ""))
	edit.text = String(ctx["get"].call())
	line.add_child(edit)
	var commit := func() -> void:
		ctx["set"].call(edit.text)
	edit.text_submitted.connect(func(_text: String) -> void: commit.call())
	edit.focus_exited.connect(func() -> void: commit.call())
	if kind == "path" or kind == "save" or kind == "dir":
		var browse := Button.new()
		browse.text = "…"
		browse.tooltip_text = "选择目录" if kind == "dir" else "选择文件"
		browse.custom_minimum_size = Vector2(24, 22)
		browse.add_theme_font_size_override("font_size", 11)
		line.add_child(browse)
		browse.pressed.connect(func() -> void:
			ctx["dialog"].call(kind, func(path: String) -> void:
				edit.text = path
				ctx["set"].call(path)
			)
		)
	var sync := func() -> void:
		if not edit.has_focus():
			edit.text = String(ctx["get"].call())
	return {"control": line, "sync": sync}


static func _spin(minimum: float, maximum: float, step: float,
		value: float, prefix: String) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.prefix = prefix
	spin.custom_minimum_size = Vector2(52, 22)
	return spin
