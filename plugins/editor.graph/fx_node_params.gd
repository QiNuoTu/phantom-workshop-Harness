class_name FxNodeParams
extends RefCounted
## 节点内联参数：**一个参数一行**，直接长在 GraphNode 里。
##
## 设计要点：
##   · 不再是“标签一行 + 控件一行”的面板，也不是节点底部的一块面板；
##   · 可绑定参数的输入端口就长在这一行左侧，端口和控件是同一个视觉单元；
##   · 控件类型由 FxWidgetRegistry 决定，新增 kind 不需要改这个类；
##   · 所有写入走 apply_edit（FxDocumentStore 的可逆效果），本类不直接改文档；
##   · 关键帧规则只实现一次：参数值可以变成 {track: [...]}，之后编辑 = 当前时间 upsert。

const LABEL_W := 64.0
const ROW_H := 22.0
const KEY_W := 18.0


var node_id: String = ""
var def: FxNodeDef
var data: Dictionary = {}
var time: float = 0.0
var duration: float = 1.0
var apply_edit: Callable = Callable()
## 需要读取文档级有效值（画布宽高等）的参数控件会用到。
var store: FxDocumentStore = null

var _host: GraphNode
var _attach: Callable
var _rows: Array[Dictionary] = []
var _keys: Dictionary = {}
## 已挂到 GraphNode 上的行：{row: Control, port_id: String}。节点视图用它做折叠。
var placed_rows: Array[Dictionary] = []
## 图层行的打帧按钮与时间同步：键是图层下标。
var _layer_keys: Dictionary = {}
var _layer_syncs: Array[Callable] = []
## 一层的可动画字段：透明度、位移、显示（混合模式是离散枚举，不进轨道）。
const LAYER_TRACK_FIELDS := [["opacity", 1.0], ["offset", [0, 0]], ["visible", true]]
var _port_specs: Dictionary = {}
## 被连线驱动的参数：{pid: true}。值由上游决定，控件只读。
var _bound: Dictionary = {}
## 本帧执行器解析出的参数值（含关键帧采样与端口回填），{pid: Variant}。
var _live: Dictionary = {}


## 把参数行挂到 host（GraphNode）里。attach(row, port) 由节点视图提供：
## port 非空时它会调用 set_slot，让端口贴在参数行左侧。
func mount(host: GraphNode, p_node_id: String, p_def: FxNodeDef, p_data: Dictionary,
		p_time: float, p_duration: float, p_apply: Callable, attach: Callable,
		ports: Dictionary = {}, p_store: FxDocumentStore = null,
		bound: Dictionary = {}) -> void:
	_host = host
	node_id = p_node_id
	def = p_def
	data = p_data
	time = p_time
	duration = maxf(0.001, p_duration)
	apply_edit = p_apply
	_attach = attach
	_port_specs = ports
	store = p_store
	_bound = bound
	_live.clear()
	_rows.clear()
	_keys.clear()
	placed_rows.clear()
	_layer_keys.clear()
	_layer_syncs.clear()
	_build_all()


func _build_all() -> void:
	if def == null:
		return
	for param in def.params:
		var kind := String(param.get("kind", "float"))
		if kind == "layers":
			_build_layers(param)
		else:
			_build_param_row(param)


## 声明了 display_fallback 的参数：把「0 = 跟随文档」翻译成当前实际值给控件显示。
## 目前只有画布宽/高用，完全由节点声明驱动，基座不认识任何具体尺寸语义。
func _fallback_getter(param: Dictionary) -> Callable:
	var key := String(param.get("display_fallback", ""))
	if key.is_empty() or store == null:
		return Callable()
	return func() -> float:
		var canvas: Vector2i = FxGraphFacade.access().doc_canvas(store.doc)
		if key == "canvas.width":
			return float(canvas.x)
		if key == "canvas.height":
			return float(canvas.y)
		return 0.0


