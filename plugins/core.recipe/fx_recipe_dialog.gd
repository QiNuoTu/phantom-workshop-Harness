class_name FxRecipeDialog
extends AcceptDialog
## VfxEngine 配方编辑器：图层表单 + JSON 原文双视图。
##
## 两个视图共享同一份 _recipe 字典：表单改动写回 JSON，切回表单时从 JSON 解析。
## 参数值仍然是**完整 JSON 文本**存进 .fxgraph，文档自包含、不依赖外部文件。
##
## 字段不做白名单：VfxEngine 以后新增的字段在 JSON 页可编辑，在表单页也会
## 自动长成一行（值按 JSON 文本编辑），所以表单不会吞掉未知字段。

signal recipe_confirmed(text: String)

const LAYER_TYPES := ["flash", "cycle", "burst", "aura", "orbit", "ring", "smoke", "spark"]
const ROOT_FIELDS := ["name", "width", "height", "duration", "loop", "seed", "ramp_size", "stretch"]
const ROOT_JSON_FIELDS := ["origin", "palette", "post"]
const FIELD_HINTS := ["count", "speed", "angle", "life", "size", "radius", "glow",
	"gravity", "drag", "color_from", "color_to", "shape", "spawn_radius", "period",
	"width", "pulses", "flatten", "omega", "t0", "y", "asset", "amount", "threshold"]

var _text: TextEdit
var _tabs: TabContainer
var _form: VBoxContainer
var _status: Label
var _preset: OptionButton
var _source: String = ""
var _recipe: Dictionary = {}
var _updating: bool = false
## 解析状态：中途打出半截 JSON 不算「失败」，只是「还没成形」。
## 失败时保留上一次成功的 _recipe，表单不会被清空，也不会覆盖用户正在输入的文本。
var _parsed_ok: bool = false
var _parse_error: String = ""


func setup(current_text: String) -> void:
	# 对话框是独立 Window，不继承 Control 的 theme，必须显式套皮肤。
	FxUiKit.style_window(self)
	title = "特效配方 · 图层表单"
	size = Vector2i(760, 680)
	min_size = Vector2i(580, 500)
	ok_button_text = "应用"
	_source = current_text
	_build()
	_text.text = current_text
	_parse_text(current_text)
	_rebuild_form()
	_validate()
	confirmed.connect(_on_confirmed)
	add_cancel_button("取消")


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	root.add_child(tools)
	_preset = OptionButton.new()
	_preset.add_item("载入预设…", 0)
	var index := 1
	for item in FxRecipePresets.presets():
		_preset.add_item(String(item.get("label", "")), index)
		_preset.set_item_metadata(index, String(item.get("json", "")))
		index += 1
	_preset.item_selected.connect(_on_preset_selected)
	tools.add_child(_preset)
	var format_button := FxUiKit.button("格式化", 10, 24)
	format_button.pressed.connect(_format)
	tools.add_child(format_button)
	var hint := FxUiKit.label("表单与 JSON 实时同步", 11, FxUiKit.MUTED)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tools.add_child(hint)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	root.add_child(_tabs)

	var form_scroll := ScrollContainer.new()
	form_scroll.name = "图层表单"
	form_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	form_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(form_scroll)
	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 6)
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form_scroll.add_child(_form)

	var json_page := VBoxContainer.new()
	json_page.name = "JSON 原文"
	_tabs.add_child(json_page)
	_text = TextEdit.new()
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.custom_minimum_size = Vector2(0, 420)
	_text.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_text.text_changed.connect(_on_text_changed)
	json_page.add_child(_text)

	_status = FxUiKit.label("", 11, FxUiKit.MUTED)
	root.add_child(_status)


func _on_tab_changed(tab: int) -> void:
	# TabContainer 在 _build() 里添加第一个页签时就会发 tab_changed，
	# 那时 _text / _form 可能还没建好。
	if _text == null or _form == null:
		return
	if tab == 0:
		# 只有 JSON 能解析成对象时才重建表单；否则保持表单原样，让用户先把 JSON 修好。
		if _parse_text(_text.text):
			_rebuild_form()
	_validate()


## 解析 JSON 文本。返回是否可用。
## 关键：**失败不清空 _recipe**。以前每次按键都把 _recipe 置成 {}，
## 于是「输入一半 → 切到表单页 → 表单空白 → 再改一下字段 → 整段 JSON 被 {} 覆盖」。
func _parse_text(value: String) -> bool:
	var probe := JSON.new()
	var err := probe.parse(value)
	if err != OK:
		_parse_error = "第 %d 行：%s" % [probe.get_error_line(), probe.get_error_message()]
		_parsed_ok = false
		return false
	var parsed: Variant = probe.data
	if not parsed is Dictionary:
		_parse_error = "顶层必须是一个 JSON 对象 { … }"
		_parsed_ok = false
		return false
	_recipe = (parsed as Dictionary).duplicate(true)
	_parse_error = ""
	_parsed_ok = true
	return true


