extends Control
## 曲线参数控件：**可拖的控制点**，不是让美工填数字。
##
## 值的数据形状：`[[x, y], [x, y], …]`，x/y 都在 0~1，按 x 升序。
## 两个端点（x=0 与 x=1）固定存在且只能上下拖 —— 删掉它们曲线就没有定义域了。
##
## 交互（三件事，不多不少）：
##   · 左键拖点 → 移动（x 不能越过邻居，保证单调，LUT 才不会回折）；
##   · 空白处左键 → 插入一个点并直接进入拖动；
##   · 右键点 → 删除（端点不可删，至少保留两个点）。
##
## 为什么自绘而不是拼一堆控件：曲线控件的手感全在"点跟着鼠标走、曲线实时变"，
## 用 `_draw` + 单条 polyline 是最短的路径。
##
## **别让控件把节点拖垮**（三处硬边界，都是踩过之后加的）：
##   1. **合批写入**：拖动时鼠标每动一像素都 `apply_param`，就是每秒几十次换桶 +
##      整段缓存重建 + 几十条撤销记录。现在拖动只改本地值并重画，写盘由 `_process`
##      攒到 0.12s 一次尾部写入；松手、加点、删点、重置立即 flush。
##   2. **写之前不回头读**：`sync()` 在 `_dirty` 时直接跳过 —— 否则自己刚拖到的位置
##      会被"文档里还没写入的旧值"覆盖，手感表现为"点弹回去"。
##   3. **采样规则不自己发明**：`_sample_at()` 必须与 C++ 的 `curve_lut()` 逐点一致
##      （线性分段、区间外取端点、y 钳在 0..1）。两边漂移 = "画的是 S 形、算的是别的"，
##      `test_fx_ae_pack` 里有对拍断言钉住它。

const PAD := 8.0
const POINT_RADIUS := 4.0
const HIT_RADIUS := 9.0

var value: Array = [[0.0, 0.0], [0.5, 0.5], [1.0, 1.0]]
var _ctx: Dictionary = {}
var _drag := -1
var _hover := -1

## 写入合批：拖动时只改本地值，攒够这么久再写一次文档。
const FLUSH_INTERVAL := 0.12

var _dirty := false
var _accum := 0.0

var _grid_color := Color(1, 1, 1, 0.08)
var _line_color := Color(0.36, 0.64, 1.0, 1.0)
var _point_color := Color(0.92, 0.94, 0.98, 1.0)
var _fill_color := Color(0.36, 0.64, 1.0, 0.10)


static func build(ctx: Dictionary) -> Dictionary:
	var widget := load("res://plugins/fx.tone/fx_curve_widget.gd").new() as Control
	widget.set("_ctx", ctx)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(widget)
	var buttons := VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 2)
	var reset := Button.new()
	reset.text = "重置"
	reset.tooltip_text = "恢复成一条直线（0→1）"
	reset.add_theme_font_size_override("font_size", 10)
	reset.custom_minimum_size = Vector2(46, 20)
	buttons.add_child(reset)
	var badge := Label.new()
	badge.add_theme_font_size_override("font_size", 10)
	badge.add_theme_color_override("font_color", FxUiKit.MUTED)
	buttons.add_child(badge)
	row.add_child(buttons)
	box.add_child(row)

	var sync := func() -> void:
		widget.call("sync")
		badge.text = "%d 点" % widget.points().size()
	reset.pressed.connect(func() -> void:
		widget.call("reset_linear")
		badge.text = "%d 点" % widget.points().size()
	)
	sync.call()
	return {"control": box, "sync": sync}


func _init() -> void:
	custom_minimum_size = Vector2(150, 72)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP

# 兼容 GDScript 的生命周期：_init 里已经设好了尺寸，这里只负责同步一次值。


func points() -> Array:
	return value


func reset_linear() -> void:
	# 两点太素：三段直线更能看出"这是一条可拖的曲线"。
	set_value([[0.0, 0.0], [0.5, 0.5], [1.0, 1.0]])
	flush()


## 从文档读回值（含关键帧采样后的结果），并重画。
func sync() -> void:
	if _ctx.is_empty() or _dirty:
		# 自己刚拖过、还没写盘：这时读回来的是旧值，会把点弹回去。
		return
	var raw: Variant = _ctx["get"].call() if _ctx.has("get") else null
	var parsed := _normalize(raw)
	if parsed.size() >= 2:
		value = parsed
	queue_redraw()


## 改本地值并排一次写盘（合批）。真正写文档只在 `flush()` 里发生。
func set_value(next: Array) -> void:
	var parsed := _normalize(next)
	if parsed.size() < 2:
		return
	if _same(value, parsed):
		return
	value = parsed
	_dirty = true
	set_process(true)
	queue_redraw()


## 立即写盘。离散动作（加点/删点/重置/松手）走这里，不必等 0.12s。
func flush() -> void:
	if not _dirty:
		return
	_dirty = false
	_accum = 0.0
	set_process(false)
	if not _ctx.is_empty() and _ctx.has("set"):
		_ctx["set"].call(_serialize(value))


func _process(delta: float) -> void:
	if not _dirty:
		set_process(false)
		return
	_accum += delta
	if _accum >= FLUSH_INTERVAL:
		flush()


func _exit_tree() -> void:
	# 面板被收起来/切走时，最后一次拖动不能丢。
	flush()