func _build_param_row(param: Dictionary) -> void:
	var pid := String(param.get("id", ""))
	var kind := String(param.get("kind", "float"))
	var row := _new_row()
	row.add_child(_make_label(param))

	var ctx := {
		"param": param,
		"node": data,
		# 控件要拿「当前」节点数据：撤销/重做会换掉 data 引用的对象。
		"node_get": func() -> Dictionary: return data,
		"node_id": node_id,
		"get": func() -> Variant: return _display_value(pid),
		"set": func(value: Variant) -> void: _write(pid, value),
		"dialog": func(dialog_kind: String, on_pick: Callable) -> void: _open_dialog(dialog_kind, on_pick),
		"host": _host,
		"fallback_get": _fallback_getter(param),
	}
	var built := FxWidgetRegistry.build(kind, ctx)
	var control: Control = built.get("control")
	if control != null:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(control)
		if _bound.has(pid):
			_freeze(control)
	var sync: Callable = built.get("sync", Callable())

	if _can_key(kind):
		row.add_child(_make_key_button(pid))
	_rows.append({"pid": pid, "sync": sync, "row": row})
	_place_row(row, _port_specs.get(pid, {}))
	_refresh_keys()


## 任何参数都能打关键帧：数值插值，文本/资源路径按 step 切换。
## 只有 layers 是复合参数（它由每层自己的 ◆ 负责）。
func _can_key(kind: String) -> bool:
	return kind != "layers"


func _make_label(param: Dictionary) -> Label:
	var label := Label.new()
	label.text = String(param.get("label", param.get("id", "")))
	label.custom_minimum_size = Vector2(LABEL_W, ROW_H)
	label.clip_text = true
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG)
	if _bound.has(String(param.get("id", ""))):
		# 被连线驱动的参数：值来自上游，标签上加个标记，免得用户以为是文档里的值。
		label.text = "⇠ " + label.text
		label.add_theme_color_override("font_color", FxUiKit.ACCENT)
		label.tooltip_text = "由连线驱动：值来自上游节点（断开连线后可编辑）"
	var hint := String(param.get("hint", ""))
	if not hint.is_empty() and not _bound.has(String(param.get("id", ""))):
		label.tooltip_text = hint
	return label


func _make_key_button(pid: String) -> Button:
	var button := Button.new()
	button.flat = true
	button.custom_minimum_size = Vector2(KEY_W, ROW_H)
	button.add_theme_font_size_override("font_size", 11)
	button.tooltip_text = "当前时间打 / 删关键帧"
	button.pressed.connect(_toggle_track.bind(pid))
	_keys[pid] = button
	return button


func _new_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.custom_minimum_size = Vector2(0, ROW_H)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return row


## 交给节点视图：add_child + set_slot（如果需要端口）。
func _place_row(row: Control, port: Dictionary = {}) -> void:
	if _host == null:
		return
	_host.add_child(row)
	placed_rows.append({"row": row, "port_id": String(port.get("id", ""))})
	if _attach.is_valid():
		_attach.call(row, port)


# ================= 图层（复合参数） =================

func _build_layers(_param: Dictionary) -> void:
	var layers := _layers()
	var head := _new_row()
	var title := Label.new()
	title.text = "图层 · %d" % layers.size()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", FxUiKit.TEXT)
	head.add_child(title)
	var add := Button.new()
	add.text = "+ 层"
	add.custom_minimum_size = Vector2(44, 22)
	add.add_theme_font_size_override("font_size", 11)
	add.tooltip_text = "从顶部加一层（端口按稳定 id 生成）"
	add.pressed.connect(_add_layer)
	head.add_child(add)
	_place_row(head)

	for i in range(layers.size()):
		_build_layer_rows(i, layers[i])