func _sync_text() -> void:
	if _updating:
		return
	_updating = true
	_text.text = JSON.stringify(_recipe, "\t")
	_updating = false
	_validate()


func _on_text_changed() -> void:
	if _updating:
		return
	_parse_text(_text.text)
	_validate()


# ================= 表单 =================

func _rebuild_form() -> void:
	for child in _form.get_children():
		_form.remove_child(child)
		child.queue_free()

	_form.add_child(FxUiKit.strong("配方参数", 12))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	_form.add_child(_wrap(grid))
	for key in ROOT_FIELDS:
		_add_field(grid, key, _recipe.get(key, _default_root(key)), -1)
	for key2 in ROOT_JSON_FIELDS:
		_add_field(grid, key2, _recipe.get(key2, null), -1, true)

	var layers: Variant = _recipe.get("layers", [])
	var layer_list: Array = layers.duplicate(true) if layers is Array else []
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	_form.add_child(header)
	var title := FxUiKit.strong("图层（%d）" % layer_list.size(), 12)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var add := FxUiKit.button("+ 添加图层", 10, 24)
	add.pressed.connect(func() -> void: _add_layer())
	header.add_child(add)

	var live_layers: Variant = _recipe.get("layers", [])
	for i in range(layer_list.size()):
		if live_layers is Array and i < (live_layers as Array).size() \
				and (live_layers as Array)[i] is Dictionary:
			_add_layer_row(i, (live_layers as Array)[i])


## 表单网格左对齐、宽度由控件决定，右侧留白 —— 而不是把每个输入框拉满整行。
func _wrap(grid: GridContainer) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(grid)
	var pad := Control.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(pad)
	return row


func _default_root(key: String) -> Variant:
	match key:
		"name": return "未命名配方"
		"width", "height": return 128
		"duration": return 1.0
		"loop", "stretch": return true
		"seed": return 1
		"ramp_size": return 10
	return ""


func _add_field(grid: GridContainer, key: String, value: Variant,
		layer_index: int, json_only: bool = false) -> void:
	var label := FxUiKit.label(key, 10, FxUiKit.MUTED)
	label.custom_minimum_size.x = 84
	grid.add_child(label)
	if value is bool and not json_only:
		var check := CheckBox.new()
		check.button_pressed = value
		# 表单里只有一个勾选框，不拉伸成一条蓝带。
		check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		check.toggled.connect(func(pressed: bool) -> void:
			_write_field(key, pressed, layer_index)
		)
		grid.add_child(check)
	elif (value is float or value is int) and not json_only:
		var spin := SpinBox.new()
		spin.min_value = -99999.0
		spin.max_value = 99999.0
		spin.step = 0.01 if value is float else 1.0
		spin.value = float(value)
		spin.custom_minimum_size.x = 120
		spin.size_flags_horizontal = Control.SIZE_FILL
		spin.value_changed.connect(func(v: float) -> void:
			_write_field(key, int(v) if value is int else v, layer_index)
		)
		grid.add_child(spin)
	else:
		grid.add_child(_line_field(key, value, layer_index))
	var pad := Control.new()
	pad.custom_minimum_size.x = 8
	grid.add_child(pad)


func _line_field(key: String, value: Variant, layer_index: int) -> Control:
	var line := LineEdit.new()
	line.size_flags_horizontal = Control.SIZE_FILL
	line.custom_minimum_size.x = 300
	line.text = "" if value == null else (JSON.stringify(value) if value is Array \
			or value is Dictionary else String(value))
	line.text_changed.connect(func(text: String) -> void:
		_write_field(key, _parse_value(text, value), layer_index)
	)
	return line


func _parse_value(text: String, original: Variant) -> Variant:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return original
	if original is Array or original is Dictionary or trimmed.begins_with("[") \
			or trimmed.begins_with("{") or trimmed.begins_with("\""):
		var parsed: Variant = JSON.parse_string(trimmed)
		return parsed if parsed != null else original
	if original is int:
		return int(trimmed)
	if original is float:
		return float(trimmed)
	return trimmed


func _write_field(key: String, value: Variant, layer_index: int) -> void:
	if not _parsed_ok:
		# JSON 页有语法错误时，表单改动先不落盘，避免把用户正在输入的内容整段覆盖。
		_status.text = "JSON 有语法错误，先在「JSON 原文」页修好再改表单"
		_status.add_theme_color_override("font_color", FxUiKit.DANGER)
		return
	if layer_index < 0:
		_recipe[key] = value
	else:
		var layers: Variant = _recipe.get("layers", [])
		if not layers is Array or layer_index >= (layers as Array).size():
			return
		if not (layers as Array)[layer_index] is Dictionary:
			return
		((layers as Array)[layer_index] as Dictionary)[key] = value
	_sync_text()