func _normalize(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for item in (raw as Array):
			if item is Array and (item as Array).size() >= 2:
				var x: float = clampf(float((item as Array)[0]), 0.0, 1.0)
				var y: float = clampf(float((item as Array)[1]), 0.0, 1.0)
				out.append([x, y])
	if out.size() < 2:
		out = [[0.0, 0.0], [1.0, 1.0]]
	out.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	# 端点归位：x=0 / x=1 必须存在，否则定义域缺一截。
	out[0][0] = 0.0
	out[out.size() - 1][0] = 1.0
	return out


func _serialize(source: Array) -> Array:
	var out: Array = []
	for p in source:
		out.append([snappedf(float(p[0]), 0.001), snappedf(float(p[1]), 0.001)])
	return out


func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if absf(float(a[i][0]) - float(b[i][0])) > 0.0005 \
				or absf(float(a[i][1]) - float(b[i][1])) > 0.0005:
			return false
	return true


func _plot_rect() -> Rect2:
	return Rect2(Vector2(PAD, PAD), size - Vector2(PAD * 2.0, PAD * 2.0))


func _to_screen(x: float, y: float) -> Vector2:
	var rect := _plot_rect()
	return Vector2(rect.position.x + x * rect.size.x,
		rect.position.y + (1.0 - y) * rect.size.y)


func _to_value(at: Vector2) -> Array:
	var rect := _plot_rect()
	var x: float = clampf((at.x - rect.position.x) / maxf(rect.size.x, 1.0), 0.0, 1.0)
	var y: float = clampf(1.0 - (at.y - rect.position.y) / maxf(rect.size.y, 1.0), 0.0, 1.0)
	return [x, y]


func _hit(at: Vector2) -> int:
	for i in range(value.size()):
		var p := _to_screen(float(value[i][0]), float(value[i][1]))
		if p.distance_to(at) <= HIT_RADIUS:
			return i
	return -1


func _draw() -> void:
	var rect := _plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), FxUiKit.PANEL_ALT, true)
	# 四宫格：(0.25/0.5/0.75) 三条竖线 + 三条横线，够对齐又不会盖住曲线。
	for i in range(1, 4):
		var fx: float = float(i) / 4.0
		draw_line(_to_screen(fx, 0.0), _to_screen(fx, 1.0), _grid_color, 1.0)
		draw_line(_to_screen(0.0, fx), _to_screen(1.0, fx), _grid_color, 1.0)
	draw_line(_to_screen(0.0, 0.0), _to_screen(1.0, 1.0), Color(1, 1, 1, 0.06), 1.0)
	# 曲线本体：按点分段线性采样（与算子里的 LUT 同一算法，所见即所得）。
	var steps := maxi(24, int(rect.size.x))
	var previous := _to_screen(0.0, _sample_at(0.0))
	for i in range(1, steps + 1):
		var x: float = float(i) / float(steps)
		var current := _to_screen(x, _sample_at(x))
		draw_line(previous, current, _line_color, 1.6)
		previous = current
	for i in range(value.size()):
		var p := _to_screen(float(value[i][0]), float(value[i][1]))
		var radius := POINT_RADIUS + (1.5 if i == _hover or i == _drag else 0.0)
		draw_circle(p, radius, _point_color)
		draw_circle(p, radius * 0.5, _line_color)


## 与 C++ 侧 tone.curves 的采样规则一致：找区间 → 线性插值 → 区间外取端点。
func _sample_at(x: float) -> float:
	if value.is_empty():
		return x
	if x <= float(value[0][0]):
		return float(value[0][1])
	var last: Array = value[value.size() - 1]
	if x >= float(last[0]):
		return float(last[1])
	for i in range(1, value.size()):
		var b: Array = value[i]
		var a: Array = value[i - 1]
		var x0: float = float(a[0])
		var x1: float = float(b[0])
		if x <= x1 + 0.000001:
			var span: float = maxf(x1 - x0, 0.000001)
			var u: float = clampf((x - x0) / span, 0.0, 1.0)
			return lerpf(float(a[1]), float(b[1]), u)
	return float(last[1])


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var click := event as InputEventMouseButton
		if click.button_index == MOUSE_BUTTON_RIGHT and click.pressed:
			var index := _hit(click.position)
			if index > 0 and index < value.size() - 1:
				var next := value.duplicate(true)
				next.remove_at(index)
				set_value(next)
				flush()
			accept_event()
			return
		if click.button_index == MOUSE_BUTTON_LEFT:
			if click.pressed:
				var hit := _hit(click.position)
				if hit >= 0:
					_drag = hit
				else:
					var point := _to_value(click.position)
					var next := value.duplicate(true)
					var insert_at := next.size() - 1
					for i in range(1, next.size()):
						if float(point[0]) < float(next[i][0]):
							insert_at = i
							break
					next.insert(insert_at, point)
					set_value(next)
					flush()
					_drag = insert_at
			else:
				_drag = -1
				flush()
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _drag >= 0 and _drag < value.size():
			var point := _to_value(motion.position)
			var next := value.duplicate(true)
			# x 只能在自己的邻居之间移动：单调性一破，LUT 就会"回头"，算子侧也会读错。
			var low: float = 0.0 if _drag == 0 else float(next[_drag - 1][0]) + 0.0005
			var high: float = 1.0 if _drag == next.size() - 1 else float(next[_drag + 1][0]) - 0.0005
			if _drag == 0:
				low = 0.0
				high = 0.0
			elif _drag == next.size() - 1:
				low = 1.0
				high = 1.0
			next[_drag] = [clampf(float(point[0]), minf(low, high), maxf(low, high)),
				float(point[1])]
			set_value(next)
		else:
			var hover := _hit(motion.position)
			if hover != _hover:
				_hover = hover
				queue_redraw()
		accept_event()
