class_name FxGraphNodeView
extends GraphNode
## 一个节点的视图：标题、端口行、内联参数行、当前帧预览。
##
## 参数行就是节点的一行：标签 + 控件 + 关键帧按钮；可绑定参数（radius/offset/...）
## 的输入端口直接长在这一行左侧，不再另起一个同名端口行，也不在节点底部堆一块面板。
##
## 端口完全由 FxGraphFacade.access().catalog_ports() 生成 —— 这个类不认识任何具体节点类型。
## 动态端口（输出图层、序列出口）在参数变化后由编辑器重建视图，连线按端口 id 恢复。

const PREVIEW_HEIGHT := 92
const NODE_WIDTH := 304.0

var node_id: String = ""
var def: FxNodeDef
var node_data: Dictionary = {}

var slot_left: Dictionary = {}
var slot_right: Dictionary = {}
var left_slots: Array[int] = []
var right_slots: Array[int] = []

var params_ui: FxNodeParams = null

var _preview: TextureRect
var store: FxDocumentStore = null
var apply_edit: Callable = Callable()
var _fiber: FxFiber = null

## 折叠只作用于**下方那块预览图**：参数与端口行一律不动，
## 因此收起不会改变插槽数量，GraphEdit 的端口缓存不会失效（那是越界报错的来源）。
## 默认由编辑器根据设置指定；这里给 true，避免 setup() 到 set_collapsed() 之间闪一下预览。
var collapsed: bool = true
var collapse_changed: Callable = Callable()
## 用户拖右下角改过尺寸后回调编辑器，重建时按记录恢复。
var size_changed: Callable = Callable()
var node_size: Vector2 = Vector2.ZERO
var _collapse_button: Button
var _summary_label: Label
var _body_rows: Array[Dictionary] = []
## 收起前的尺寸：展开时还原用户拖出来的大小（没拖过就是自然高度）。
var _expanded_size: Vector2 = Vector2.ZERO


func setup(p_node_id: String, p_def: FxNodeDef, p_node_data: Dictionary,
		p_store: FxDocumentStore = null, p_apply_edit: Callable = Callable()) -> void:
	node_id = p_node_id
	def = p_def
	node_data = p_node_data
	store = p_store
	apply_edit = p_apply_edit
	name = node_id
	title = "%s   %s" % [FxI18n.text(def.label), node_id]
	custom_minimum_size = Vector2(NODE_WIDTH + (48.0 if def.is_output else 0.0), 0)
	var pos: Array = p_node_data.get("pos", [0, 0])
	position_offset = Vector2(float(pos[0]), float(pos[1]))
	_rebuild()
	resize_request.connect(_on_resize_request)


func _rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	slot_left.clear()
	slot_right.clear()
	left_slots.clear()
	right_slots.clear()
	_preview = null
	params_ui = null
	_expanded_size = Vector2.ZERO

	var ports: Dictionary = FxGraphFacade.access().catalog_ports(def, node_data.get("params", {}))
	var inputs: Array = ports.get("inputs", [])
	var outputs: Array = ports.get("outputs", [])
	var exec_in: Dictionary = {}
	var exec_out: Dictionary = {}
	var data_inputs: Array = []
	var data_outputs: Array = []
	var param_ports: Dictionary = {}
	for p in inputs:
		var port: Dictionary = p
		if StringName(port.get("type", "")) == FxGraphFacade.access().port_exec() and exec_in.is_empty():
			exec_in = port
		elif bool(port.get("param", false)):
			param_ports[String(port.get("id", ""))] = port
		else:
			data_inputs.append(port)
	for p in outputs:
		var port2: Dictionary = p
		if StringName(port2.get("type", "")) == FxGraphFacade.access().port_exec() and exec_out.is_empty():
			exec_out = port2
		else:
			data_outputs.append(port2)

	if not exec_in.is_empty() or not exec_out.is_empty():
		_add_row(exec_in, exec_out)
	# 参数与端口同 id 时只保留一行：端口贴在参数行左侧，
	# 否则「向量」这类节点会出现两行 X / 两行 Y。
	var param_ids: Dictionary = {}
	for prm in def.params:
		param_ids[String((prm as Dictionary).get("id", ""))] = true
	for p in data_inputs:
		var in_id := String((p as Dictionary).get("id", ""))
		# 图层端口（layer_<id>）由 FxNodeParams 画在对应图层的参数行上，
		# 这样「图层名 + 混合 + 透明度 + 位移 + 端口」是同一行。
		if param_ids.has(in_id) or in_id.begins_with("layer_"):
			param_ports[in_id] = p
			continue
		_add_row(p, {})
	_add_params(param_ports)
	for p in data_outputs:
		_add_row({}, p)
	if _has_image_output(data_outputs):
		_add_preview_row()
	_add_collapse_row()
	# 重建阶段只同步可见性：尺寸由编辑器按记录恢复，别在这里抢先重算。
	_apply_collapse(false)
	_create_time_fiber()