func _add_layer_row(index: int, data: Dictionary) -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", FxUiKit.panel_style(FxUiKit.PANEL_ALT, FxUiKit.BORDER, 4))
	_form.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	card.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	box.add_child(head)
	head.add_child(FxUiKit.strong("#%d" % (index + 1), 11))
	var type_picker := OptionButton.new()
	for i in range(LAYER_TYPES.size()):
		type_picker.add_item(LAYER_TYPES[i], i)
	var current := LAYER_TYPES.find(String(data.get("type", "")))
	type_picker.select(maxi(0, current))
	type_picker.item_selected.connect(func(i: int) -> void:
		_write_field("type", LAYER_TYPES[i], index)
	)
	head.add_child(type_picker)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var up := FxUiKit.button("↑", 10, 22)
	up.pressed.connect(func() -> void: _move_layer(index, -1))
	head.add_child(up)
	var down := FxUiKit.button("↓", 10, 22)
	down.pressed.connect(func() -> void: _move_layer(index, 1))
	head.add_child(down)
	var remove := FxUiKit.button("×", 10, 22)
	remove.pressed.connect(func() -> void: _remove_layer(index))
	head.add_child(remove)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 3)
	box.add_child(_wrap(grid))
	for raw_key in data.keys():
		var key := String(raw_key)
		if key == "type":
			continue
		_add_field(grid, key, data[raw_key], index,
			data[raw_key] is Array or data[raw_key] is Dictionary)

	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 4)
	box.add_child(add_row)
	var field_picker := OptionButton.new()
	for f in FIELD_HINTS:
		field_picker.add_item(f)
	add_row.add_child(field_picker)
	var add_field := FxUiKit.button("+ 添加字段", 10, 22)
	add_field.pressed.connect(func() -> void:
		var field_name := String(FIELD_HINTS[field_picker.selected])
		if not data.has(field_name):
			_write_field(field_name, 0.0, index)
			_rebuild_form()
	)
	add_row.add_child(add_field)


func _add_layer() -> void:
	var layers: Variant = _recipe.get("layers", [])
	if not layers is Array:
		layers = []
		_recipe["layers"] = layers
	(layers as Array).append({
		"type": "cycle", "count": 24, "speed": [8, 32], "life": [0.4, 0.9],
		"size": [2, 6], "glow": 0.6, "shape": "smoke",
	})
	_sync_text()
	_rebuild_form()


func _remove_layer(index: int) -> void:
	var layers: Variant = _recipe.get("layers", [])
	if not layers is Array or index < 0 or index >= (layers as Array).size():
		return
	(layers as Array).remove_at(index)
	_sync_text()
	_rebuild_form()


func _move_layer(index: int, delta: int) -> void:
	var layers: Variant = _recipe.get("layers", [])
	if not layers is Array:
		return
	var target := index + delta
	if index < 0 or target < 0 or index >= (layers as Array).size() \
			or target >= (layers as Array).size():
		return
	var item: Variant = (layers as Array)[index]
	(layers as Array).remove_at(index)
	(layers as Array).insert(target, item)
	_sync_text()
	_rebuild_form()


# ================= 工具 / 校验 =================

func _on_preset_selected(index: int) -> void:
	_preset.select(0)
	if index <= 0:
		return
	var text := String(_preset.get_item_metadata(index))
	if text.is_empty():
		return
	_text.text = text
	_parse_text(text)
	_rebuild_form()
	_validate()


func _format() -> void:
	if _parse_text(_text.text):
		_sync_text()
		_rebuild_form()
	_validate()


func _validate() -> void:
	var ok := _parsed_ok
	var message := ""
	if not _parsed_ok:
		message = "JSON 解析失败 · %s" % _parse_error
	else:
		var layers: Variant = _recipe.get("layers", null)
		if not layers is Array or (layers as Array).is_empty():
			message = "缺少 layers 数组（至少一层）"
			ok = false
		else:
			message = "%s · %d×%d · %d 层 · %.2fs" % [
				String(_recipe.get("name", "未命名配方")),
				int(_recipe.get("width", 96)), int(_recipe.get("height", 96)),
				(layers as Array).size(), float(_recipe.get("duration", 1.0)),
			]
	_status.text = message
	_status.add_theme_color_override("font_color", FxUiKit.OK if ok else FxUiKit.DANGER)
	var ok_button := get_ok_button()
	if ok_button != null:
		ok_button.disabled = not ok


func _on_confirmed() -> void:
	if not _parse_text(_text.text):
		_validate()
		popup_centered()
		return
	# 确认时重新序列化：注释、缩进、尾逗号里的脏东西不会带进文档。
	recipe_confirmed.emit(JSON.stringify(_recipe, "\t"))
	queue_free()
