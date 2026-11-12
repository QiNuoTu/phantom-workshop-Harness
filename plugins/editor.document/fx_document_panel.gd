class_name FxDocumentPanel
extends Control
## 文档属性面板（插件 editor.document 提供）。
##
## 画布尺寸、时长、帧率、循环、背景色、输出节点都在这里；
## 所有写入走 FxDocumentStore 的可逆效果，因此可以撤销。

var shell: FxShell
var store: FxDocumentStore
var _syncing: bool = false

var _name_edit: LineEdit
var _path_label: Label
var _canvas_w: SpinBox
var _canvas_h: SpinBox
var _duration: SpinBox
var _fps: SpinBox
var _loop: CheckBox
var _background: ColorPickerButton
var _output_label: Label


static func create(ctx: Dictionary) -> Control:
	var panel := FxDocumentPanel.new()
	panel.setup(ctx)
	return panel


func setup(ctx: Dictionary) -> void:
	shell = ctx.get("shell")
	store = ctx.get("store")
	name = "DocumentPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	if store != null:
		store.changed.connect(_on_store_changed)
	_sync_all()


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	root.add_child(FxUiKit.strong("文档", 13))
	var name_row := HBoxContainer.new()
	name_row.add_child(FxUiKit.label("名称", 11))
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size.y = 24
	_name_edit.add_theme_font_size_override("font_size", 12)
	name_row.add_child(_name_edit)
	root.add_child(name_row)
	_name_edit.text_submitted.connect(func(_text: String) -> void: _commit_name())
	_name_edit.focus_exited.connect(_commit_name)

	_path_label = FxUiKit.label("未保存", 10, FxUiKit.MUTED)
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root.add_child(_path_label)

	root.add_child(HSeparator.new())
	root.add_child(FxUiKit.strong("画布", 12))
	var canvas_row := HBoxContainer.new()
	canvas_row.add_child(FxUiKit.label("尺寸", 11))
	_canvas_w = _spin(1, 4096, 1, 128, 78)
	_canvas_h = _spin(1, 4096, 1, 128, 78)
	canvas_row.add_child(_canvas_w)
	canvas_row.add_child(FxUiKit.label("×", 11))
	canvas_row.add_child(_canvas_h)
	root.add_child(canvas_row)
	var bg_row := HBoxContainer.new()
	bg_row.add_child(FxUiKit.label("背景", 11))
	_background = ColorPickerButton.new()
	_background.custom_minimum_size = Vector2(66, 24)
	_background.edit_alpha = true
	_background.tooltip_text = "画布底色（导出时保留 alpha）"
	bg_row.add_child(_background)
	root.add_child(bg_row)

	root.add_child(HSeparator.new())
	root.add_child(FxUiKit.strong("时间轴", 12))
	var time_row := HBoxContainer.new()
	time_row.add_child(FxUiKit.label("时长", 11))
	_duration = _spin(0.05, 60.0, 0.05, 1.0, 74)
	_duration.suffix = "s"
	time_row.add_child(_duration)
	time_row.add_child(FxUiKit.label("帧率", 11))
	_fps = _spin(1, 120, 1, 30, 64)
	time_row.add_child(_fps)
	root.add_child(time_row)
	_loop = CheckBox.new()
	_loop.text = "循环播放"
	_loop.add_theme_font_size_override("font_size", 11)
	root.add_child(_loop)

	root.add_child(HSeparator.new())
	root.add_child(FxUiKit.strong("输出", 12))
	_output_label = FxUiKit.label("—", 11, FxUiKit.ACCENT)
	root.add_child(_output_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)
	# 「新建/打开/保存」属于文件命令，统一由菜单栏「文件」与快速访问栏提供。
	# 这里不再重复放一排按钮，避免三处入口做同一件事。
	var path_hint := FxUiKit.wrapped("文件命令见菜单栏「文件」", 10, FxUiKit.MUTED)
	root.add_child(path_hint)

	_canvas_w.value_changed.connect(func(_v: float) -> void: _commit_canvas())
	_canvas_h.value_changed.connect(func(_v: float) -> void: _commit_canvas())
	_duration.value_changed.connect(func(_v: float) -> void: _commit_timeline())
	_fps.value_changed.connect(func(_v: float) -> void: _commit_timeline())
	_loop.toggled.connect(func(_pressed: bool) -> void: _commit_timeline())
	_background.color_changed.connect(_commit_background)


func _spin(minimum: float, maximum: float, step: float, value: float, width: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = Vector2(width, 24)
	spin.add_theme_font_size_override("font_size", 11)
	spin.get_line_edit().add_theme_font_size_override("font_size", 11)
	return spin


func _call_actions(method: String) -> void:
	var actions: Variant = shell.service("document") if shell != null else null
	if actions != null:
		actions.call(method)
		_sync_all()


# ================= 写入 =================

func _commit_name() -> void:
	if _syncing or store == null:
		return
	var text := _name_edit.text.strip_edges()
	if text.is_empty() or text == String(FxGraphDoc.meta_value(store.doc, "name", "")):
		return
	store.set_doc_meta("name", text)


func _commit_canvas() -> void:
	if _syncing or store == null:
		return
	store.set_canvas(int(_canvas_w.value), int(_canvas_h.value))


func _commit_timeline() -> void:
	if _syncing or store == null:
		return
	store.set_timeline(int(_fps.value), float(_duration.value), _loop.button_pressed)


func _commit_background(color: Color) -> void:
	if _syncing or store == null:
		return
	store.mutate(func(d: Dictionary) -> void:
		var meta: Dictionary = d.get("meta", {})
		var canvas: Dictionary = meta.get("canvas", {})
		canvas["background"] = color.to_html()
		meta["canvas"] = canvas
		d["meta"] = meta
	, ["canvas"], "canvas")


# ================= 同步 =================

func _on_store_changed(keys: Array) -> void:
	if keys.has("canvas") or keys.has("timeline") or keys.has("doc"):
		_sync_all()


func _sync_all() -> void:
	if store == null:
		return
	_syncing = true
	var doc := store.doc
	_name_edit.text = String(FxGraphDoc.meta_value(doc, "name", "未命名"))
	var canvas := FxGraphDoc.canvas(doc)
	_canvas_w.set_value_no_signal(canvas.x)
	_canvas_h.set_value_no_signal(canvas.y)
	# SpinBox 的内部 LineEdit 在入树前不会自己显示新值，显式同步文本。
	_canvas_w.get_line_edit().text = str(canvas.x)
	_canvas_h.get_line_edit().text = str(canvas.y)
	var timeline := FxGraphDoc.timeline(doc)
	_duration.set_value_no_signal(float(timeline.get("duration", 1.0)))
	_fps.set_value_no_signal(int(timeline.get("fps", 30)))
	_loop.set_pressed_no_signal(bool(timeline.get("loop", true)))
	_background.color = FxGraphDoc.canvas_background(doc)
	var output := FxGraphDoc.output_id(doc)
	_output_label.text = output if not output.is_empty() else "（未指定输出节点）"
	var actions: Variant = shell.service("document") if shell != null else null
	if actions != null:
		var path := String(actions.get("current_path"))
		_path_label.text = path if not path.is_empty() else "未保存"
		_path_label.tooltip_text = path
	_syncing = false
