class_name FxParticleExportDialog
extends AcceptDialog
## 粒子导出选项：贴图来源、帧网格、发射参数。
##
## 只负责收集选项，真正写文件交给 FxParticleExport（无 UI、可无头测试）。

signal export_requested(options: Dictionary)

const SHAPE_LABELS := [
	["point", "单点"],
	["sphere", "球形"],
	["sphere_surface", "球面"],
	["box", "方形"],
	["ring", "环形"],
]
const SOURCE_LABELS := [
	["sheet", "整段序列（精灵表）"],
	["frame", "当前帧作为贴图"],
	["texture", "外部纹理 / 精灵表"],
]

var doc: Dictionary = {}
var scene_path: String = ""

var _source: OptionButton
var _texture: LineEdit
var _texture_row: HBoxContainer
var _columns: SpinBox
var _rows: SpinBox
var _grid_row: HBoxContainer
var _amount: SpinBox
var _lifetime: SpinBox
var _explosiveness: SpinBox
var _randomness: SpinBox
var _one_shot: CheckBox
var _shape: OptionButton
var _radius: SpinBox
var _spread: SpinBox
var _dir_x: SpinBox
var _dir_y: SpinBox
var _gravity_x: SpinBox
var _gravity_y: SpinBox
var _scale_min: SpinBox
var _scale_max: SpinBox
var _filter: OptionButton


func setup(p_doc: Dictionary, p_scene_path: String) -> void:
	doc = p_doc
	scene_path = p_scene_path
	title = "Godot 粒子发生器选项"
	ok_button_text = "导出"
	size = Vector2i(560, 660)
	min_size = Vector2i(520, 600)
	_build()
	confirmed.connect(_on_confirmed)


