class_name FxNodePicker
extends Control
## 节点创建弹窗的**抽象契约**（微内核 UI 契约，不是具体实现）。
##
## 蓝图层只通过 FxNodePickerBroker 拿到这个类型，不再 new 具体弹窗类，
## 因此「创建节点用什么 UI」变成一个可替换的插件贡献：
## 搜索面板、右键菜单、语音/命令面板、甚至无 UI 的测试桩都能实现它。
## 默认实现全部是安全空操作 —— 停用编辑器插件时蓝图不会崩，只是不能加节点。

## Emitted when the user picks a node type. [param node_type] is the definition id.
signal node_chosen(node_type: String)


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func open_at(_screen_position: Vector2) -> void:
	pass


func open_for_port(_screen_position: Vector2, _port_type: StringName,
		_want_input: bool) -> void:
	pass


func clear_port_filter() -> void:
	pass


func port_filter_active() -> bool:
	return false


func port_filter_type() -> StringName:
	return &""


func filtered_types() -> Array[String]:
	return []


func scope_count() -> int:
	return 0


func set_filter(_text: String) -> void:
	pass


func choose_type(_node_type: String) -> bool:
	return false


func reload_defs() -> void:
	pass


func hide_picker() -> void:
	hide()


# ---- 面板几何：这是一张浮层，用户可以拖走、也可以拖大拖小 ----
# 默认实现是空操作，因此一个「不支持拖拽」的实现（测试桩、命令面板）照样能用。

func panel_size() -> Vector2:
	return size


func panel_position() -> Vector2:
	return position


func resize_panel(_value: Vector2) -> void:
	pass


func move_panel_to(_value: Vector2) -> void:
	pass


func dragging() -> bool:
	return false