## 一层 = 一行：端口 + 图层名 + 混合 + 透明度 + 位移 X/Y + 显隐 + 排序/删除。
## 端口（layer_<id>）就长在这一行左侧，所以「这一层吃什么图」和它的参数是同一个视觉单元。
## 一层 = 一行：端口 + 图层名 + 混合 + 透明度 + 位移 X/Y + ◆ + 显 + 排序/删除。
## ◆ 把这一层的透明度 / 位移 / 显隐一起打上关键帧，之后由轨道驱动。
func _build_layer_rows(index: int, raw_layer: Variant) -> void:
	var layer: Dictionary = raw_layer if raw_layer is Dictionary else {}
	var layer_id := String(layer.get("id", str(index)))

	var row := _new_row()
	row.add_theme_constant_override("separation", 3)

	var name_edit := LineEdit.new()
	name_edit.text = String(layer.get("name", "图层 %d" % (index + 1)))
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.custom_minimum_size = Vector2(64, 22)
	name_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_edit.add_theme_font_size_override("font_size", 11)
	name_edit.tooltip_text = "图层名（同时作为端口标签）"
	row.add_child(name_edit)

	var blend := OptionButton.new()
	blend.custom_minimum_size = Vector2(62, 22)
	blend.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	blend.add_theme_font_size_override("font_size", 10)
	for mode in FxImageUtil.MODES:
		var mode_index := blend.item_count
		blend.add_item(_blend_label(mode), mode_index)
		blend.set_item_metadata(mode_index, mode)
	blend.tooltip_text = "混合模式"
	var current_blend := String(layer.get("blend", "normal"))
	for i in range(blend.item_count):
		if String(blend.get_item_metadata(i)) == current_blend:
			blend.select(i)
			break
	row.add_child(blend)

	var opacity := _layer_spin(0.0, 1.0, 0.01,
		clampf(FxGraphFacade.access().as_number(_layer_display(layer, "opacity", 1.0), 1.0), 0.0, 1.0), "α")
	opacity.tooltip_text = "不透明度"
	row.add_child(opacity)

	var offset := FxGraphFacade.access().as_vec2(_layer_display(layer, "offset", [0, 0]), Vector2.ZERO)
	var ox := _layer_spin(-4096, 4096, 1, offset.x, "X")
	var oy := _layer_spin(-4096, 4096, 1, offset.y, "Y")
	ox.tooltip_text = "水平位移"
	oy.tooltip_text = "垂直位移"
	row.add_child(ox)
	row.add_child(oy)

	var key_button := _mini_button("○", "这一层的透明度 / 位移 / 显隐打关键帧")
	key_button.custom_minimum_size = Vector2(16, 22)
	key_button.pressed.connect(_toggle_layer_track.bind(index))
	_layer_keys[index] = key_button
	row.add_child(key_button)

	var visible_button := _mini_button("显", "显示 / 隐藏该层")
	visible_button.toggle_mode = true
	visible_button.button_pressed = FxGraphFacade.access().as_bool(
		_layer_display(layer, "visible", true), true)
	visible_button.add_theme_color_override("font_color",
		FxUiKit.ACCENT if visible_button.button_pressed else FxUiKit.MUTED)
	row.add_child(visible_button)
	var up := _mini_button("↑", "上移一层")
	up.pressed.connect(_move_layer.bind(index, -1))
	row.add_child(up)
	var down := _mini_button("↓", "下移一层")
	down.pressed.connect(_move_layer.bind(index, 1))
	row.add_child(down)
	var remove := _mini_button("×", "删除该层")
	remove.pressed.connect(_delete_layer.bind(index))
	row.add_child(remove)

	_place_row(row, _port_specs.get("layer_%s" % layer_id, {}))

	name_edit.text_submitted.connect(func(_t: String) -> void: _set_layer_name(index, name_edit.text))
	name_edit.focus_exited.connect(func() -> void: _set_layer_name(index, name_edit.text))
	visible_button.toggled.connect(func(pressed: bool) -> void:
		visible_button.add_theme_color_override("font_color",
			FxUiKit.ACCENT if pressed else FxUiKit.MUTED)
		_set_layer_field(index, "visible", pressed, false)
	)
	blend.item_selected.connect(func(item: int) -> void:
		_set_layer_field(index, "blend", String(blend.get_item_metadata(item)), false)
	)
	opacity.value_changed.connect(func(value: float) -> void:
		_set_layer_field(index, "opacity", clampf(value, 0.0, 1.0), false)
	)
	ox.value_changed.connect(func(_v: float) -> void:
		_set_layer_field(index, "offset", [ox.value, oy.value], false)
	)
	oy.value_changed.connect(func(_v: float) -> void:
		_set_layer_field(index, "offset", [ox.value, oy.value], false)
	)

	# 播放头移动时把这一行拉回本帧数值（轨道驱动时 SpinBox 不会自己变）。
	var sync := func() -> void:
		var current := _layers()
		if index < 0 or index >= current.size() or not current[index] is Dictionary:
			return
		var fresh: Dictionary = current[index]
		if not opacity.get_line_edit().has_focus():
			opacity.set_value_no_signal(clampf(FxGraphFacade.access().as_number(
				_layer_display(fresh, "opacity", 1.0), 1.0), 0.0, 1.0))
		var off := FxGraphFacade.access().as_vec2(_layer_display(fresh, "offset", [0, 0]), Vector2.ZERO)
		if not ox.get_line_edit().has_focus():
			ox.set_value_no_signal(off.x)
		if not oy.get_line_edit().has_focus():
			oy.set_value_no_signal(off.y)
		var vis := FxGraphFacade.access().as_bool(_layer_display(fresh, "visible", true), true)
		visible_button.set_pressed_no_signal(vis)
		visible_button.add_theme_color_override("font_color",
			FxUiKit.ACCENT if vis else FxUiKit.MUTED)
	_layer_syncs.append(sync)