func _build() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var target := Label.new()
	target.text = "输出：%s" % scene_path.get_file()
	target.add_theme_font_size_override("font_size", 11)
	target.add_theme_color_override("font_color", FxUiKit.MUTED)
	root.add_child(target)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	root.add_child(grid)

	_source = OptionButton.new()
	for i in range(SOURCE_LABELS.size()):
		_source.add_item(String(SOURCE_LABELS[i][1]), i)
		_source.set_item_metadata(i, String(SOURCE_LABELS[i][0]))
	_source.select(0)
	_add_field(grid, "贴图来源", _source)
	_source.item_selected.connect(func(_index: int) -> void: _sync_rows())

	_texture_row = HBoxContainer.new()
	_texture = LineEdit.new()
	_texture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_texture.placeholder_text = "PNG / 精灵表路径"
	_texture_row.add_child(_texture)
	var browse := Button.new()
	browse.text = "…"
	browse.pressed.connect(_pick_texture)
	_texture_row.add_child(browse)
	grid.add_child(_texture_row)

	_grid_row = HBoxContainer.new()
	_columns = _spin(1, 64, 1, 1)
	_rows = _spin(1, 64, 1, 1)
	_grid_row.add_child(_label("列"))
	_grid_row.add_child(_columns)
	_grid_row.add_child(_label("行"))
	_grid_row.add_child(_rows)
	grid.add_child(_grid_row)

	_amount = _spin(1, 20000, 1, 1)
	_add_field(grid, "粒子数量", _amount)
	var timeline := FxExportService.timeline_of(doc)
	_lifetime = _spin(0.02, 60.0, 0.02, float(timeline["duration"]))
	_add_field(grid, "生命（秒）", _lifetime)
	_explosiveness = _spin(0.0, 1.0, 0.01, 0.0)
	_add_field(grid, "爆炸度", _explosiveness)
	_randomness = _spin(0.0, 1.0, 0.01, 0.0)
	_add_field(grid, "随机度", _randomness)
	_one_shot = CheckBox.new()
	_one_shot.text = "单次发射"
	_add_field(grid, "播放", _one_shot)

	_shape = OptionButton.new()
	for i in range(SHAPE_LABELS.size()):
		_shape.add_item(String(SHAPE_LABELS[i][1]), i)
		_shape.set_item_metadata(i, String(SHAPE_LABELS[i][0]))
	_shape.select(0)
	_add_field(grid, "发射形状", _shape)
	_radius = _spin(0.0, 512.0, 1.0, 12.0)
	_add_field(grid, "形状半径", _radius)
	_spread = _spin(0.0, 360.0, 1.0, 0.0)
	_add_field(grid, "扩散（°）", _spread)

	var direction_row := HBoxContainer.new()
	_dir_x = _spin(-1.0, 1.0, 0.05, 0.0)
	_dir_y = _spin(-1.0, 1.0, 0.05, -1.0)
	direction_row.add_child(_label("X"))
	direction_row.add_child(_dir_x)
	direction_row.add_child(_label("Y"))
	direction_row.add_child(_dir_y)
	_add_field(grid, "方向", direction_row)

	var gravity_row := HBoxContainer.new()
	_gravity_x = _spin(-2000.0, 2000.0, 1.0, 0.0)
	_gravity_y = _spin(-2000.0, 2000.0, 1.0, 0.0)
	gravity_row.add_child(_label("X"))
	gravity_row.add_child(_gravity_x)
	gravity_row.add_child(_label("Y"))
	gravity_row.add_child(_gravity_y)
	_add_field(grid, "重力", gravity_row)

	var scale_row := HBoxContainer.new()
	_scale_min = _spin(0.01, 16.0, 0.01, 1.0)
	_scale_max = _spin(0.01, 16.0, 0.01, 1.0)
	scale_row.add_child(_label("最小"))
	scale_row.add_child(_scale_min)
	scale_row.add_child(_label("最大"))
	scale_row.add_child(_scale_max)
	_add_field(grid, "缩放", scale_row)

	_filter = OptionButton.new()
	_filter.add_item("最近邻（像素）", 0)
	_filter.add_item("线性", 1)
	_filter.select(0)
	_add_field(grid, "贴图过滤", _filter)

	var hint := Label.new()
	hint.text = "“当前帧”使用时间轴 0 秒画面；外部纹理可指定列×行做翻转书。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", FxUiKit.MUTED)
	root.add_child(hint)
	_sync_rows()


func _add_field(grid: GridContainer, text: String, control: Control) -> void:
	grid.add_child(_label(text))
	grid.add_child(control)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 74
	label.add_theme_font_size_override("font_size", 12)
	return label


func _spin(minimum: float, maximum: float, step: float, value: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = Vector2(86, 24)
	return spin


func _sync_rows() -> void:
	var mode := String(_source.get_item_metadata(_source.selected))
	_texture_row.visible = mode == "texture"
	_grid_row.visible = mode == "texture"


func _pick_texture() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp", "图片")
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		_texture.text = ProjectSettings.localize_path(path)
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.6])


func _on_confirmed() -> void:
	var options := {
		"source": String(_source.get_item_metadata(_source.selected)),
		"texture": _texture.text.strip_edges(),
		"columns": int(_columns.value),
		"rows": int(_rows.value),
		"amount": int(_amount.value),
		"lifetime": float(_lifetime.value),
		"explosiveness": float(_explosiveness.value),
		"randomness": float(_randomness.value),
		"one_shot": _one_shot.button_pressed,
		"emission_shape": String(_shape.get_item_metadata(_shape.selected)),
		"emission_radius": float(_radius.value),
		"spread": float(_spread.value),
		"direction": [float(_dir_x.value), float(_dir_y.value)],
		"gravity": [float(_gravity_x.value), float(_gravity_y.value)],
		"scale_min": float(_scale_min.value),
		"scale_max": float(_scale_max.value),
		"texture_filter": _filter.selected,
		"name": String(FxGraphDoc.meta_value(doc, "name", "FxEmitter")),
	}
	export_requested.emit(options)
