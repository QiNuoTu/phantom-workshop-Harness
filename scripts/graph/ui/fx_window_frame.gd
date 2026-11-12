class_name FxWindowFrame
extends Control
## 无边框窗口的边缘缩放。
##
## 自绘标题栏之后窗口没有系统边框，缩放手感由这里补：四边 + 四角共 8 条 6px
## 的透明拖拽带，拖动时直接改 DisplayServer 的窗口位置与尺寸。
## 无头模式（测试）不安装，也不会调用任何 DisplayServer 窗口 API。

const EDGE := 6.0
const CORNER := 12.0
const MIN_SIZE := Vector2i(960, 620)

var _resizing: bool = false
var _dir: Vector2i = Vector2i.ZERO
var _start_mouse: Vector2i = Vector2i.ZERO
var _start_pos: Vector2i = Vector2i.ZERO
var _start_size: Vector2i = Vector2i.ZERO


## 给一个铺满窗口的 Control 安装缩放带；返回实例方便外壳在重建时释放。
static func install(host: Control) -> FxWindowFrame:
	var frame := FxWindowFrame.new()
	frame.name = "WindowFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(frame)
	frame._build()
	return frame


static func window_available() -> bool:
	return DisplayServer.get_name() != "headless"


func _build() -> void:
	for dir in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0),
			Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		_add_handle(dir)


func _add_handle(dir: Vector2i) -> void:
	var handle := Control.new()
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = _cursor_for(dir)
	var corner := dir.x != 0 and dir.y != 0
	var w := CORNER if corner else EDGE
	var h := CORNER if corner else EDGE
	if dir.x < 0:
		handle.anchor_left = 0.0
		handle.anchor_right = 0.0
		handle.offset_left = 0.0
		handle.offset_right = w
	elif dir.x > 0:
		handle.anchor_left = 1.0
		handle.anchor_right = 1.0
		handle.offset_left = -w
		handle.offset_right = 0.0
	else:
		handle.anchor_left = 0.0
		handle.anchor_right = 1.0
	if dir.y < 0:
		handle.anchor_top = 0.0
		handle.anchor_bottom = 0.0
		handle.offset_top = 0.0
		handle.offset_bottom = h
	elif dir.y > 0:
		handle.anchor_top = 1.0
		handle.anchor_bottom = 1.0
		handle.offset_top = -h
		handle.offset_bottom = 0.0
	else:
		handle.anchor_top = 0.0
		handle.anchor_bottom = 1.0
	handle.gui_input.connect(_on_handle_input.bind(dir))
	add_child(handle)


func _cursor_for(dir: Vector2i) -> Control.CursorShape:
	if dir.x != 0 and dir.y != 0:
		return Control.CURSOR_FDIAGSIZE if dir.x * dir.y > 0 else Control.CURSOR_BDIAGSIZE
	if dir.x != 0:
		return Control.CURSOR_HSIZE
	return Control.CURSOR_VSIZE


func _on_handle_input(event: InputEvent, dir: Vector2i) -> void:
	if not window_available():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED:
				return
			_resizing = true
			_dir = dir
			_start_mouse = DisplayServer.mouse_get_position()
			_start_pos = DisplayServer.window_get_position()
			_start_size = DisplayServer.window_get_size()
		else:
			_resizing = false
		return
	if not (event is InputEventMouseMotion) or not _resizing:
		return
	var delta := DisplayServer.mouse_get_position() - _start_mouse
	var next_pos := _start_pos
	var next_size := _start_size
	if _dir.x < 0:
		next_size.x = maxi(MIN_SIZE.x, _start_size.x - delta.x)
		next_pos.x = _start_pos.x + (_start_size.x - next_size.x)
	elif _dir.x > 0:
		next_size.x = maxi(MIN_SIZE.x, _start_size.x + delta.x)
	if _dir.y < 0:
		next_size.y = maxi(MIN_SIZE.y, _start_size.y - delta.y)
		next_pos.y = _start_pos.y + (_start_size.y - next_size.y)
	elif _dir.y > 0:
		next_size.y = maxi(MIN_SIZE.y, _start_size.y + delta.y)
	DisplayServer.window_set_position(next_pos)
	DisplayServer.window_set_size(next_size)