## 图层字段显示值：被轨道驱动时取当前时间的采样值。
func _layer_display(layer: Dictionary, field: String, fallback: Variant) -> Variant:
	var raw: Variant = layer.get(field, fallback)
	if raw is Dictionary and (raw as Dictionary).has("track"):
		return FxTracks.sample(raw, time)
	return raw


## 一层的打帧 / 删帧：透明度 + 位移 + 显隐作为一组。
func _toggle_layer_track(index: int) -> void:
	var layers := _layers()
	if index < 0 or index >= layers.size() or not layers[index] is Dictionary:
		return
	var copy: Array = layers.duplicate(true)
	var layer: Dictionary = copy[index]
	var at := snappedf(time, 0.001)
	var has_key := false
	for entry in LAYER_TRACK_FIELDS:
		var raw: Variant = layer.get(String(entry[0]), entry[1])
		if raw is Dictionary and (raw as Dictionary).has("track"):
			for key in (raw as Dictionary).get("track", []):
				if key is Array and (key as Array).size() >= 1 \
						and absf(float((key as Array)[0]) - at) < 0.02:
					has_key = true
	for entry in LAYER_TRACK_FIELDS:
		var field := String(entry[0])
		var fallback: Variant = entry[1]
		var current: Variant = _layer_display(layer, field, fallback)
		var raw: Variant = layer.get(field, fallback)
		if raw is Dictionary and (raw as Dictionary).has("track"):
			var track: Dictionary = (raw as Dictionary).duplicate(true)
			var keys: Array = (track.get("track", []) as Array).duplicate(true)
			if has_key:
				for i in range(keys.size() - 1, -1, -1):
					if keys[i] is Array and absf(float((keys[i] as Array)[0]) - at) < 0.02:
						keys.remove_at(i)
				if keys.is_empty():
					layer[field] = current
					continue
			else:
				keys.append([at, _to_store(current)])
			track["track"] = FxTracks.normalize(keys, duration)
			layer[field] = track
		elif not has_key:
			layer[field] = {
				"track": [[at, _to_store(current)]],
				"interp": "step" if field == "visible" else "linear",
			}
	copy[index] = layer
	_apply_layers(copy, false)
	_refresh_keys()


