class_name FxWindowLayer
extends Control
## 浮动窗口层：铺满外壳，承载插件注册的窗口。
##
## 两种宿主形态：`open()` 用自绘的内嵌浮动窗口，`open_native()` 用真正的
## OS 窗口（force_native）。同一个 content 实例可以在两者之间搬家，
## 外壳只认 `present_at / release_content / raise` 这一组鸭子类型方法。
##
## 层本身 mouse_filter=IGNORE，只有窗口接输入；这样没开窗口时它完全透明。

signal window_closed(window_id: String)
signal window_geometry_changed(window_id: String, rect: Rect2)
signal window_redock_requested(window_id: String)

var _windows: Dictionary = {}
var _closing: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func open(window_id: String, title: String, content: Control, size: Vector2i,
		singleton: bool = true) -> FxPluginWindow:
	if _windows.has(window_id):
		var existing: FxPluginWindow = _windows[window_id]
		if is_instance_valid(existing):
			existing.raise()
			return existing
		_windows.erase(window_id)
	var window := FxPluginWindow.new()
	window.setup(window_id, title, content, size)
	add_child(window)
	window.close_requested.connect(func() -> void: close(window_id))
	window.geometry_changed.connect(func(id: String, rect: Rect2) -> void:
		window_geometry_changed.emit(id, rect))
	window.redock_requested.connect(func(id: String) -> void:
		window_redock_requested.emit(id))
	window.present(Rect2(Vector2.ZERO, get_rect().size))
	window.raise()
	_windows[window_id] = window
	return window


## 独立系统窗口：force_native 的 Window 节点，可拖到第二块屏幕、可最小化。
func open_native(window_id: String, title: String, content: Control, size: Vector2i) -> FxNativeWindow:
	if _windows.has(window_id):
		var existing: Variant = _windows[window_id]
		if is_instance_valid(existing):
			existing.raise()
			return existing as FxNativeWindow
		_windows.erase(window_id)
	var window := FxNativeWindow.create(window_id, title, content, size)
	add_child(window)
	window.close_requested.connect(func() -> void: close(window_id))
	window.geometry_changed.connect(func(id: String, rect: Rect2) -> void:
		window_geometry_changed.emit(id, rect))
	window.redock_requested.connect(func(id: String) -> void:
		window_redock_requested.emit(id))
	window.present(Rect2(Vector2.ZERO, get_rect().size))
	_windows[window_id] = window
	return window


func close(window_id: String) -> void:
	if not _windows.has(window_id) or _closing.has(window_id):
		return
	var window: Variant = _windows[window_id]
	# 原生窗口的位置 OS 自己管，没有 position_changed 信号：关之前补一次几何保存。
	if window is FxNativeWindow and is_instance_valid(window):
		window_geometry_changed.emit(window_id, (window as FxNativeWindow).current_rect())
	_closing[window_id] = true
	# 先广播：分离出来的面板要赶在窗口被释放前把内容取回并重新停靠。
	window_closed.emit(window_id)
	_closing.erase(window_id)
	_windows.erase(window_id)
	if is_instance_valid(window):
		window.queue_free()


func close_all() -> void:
	for key in _windows.keys():
		var window: Variant = _windows[key]
		if is_instance_valid(window):
			window.queue_free()
	_windows.clear()


func has(window_id: String) -> bool:
	return _windows.has(window_id)


func open_ids() -> Array[String]:
	var out: Array[String] = []
	for key in _windows.keys():
		out.append(String(key))
	return out


## 返回内嵌窗口或原生窗口；调用方按鸭子类型使用，不做类型假设。
func window(window_id: String) -> Variant:
	return _windows.get(window_id)


func count() -> int:
	return _windows.size()
