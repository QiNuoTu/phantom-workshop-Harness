class_name FxNativeWindow
extends Window
## 独立系统窗口：与「内嵌浮动窗口」并列存在的第二种分离形态。
##
## `force_native = true` 让 Godot 用真正的 OS 窗口（有自己的标题栏、可跨屏幕、
## 可 alt-tab、可最小化），而不是主窗口里的一块自绘区域。内容仍然是**同一个
## Control 实例**，关闭时原样还给停靠区，画布状态不会丢。
##
## 无头环境没有原生窗口，此时 force_native 关掉，退化成内嵌 Window 以便测试/自检。

signal geometry_changed(window_id: String, rect: Rect2)
signal redock_requested(window_id: String)

var id: String = ""
var _content: Control = null
var _closing: bool = false


static func create(p_id: String, title: String, content: Control,
		size: Vector2i) -> FxNativeWindow:
	var window := FxNativeWindow.new()
	window.setup(p_id, title, content, size)
	return window


func setup(p_id: String, title: String, content: Control, size: Vector2i) -> void:
	id = p_id
	self.title = title
	# Window 节点一进场景树就会显示；force_native 必须在显示之前设好，
	# 且期间不能让 visible=true，否则引擎报 "Can't change force_native while displayed"。
	visible = false
	force_native = DisplayServer.get_name() != "headless"
	borderless = false
	unresizable = false
	min_size = Vector2i(360, 240)
	self.size = Vector2i(maxi(size.x, 360), maxi(size.y, 240))
	position = Vector2i(140, 120)
	transient = false
	exclusive = false
	FxUiKit.style_window(self)
	_content = content
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_content)
	close_requested.connect(_on_close_requested)
	size_changed.connect(func() -> void:
		geometry_changed.emit(id, Rect2(Vector2(position), Vector2(size)))
	)


func present(_bounds: Rect2) -> void:
	# 无论原生还是内嵌都延后一帧：有些平台会把 force_native 降级成内嵌窗口，
	# 那种情况下立刻 show() 会和 popup 一样抢跑，触发 sub_window_grab_focus 报错。
	FxUiKit.popup_later(self, "show")


func present_at(rect: Rect2) -> void:
	position = Vector2i(int(rect.position.x), int(rect.position.y))
	size = Vector2i(maxi(360, int(rect.size.x)), maxi(240, int(rect.size.y)))
	FxUiKit.popup_later(self, "show")


## 与主窗口内嵌浮动窗口同名的 API，外壳不用区分两种实现。
func release_content() -> Control:
	_closing = true
	if _content == null:
		return null
	var result := _content
	remove_child(_content)
	_content = null
	return result


func raise() -> void:
	show()
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_move_to_foreground(get_window_id())


func request_redock() -> void:
	redock_requested.emit(id)


func current_rect() -> Rect2:
	return Rect2(Vector2(position), Vector2(size))


func _on_close_requested() -> void:
	if _closing:
		return
	# 只负责隐藏；window_layer 会把内容还给停靠区并释放窗口。
	hide()