func _layer_track_state(index: int) -> Dictionary:
	var layers := _layers()
	if index < 0 or index >= layers.size() or not layers[index] is Dictionary:
		return {"track": false, "key": false}
	var layer: Dictionary = layers[index]
	var state := {"track": false, "key": false}
	for entry in LAYER_TRACK_FIELDS:
		var raw: Variant = layer.get(String(entry[0]), entry[1])
		if not raw is Dictionary or not (raw as Dictionary).has("track"):
			continue
		state["track"] = true
		for key in (raw as Dictionary).get("track", []):
			if key is Array and (key as Array).size() >= 1 \
					and absf(float((key as Array)[0]) - time) < 0.02:
				state["key"] = true
	return state


func _blend_label(mode: String) -> String:
	return String({
		"normal": "正常", "add": "相加", "multiply": "正片叠底",
		"screen": "滤色", "overlay": "叠加", "subtract": "相减",
	}.get(mode, mode))


## GraphNode 的内容区没有内边距，最后一个控件会紧贴圆角；补 6px 让按钮不被裁。
func _right_pad() -> Control:
	var pad := Control.new()
	pad.custom_minimum_size.x = 6
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return pad


func _mini_button(text: String, hint: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = hint
	button.custom_minimum_size = Vector2(18, 22)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", 10)
	return button


func _layer_spin(minimum: float, maximum: float, step: float,
		value: float, prefix: String) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.prefix = prefix
	spin.custom_minimum_size = Vector2(50, 22)
	spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	spin.add_theme_font_size_override("font_size", 10)
	spin.get_line_edit().add_theme_font_size_override("font_size", 10)
	spin.set_value_no_signal(value)
	return spin


# ================= 时间 / 关键帧 =================

func set_time(value: float) -> void:
	if absf(value - time) < 0.00001:
		return
	time = value
	if _host != null and _host.is_inside_tree():
		var focus := _host.get_viewport().gui_get_focus_owner()
		if focus != null and _host.is_ancestor_of(focus) and focus is LineEdit:
			return
	refresh_values()
	_refresh_keys()


## 撤销/重做或外部改参数后，把控件显示拉回文档值。
func refresh_values() -> void:
	for row in _rows:
		var sync: Callable = row.get("sync", Callable())
		if sync.is_valid():
			sync.call()
	# 图层行不经过 FxWidgetRegistry，单独同步（轨道驱动时数值要跟着播放头走）。
	for layer_sync in _layer_syncs:
		if layer_sync.is_valid():
			layer_sync.call()


func _refresh_keys() -> void:
	for pid in _keys.keys():
		var button: Button = _keys[pid]
		if not is_instance_valid(button):
			continue
		if _has_key_at(String(pid), time):
			button.text = "◆"
			button.add_theme_color_override("font_color", FxUiKit.ACCENT)
		elif _has_track(String(pid)):
			button.text = "◇"
			button.add_theme_color_override("font_color", FxUiKit.ACCENT)
		else:
			button.text = "○"
			button.add_theme_color_override("font_color", FxUiKit.MUTED)
	for index in _layer_keys.keys():
		var layer_button: Button = _layer_keys[index]
		if not is_instance_valid(layer_button):
			continue
		var state := _layer_track_state(int(index))
		if bool(state.get("key", false)):
			layer_button.text = "◆"
			layer_button.add_theme_color_override("font_color", FxUiKit.ACCENT)
		elif bool(state.get("track", false)):
			layer_button.text = "◇"
			layer_button.add_theme_color_override("font_color", FxUiKit.ACCENT)
		else:
			layer_button.text = "○"
			layer_button.add_theme_color_override("font_color", FxUiKit.MUTED)


func _toggle_track(pid: String) -> void:
	var params: Dictionary = data.get("params", {})
	var raw: Variant = params.get(pid, _default_value(pid))
	var fallback: Variant = _display_value(pid)
	var new_raw: Variant
	if raw is Dictionary and (raw as Dictionary).has("track"):
		var track: Dictionary = (raw as Dictionary).duplicate(true)
		var keys: Array = (track.get("track", []) as Array).duplicate(true)
		var found := -1
		for i in range(keys.size()):
			var entry: Array = keys[i]
			if absf(float(entry[0]) - time) < 0.02:
				found = i
				break
		if found >= 0:
			keys.remove_at(found)
		else:
			keys.append([snappedf(time, 0.001), _to_store(fallback)])
		if keys.is_empty():
			new_raw = _to_store(fallback)
		else:
			track["track"] = FxTracks.normalize(keys, duration)
			new_raw = track
	else:
		new_raw = {
			"track": [[snappedf(time, 0.001), _to_store(fallback)]],
			"interp": "linear",
		}
	_apply_value(pid, new_raw, false)
	refresh_values()
	_refresh_keys()


func _has_track(pid: String) -> bool:
	var raw: Variant = data.get("params", {}).get(pid, null)
	return raw is Dictionary and (raw as Dictionary).has("track")


func _has_key_at(pid: String, at: float) -> bool:
	var raw: Variant = data.get("params", {}).get(pid, null)
	if not raw is Dictionary or not (raw as Dictionary).has("track"):
		return false
	for entry in (raw as Dictionary).get("track", []):
		if entry is Array and (entry as Array).size() >= 1 \
				and absf(float((entry as Array)[0]) - at) < 0.02:
			return true
	return false


# ================= 图层写回 =================

func _set_layer_name(index: int, text: String) -> void:
	var layers := _layers()
	if index < 0 or index >= layers.size():
		return
	var clean := text.strip_edges()
	if clean.is_empty() or clean == String((layers[index] as Dictionary).get("name", "")):
		return
	var copy: Array = layers.duplicate(true)
	(copy[index] as Dictionary)["name"] = clean
	_apply_layers(copy, true)


func _set_layer_field(index: int, key: String, value: Variant, structural: bool) -> void:
	var layers := _layers()
	if index < 0 or index >= layers.size():
		return
	var copy: Array = layers.duplicate(true)
	(copy[index] as Dictionary)[key] = value
	_apply_layers(copy, structural)


func _move_layer(index: int, delta: int) -> void:
	var layers := _layers()
	var target := index + delta
	if index < 0 or index >= layers.size() or target < 0 or target >= layers.size():
		return
	var copy: Array = layers.duplicate(true)
	var layer: Variant = copy[index]
	copy[index] = copy[target]
	copy[target] = layer
	_apply_layers(copy, true)


func _delete_layer(index: int) -> void:
	var layers := _layers()
	if index < 0 or index >= layers.size():
		return
	var copy: Array = layers.duplicate(true)
	copy.remove_at(index)
	_apply_layers(copy, true)


func _add_layer() -> void:
	var layers := _layers()
	var copy: Array = layers.duplicate(true)
	copy.append({
		"id": _new_layer_id(copy),
		"name": "图层 %d" % (copy.size() + 1),
		"blend": "normal",
		"opacity": 1.0,
		"offset": [0, 0],
		"visible": true,
	})
	_apply_layers(copy, true)


func _apply_layers(layers: Array, structural: bool) -> void:
	_apply_value("layers", layers, structural)


func _ensure_layer_ids(layers: Array) -> void:
	for i in range(layers.size()):
		if not layers[i] is Dictionary:
			continue
		var layer: Dictionary = layers[i]
		if not layer.has("id") or String(layer.get("id", "")).is_empty():
			layer["id"] = _new_layer_id(layers, i)
			layers[i] = layer


func _new_layer_id(layers: Array, ignore_index: int = -1) -> String:
	var used: Dictionary = {}
	for i in range(layers.size()):
		if i == ignore_index or not layers[i] is Dictionary:
			continue
		used[String((layers[i] as Dictionary).get("id", ""))] = true
	var n := 0
	while used.has(str(n)):
		n += 1
	return str(n)


func _layers() -> Array:
	var raw: Variant = data.get("params", {}).get("layers", _default_value("layers"))
	if raw is Array:
		_ensure_layer_ids(raw)
		return raw
	var fallback: Variant = _default_value("layers")
	var layers: Array = (fallback as Array).duplicate(true) if fallback is Array else []
	data.get("params", {})["layers"] = layers
	return layers


# ================= 值 / 写回 =================

func _display_value(pid: String) -> Variant:
	# 被连线驱动时，显示上游本帧给到的值（执行器回传，已是端口类型转换后的结果）。
	if _bound.has(pid) and _live.has(pid):
		return _live[pid]
	var raw: Variant = data.get("params", {}).get(pid, _default_value(pid))
	if raw is Dictionary and (raw as Dictionary).has("track"):
		return FxTracks.sample(raw, time)
	return raw


## 执行器每帧回传「本节点解析后的参数」。只有被驱动的参数会显示这些值，
## 其余参数照旧读文档 —— 所以不会把关键帧采样结果误写回文档。
func set_live_values(values: Dictionary) -> void:
	if values.is_empty() or _bound.is_empty():
		return
	var changed := false
	for pid in _bound.keys():
		if not values.has(pid):
			continue
		var next: Variant = values[pid]
		var current: Variant = _live.get(pid)
		# GDScript 对「不同类型」用 != 会直接报错（例如 Vector2 与 Array），
		# 真实工程里 vec2 参数被连线驱动时就会踩到。同类型比较才是安全的。
		var differs := typeof(current) != typeof(next)
		if not differs:
			differs = current != next
		if differs:
			_live[pid] = next
			changed = true
	if changed:
		refresh_values()


## 递归停用交互：连线驱动的参数不该被本地编辑（改了也会被上游覆盖）。
func _freeze(node: Node) -> void:
	if node is Control:
		var control: Control = node
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		control.modulate = Color(1, 1, 1, 0.55)
	for child in node.get_children():
		_freeze(child)


func _default_value(pid: String) -> Variant:
	if def == null:
		return null
	return def.param(pid).get("default", null)


func _write(pid: String, value: Variant) -> void:
	if data.is_empty():
		return
	var params: Dictionary = data.get("params", {})
	var raw: Variant = params.get(pid, _default_value(pid))
	var stored: Variant = _to_store(value)
	var new_raw: Variant = stored
	if raw is Dictionary and (raw as Dictionary).has("track"):
		var track: Dictionary = (raw as Dictionary).duplicate(true)
		track["track"] = FxTracks.upsert(track.get("track", []), time, stored, duration)
		new_raw = track
	_apply_value(pid, new_raw, false)


## 参数写回的唯一出口：走可逆效果；没有 apply_edit 时退回直接写（独立使用/旧测试）。
func _apply_value(pid: String, value: Variant, structural: bool) -> void:
	if apply_edit.is_valid():
		apply_edit.call(node_id, pid, value, structural)
	else:
		var params: Dictionary = data.get("params", {})
		params[pid] = value
		data["params"] = params


func _to_store(value: Variant) -> Variant:
	if value is Vector2:
		return [value.x, value.y]
	if value is Color:
		# Color.to_html() 不带 '#'；统一补上，文档里的颜色永远是 "#rrggbb[aa]"，
		# 轨道插值才能认出它是颜色（裸十六进制以前被当成普通文本，永不插值）。
		return "#" + (value as Color).to_html()
	if value is float:
		return snappedf(float(value), 0.0001)
	return value


# ================= 资源对话框 =================

## 只保留通用“路径”对话框；asset/font/pixelfx 由对应插件自己实现控件。
func _open_dialog(kind: String, on_pick: Callable) -> void:
	if _host == null:
		return
	var dialog := FileDialog.new()
	# 导出节点要选「写到哪」而不是「读哪个」，目录型参数还要能选目录。
	match kind:
		"save":
			dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		"dir":
			dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_:
			dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	if kind != "dir":
		dialog.add_filter("*.*", "所有文件")
	_host.add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		on_pick.call(ProjectSettings.localize_path(path))
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.6])