## 只有会产出图像输出的节点才占用预览区高度；纯数值 / 布尔 / 文本节点直接收起。
func _has_image_output(outputs: Array) -> bool:
	for p in outputs:
		if String((p as Dictionary).get("type", "")) == "image":
			return true
	return false


## 参数行：由 FxNodeParams 生成，端口贴在行左。
func _add_params(param_ports: Dictionary) -> void:
	if def == null or def.params.is_empty():
		return
	var duration := 1.0
	var now := 0.0
	if store != null:
		duration = float(FxGraphFacade.access().doc_timeline(store.doc).get("duration", 1.0))
		now = store.current_time
	params_ui = FxNodeParams.new()
	params_ui.mount(self, node_id, def, node_data, now, duration, apply_edit, _attach_row,
		param_ports, store, _bound_params(param_ports))
	# 端口表里存在、但没有对应参数行的（理论上不该有）：补成普通端口行。
	# 图层端口由图层行自己消费，这里不能再补一行。
	for pid in param_ports.keys():
		if String(pid).begins_with("layer_"):
			continue
		if not _params_has_row(String(pid)):
			_add_row(param_ports[pid], {})


## 哪些参数行有连线接入：参数端口就是参数本身，查一次入边即可。
## 图层端口（layer_<id>）吃的是图像，不算「参数被驱动」。
func _bound_params(param_ports: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if store == null:
		return out
	for pid in param_ports.keys():
		var key := String(pid)
		if key.begins_with("layer_"):
			continue
		var edge := FxGraphFacade.access().doc_edge_into(store.doc, node_id, key)
		if not edge.is_empty():
			out[key] = true
	return out


func _params_has_row(pid: String) -> bool:
	if def == null:
		return false
	for p in def.params:
		if String((p as Dictionary).get("id", "")) == pid:
			return true
	return false


func _attach_row(row: Control, port: Dictionary) -> void:
	var slot := row.get_index()
	if port.is_empty():
		set_slot(slot, false, 0, Color(0, 0, 0, 0), false, 0, Color(0, 0, 0, 0))
		return
	var type_name: Variant = port.get("type", "")
	set_slot(slot, true, FxGraphFacade.access().port_id_of(type_name), FxGraphFacade.access().port_color_of(type_name),
		false, 0, Color(0, 0, 0, 0))
	slot_left[slot] = String(port.get("id", ""))
	left_slots.append(slot)


func _create_time_fiber() -> void:
	if store == null or params_ui == null:
		return
	var fiber_component := FxComponent.new()
	fiber_component.inject = ["time"]
	fiber_component.label = "node-params:" + node_id
	fiber_component.on_coeffects = func(_ctx: FxContext, keys: Array) -> void:
		if keys.has("time") and is_instance_valid(params_ui):
			params_ui.set_time(store.current_time)
	_fiber = store.use(fiber_component, {}, null)


func _exit_tree() -> void:
	if _fiber != null and is_instance_valid(_fiber):
		_fiber.dispose()
		_fiber = null


func _add_row(in_port: Dictionary, out_port: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size.y = 22

	var in_label := Label.new()
	in_label.text = String(in_port.get("label", "")) if not in_port.is_empty() else ""
	in_label.add_theme_font_size_override("font_size", 11)
	if not in_port.is_empty():
		in_label.add_theme_color_override("font_color", FxGraphFacade.access().port_color_of(in_port.get("type", "")))
	in_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(in_label)

	var out_label := Label.new()
	out_label.text = String(out_port.get("label", "")) if not out_port.is_empty() else ""
	out_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	out_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out_label.add_theme_font_size_override("font_size", 11)
	if not out_port.is_empty():
		out_label.add_theme_color_override("font_color", FxGraphFacade.access().port_color_of(out_port.get("type", "")))
	out_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(out_label)

	add_child(row)
	var slot := row.get_index()
	var has_in := not in_port.is_empty()
	var has_out := not out_port.is_empty()
	var in_type := FxGraphFacade.access().port_id_of(in_port.get("type", "")) if has_in else 0
	var out_type := FxGraphFacade.access().port_id_of(out_port.get("type", "")) if has_out else 0
	var in_color := FxGraphFacade.access().port_color_of(in_port.get("type", "")) if has_in else Color(0, 0, 0, 0)
	var out_color := FxGraphFacade.access().port_color_of(out_port.get("type", "")) if has_out else Color(0, 0, 0, 0)
	set_slot(slot, has_in, in_type, in_color, has_out, out_type, out_color)
	if has_in:
		slot_left[slot] = String(in_port.get("id", ""))
		left_slots.append(slot)
	if has_out:
		slot_right[slot] = String(out_port.get("id", ""))
		right_slots.append(slot)


func _add_preview_row() -> void:
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(0, PREVIEW_HEIGHT)
	# 拖大节点时预览一起变高，而不是留一块空白。
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview.modulate = Color(1, 1, 1, 0.96)
	add_child(_preview)
	var slot := _preview.get_index()
	set_slot(slot, false, 0, Color(0, 0, 0, 0), false, 0, Color(0, 0, 0, 0))


## 折叠行：左侧是摘要（收起时才显示），右侧一个 ▾ / ▸ 小三角。
## 收起的只是「没接线的参数行 + 预览」；已接线的参数行与全部端口行留在原处，
## 所以节点变矮了，连线也不会错位。
func _add_collapse_row() -> void:
	# 只有带预览的节点才需要这个三角；纯数值节点本来就没有可收的东西。
	if _preview == null:
		return
	_summary_label = Label.new()
	_summary_label.text = ""
	_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_label.clip_text = true
	_summary_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_summary_label.add_theme_font_size_override("font_size", 10)
	_summary_label.add_theme_color_override("font_color", FxUiKit.MUTED)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.custom_minimum_size.y = 16
	row.add_child(_summary_label)

	_collapse_button = Button.new()
	_collapse_button.flat = true
	_collapse_button.focus_mode = Control.FOCUS_NONE
	_collapse_button.custom_minimum_size = Vector2(18, 16)
	_collapse_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	_collapse_button.add_theme_font_size_override("font_size", 9)
	_collapse_button.add_theme_color_override("font_color", FxUiKit.MUTED)
	_collapse_button.pressed.connect(_toggle_collapse)
	row.add_child(_collapse_button)

	add_child(row)
	var slot := row.get_index()
	set_slot(slot, false, 0, Color(0, 0, 0, 0), false, 0, Color(0, 0, 0, 0))
	# 可拖右下角改尺寸（预览节点需要更大的观察窗）。
	resizable = true


func _toggle_collapse() -> void:
	collapsed = not collapsed
	_apply_collapse(true)
	if collapse_changed.is_valid():
		collapse_changed.call(node_id, collapsed)


## 外部（编辑器重建时）设置折叠状态：不动尺寸，调用方随后会按记录恢复尺寸。
func set_collapsed(value: bool) -> void:
	collapsed = value
	_apply_collapse(false)


## 重建后按「内容最小尺寸」把收起的节点压矮（不改用户拖过的尺寸记录）。
## 编辑器只在没有记录尺寸时调它，所以不会覆盖用户手动调整。
func fit_collapsed() -> void:
	if collapsed and is_inside_tree() and _preview != null:
		size = Vector2(size.x, 0.0)


## 撤销/重做后文档里的节点 Dictionary 会被换掉；把视图与参数行指回新对象，
## 否则参数控件一直读的是旧快照（表现为「显示了上一次的值」）。
func sync_document_data(new_data: Dictionary) -> void:
	if new_data.is_empty():
		return
	node_data = new_data
	if params_ui != null:
		params_ui.data = new_data


func _apply_collapse(refit: bool = true) -> void:
	if _preview == null or _collapse_button == null or not is_instance_valid(_collapse_button):
		return
	_preview.visible = not collapsed
	if is_instance_valid(_summary_label):
		_summary_label.text = "预览已收起" if collapsed else ""
	_collapse_button.text = "▶" if collapsed else "▼"
	_collapse_button.tooltip_text = "展开预览" if collapsed else "收起预览"
	if refit:
		_refit_size.call_deferred()


## 折叠后必须**重新贴合内容高度**：GraphNode 的最小尺寸只统计可见子节点，
## 把预览藏起来再 size.y = 0（会被夹到最小尺寸）就正好收成内容高度。
## 展开时同理长回自然高度；用户拖过的尺寸优先还原。
func _refit_size() -> void:
	if not is_inside_tree():
		return
	if collapsed:
		if _expanded_size == Vector2.ZERO:
			_expanded_size = size
		size = Vector2(size.x, 0.0)
	else:
		if _expanded_size != Vector2.ZERO:
			size = Vector2(maxf(_expanded_size.x, size.x), _expanded_size.y)
			_expanded_size = Vector2.ZERO
		else:
			size = Vector2(size.x, 0.0)
	node_size = size
	if size_changed.is_valid():
		size_changed.call(node_id, size)


func _on_resize_request(new_size: Vector2) -> void:
	var clamped := Vector2(maxf(new_size.x, 220.0), maxf(new_size.y, 60.0))
	size = clamped
	node_size = clamped
	if size_changed.is_valid():
		size_changed.call(node_id, clamped)


## 预览图来自执行器的 node_previewed 信号，已经是缩小后的 Image。
func set_preview(image: Image) -> void:
	if _preview == null or image == null:
		return
	var existing := _preview.texture as ImageTexture
	if existing != null and existing.get_width() == image.get_width() \
			and existing.get_height() == image.get_height():
		existing.update(image)
	else:
		_preview.texture = ImageTexture.create_from_image(image)


## 撤销/重做后刷新参数行显示。
func sync_params() -> void:
	if params_ui != null:
		params_ui.refresh_values()


## 执行器回传的本节点参数：被连线驱动的那些行显示上游值。
func apply_live_params(values: Dictionary) -> void:
	if params_ui != null:
		params_ui.set_live_values(values)


func set_editor_time(time: float) -> void:
	if params_ui != null:
		params_ui.set_time(time)


# ================= 端口 / 插槽映射 =================

func slot_of_input_port(port_index: int) -> int:
	return left_slots[port_index] if port_index >= 0 and port_index < left_slots.size() else -1


func slot_of_output_port(port_index: int) -> int:
	return right_slots[port_index] if port_index >= 0 and port_index < right_slots.size() else -1


func input_port_id_at(port_index: int) -> String:
	var slot := slot_of_input_port(port_index)
	return String(slot_left.get(slot, "")) if slot >= 0 else ""


func output_port_id_at(port_index: int) -> String:
	var slot := slot_of_output_port(port_index)
	return String(slot_right.get(slot, "")) if slot >= 0 else ""


func input_port_index(port_id: String) -> int:
	for i in range(left_slots.size()):
		if String(slot_left.get(left_slots[i], "")) == port_id:
			return i
	return -1


func output_port_index(port_id: String) -> int:
	for i in range(right_slots.size()):
		if String(slot_right.get(right_slots[i], "")) == port_id:
			return i
	return -1


func is_output_node() -> bool:
	return def != null and def.is_output
