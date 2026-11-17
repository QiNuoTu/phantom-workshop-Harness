class_name FxNodeValueGauge
extends VBoxContainer
## 节点卡片上的「输出值预览」：**按类型选组件**，不再手绘。
##
## 为什么不用 `_draw`：
##   手绘出来的东西不跟皮肤走、不吃主题字体、拿不到焦点与无障碍信息，
##   而且每加一种类型就要再写一段画图代码。这里全部用引擎组件拼：
##
##   number  TextureRect + CurveTexture（曲线由 Curve 资源烘成纹理，不是自己画线）
##   vec2    两个 ProgressBar（X / Y 各一条，范围 -1..1）
##   color   ColorRect（色块，透明度直接体现在颜色里）
##   bool    Label（● 着色）+ 文本
##   text    Label（超长自动裁切）
##
## 分派只有一个点 `kind_of()`：只认**端口类型名**与 Variant 形态，不认识任何节点类型，
## 所以插件新增节点不需要改这里。
##
## 两条容易忘的纪律（都在 set_samples 里）：
##   · 显示签名没变就不重排/不换纹理 —— 播放期读数每帧推，白刷纯属浪费；
##   · 值没变不追加采样 —— 否则曲线被同一个值填满，「一直没变」反而看不出来。

const HEIGHT := 46.0
## 曲线保留的采样数：够看出一个周期，又不至于把小条插成锯齿。
const HISTORY := 48
## 曲线的分段数：每段一个 ColorRect，高度编码采样值。
## 为什么不用 CurveTexture：它在 Godot 4 里是「填充到底部」的曲线纹理（给粒子/渐变用），
## 当真折线会糊成一团实心块 —— 这是实测截图当场看出来的。
const SPARK_SEGMENTS := 24

const KIND_NUMBER := "number"
const KIND_VEC2 := "vec2"
const KIND_COLOR := "color"
const KIND_BOOL := "bool"
const KIND_TEXT := "text"

## 每个端口一条历史：port -> Array[float]。只给 number 用。
var _history: Dictionary = {}
var _samples: Array = []
var _last_value: Dictionary = {}
var _last_signature: String = ""
## 每行一组组件：{root, port, port_label, spark, segs, bars, bar_x, bar_y,
##                swatch, dot, text, value}
var _rows: Array[Dictionary] = []
var _empty_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(0, HEIGHT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 0)


## 每帧（或每次求值）推一次结构化读数：`[{port, type, value, text}]`。
func set_samples(samples: Array) -> void:
	_samples = samples.duplicate()
	var appended := false
	for item in samples:
		var sample: Dictionary = item
		if kind_of(sample) != KIND_NUMBER:
			continue
		var port := String(sample.get("port", ""))
		var value := float(sample.get("value", 0.0))
		var bucket: Array = _history.get(port, [])
		if is_equal_approx(float(_last_value.get(port, NAN)), value) and not bucket.is_empty():
			continue
		bucket.append(value)
		while bucket.size() > HISTORY:
			bucket.pop_front()
		_history[port] = bucket
		_last_value[port] = value
		appended = true
	var signature := _signature_of(samples)
	if appended or signature != _last_signature:
		_last_signature = signature
		_rebuild()
	tooltip_text = _tooltip_of(samples)


## 只有一行文本时的兼容入口（旧调用方 / 没有结构化读数的插件）。
func set_text(text: String) -> void:
	set_samples([{"port": "", "type": "string", "value": text, "text": text}])


func samples() -> Array:
	return _samples


## 最近一段数值历史（测试与诊断用）。
func history_of(port: String = "") -> Array:
	for item in _samples:
		var sample: Dictionary = item
		if String(sample.get("port", "")) == port or port.is_empty():
			return (_history.get(String(sample.get("port", "")), []) as Array).duplicate()
	return []


## 某个端口的曲线分段（测试用：确认数值走的是分段色块组件，而不是手绘）。
func spark_of(port: String) -> Array:
	for row in _rows:
		if String(row.get("port", "")) == port:
			return (row["segs"] as Array).duplicate()
	return []


## 把一个读数归一成组件种类。判据顺序：先看端口声明的类型，再看实际值的形态。
## 端口类型是插件声明的，比 Variant 更可信（int 落在 number 端口里仍该画曲线）。
static func kind_of(sample: Dictionary) -> String:
	match String(sample.get("type", "")):
		"number", "int", "float":
			return KIND_NUMBER
		"vec2":
			return KIND_VEC2
		"color":
			return KIND_COLOR
		"bool":
			return KIND_BOOL
		"string", "image", "image_object":
			return KIND_TEXT
	var value: Variant = sample.get("value", null)
	if value is float or value is int:
		return KIND_NUMBER
	if value is Vector2 or value is Vector2i:
		return KIND_VEC2
	if value is Color:
		return KIND_COLOR
	if value is bool:
		return KIND_BOOL
	return KIND_TEXT


## 一行可读文本：数值旁的读数、tooltip、以及组件放不下时的兜底。
static func text_of(sample: Dictionary) -> String:
	var value: Variant = sample.get("value", null)
	match kind_of(sample):
		KIND_NUMBER:
			return "%.3f" % float(value)
		KIND_VEC2:
			var v := Vector2.ZERO
			if value is Vector2:
				v = value
			return "(%.2f, %.2f)" % [v.x, v.y]
		KIND_COLOR:
			var c := Color.BLACK
			if value is Color:
				c = value
			return "#" + c.to_html(c.a < 0.999)
		KIND_BOOL:
			return "开" if bool(value) else "关"
	var text := String(sample.get("text", ""))
	return text if not text.is_empty() else str(value)


# ================= 组件装配 =================

## 按样本重建行。最多两行：主输出 + 第二输出（多输出节点不该只看得见第一行）。
func _rebuild() -> void:
	var wanted := mini(_samples.size(), 2)
	while _rows.size() < wanted:
		_rows.append(_make_row())
	if _rows.size() > wanted:
		for i in range(_rows.size() - 1, wanted - 1, -1):
			var extra: Dictionary = _rows[i]
			(extra["root"] as Control).queue_free()
			_rows.remove_at(i)
	if wanted == 0:
		_ensure_empty_label()
		return
	if _empty_label != null:
		_empty_label.visible = false
	for i in range(wanted):
		_fill_row(_rows[i], _samples[i] as Dictionary)


func _ensure_empty_label() -> void:
	if _empty_label == null:
		_empty_label = FxUiKit.label("等待求值…", 10, FxUiKit.MUTED)
		_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_empty_label)
	_empty_label.visible = true


## 一行骨架：端口名 / 组件区 / 读数。五类控件一次建好、按类型显隐 ——
## 每次重排都销毁重建会闪，也会打断 tooltip。
func _make_row() -> Dictionary:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, HEIGHT / 2.0)
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	var port_label := FxUiKit.label("", 9, FxUiKit.MUTED)
	port_label.custom_minimum_size = Vector2(26, 0)
	port_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(port_label)

	# 组件区用容器排：原来的裸 Control + 锚点会让色块高度算成 0（实测截图里色块整个消失）。
	var body := HBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	row.add_child(body)

	# 曲线：一段采样一个 ColorRect，高度编码数值 —— 纯组件，没有手绘。
	var spark := Control.new()
	spark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(spark)
	var segs: Array[ColorRect] = []
	for i in range(SPARK_SEGMENTS):
		var seg := ColorRect.new()
		seg.color = FxUiKit.ACCENT_COOL
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seg.visible = false
		spark.add_child(seg)
		segs.append(seg)
	spark.resized.connect(_on_spark_resized.bind(spark))

	# 向量：X / Y 两条进度条，按正负决定填充方向（负数向左长）。
	var bars := VBoxContainer.new()
	bars.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bars.add_theme_constant_override("separation", 2)
	body.add_child(bars)
	var bar_x := _make_bar(FxUiKit.ACCENT_COOL)
	var bar_y := _make_bar(FxUiKit.ACCENT)
	bars.add_child(bar_x)
	bars.add_child(bar_y)

	# 颜色：色块。透明度直接体现在颜色里，不再叠棋盘（那是手绘）。
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(26, 16)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(swatch)

	# 布尔：着色圆点 + 文本。
	var dot := FxUiKit.label("●", 12, FxUiKit.BORDER)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(dot)

	# 文本：裁切显示，完整内容在 tooltip 里。
	var text := FxUiKit.label("", 10, FxUiKit.TEXT)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.clip_text = true
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(text)

	var value_label := FxUiKit.label("", 11, FxUiKit.ACCENT_COOL)
	value_label.custom_minimum_size = Vector2(64, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(value_label)

	return {"root": row, "port": "", "port_label": port_label, "body": body,
		"spark": spark, "segs": segs, "bars": bars,
		"bar_x": bar_x, "bar_y": bar_y, "swatch": swatch, "dot": dot,
		"text": text, "value": value_label}


func _make_bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.001
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 7)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(2)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.35)
	bg.set_corner_radius_all(2)
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", bg)
	return bar


## 把一条读数灌进已有行：切显隐、换值、必要时重烘曲线。
func _fill_row(row: Dictionary, sample: Dictionary) -> void:
	var kind := kind_of(sample)
	var port := String(sample.get("port", ""))
	row["port"] = port
	(row["port_label"] as Label).text = port
	(row["spark"] as Control).visible = kind == KIND_NUMBER
	(row["bars"] as Control).visible = kind == KIND_VEC2
	(row["swatch"] as Control).visible = kind == KIND_COLOR
	(row["dot"] as Control).visible = kind == KIND_BOOL
	(row["text"] as Control).visible = kind == KIND_TEXT
	(row["value"] as Label).visible = kind != KIND_BOOL and kind != KIND_TEXT
	(row["value"] as Label).text = text_of(sample)
	match kind:
		KIND_NUMBER:
			_fill_spark(row, port)
		KIND_VEC2:
			var v := Vector2.ZERO
			if sample.get("value") is Vector2:
				v = sample["value"]
			# 负数向左长、正数向右长：用 fill_mode 表达方向，比「从 0 填到 0.62」直观。
			_set_bar(row["bar_x"] as ProgressBar, v.x)
			_set_bar(row["bar_y"] as ProgressBar, v.y)
		KIND_COLOR:
			var c := Color.BLACK
			if sample.get("value") is Color:
				c = sample["value"]
			(row["swatch"] as ColorRect).color = c
		KIND_BOOL:
			var on := bool(sample.get("value", false))
			var dot := row["dot"] as Label
			dot.add_theme_color_override("font_color", FxUiKit.OK if on else FxUiKit.BORDER)
			dot.text = "● 开" if on else "● 关"
		_:
			(row["text"] as Label).text = text_of(sample)


## 数值：把最近 SPARK_SEGMENTS 个采样画成等宽色块，高度按本段最小/最大值归一。
## 采样不足时就只亮前几段；全等时给一点余量，让「一直没变」显示成一条齐平的短线。
func _fill_spark(row: Dictionary, port: String) -> void:
	var segs: Array = row["segs"]
	var spark: Control = row["spark"]
	var values: Array = _history.get(port, [])
	var start := maxi(values.size() - SPARK_SEGMENTS, 0)
	var shown: Array = values.slice(start) if not values.is_empty() else []
	var width := maxf(spark.size.x, 24.0)
	var height := maxf(spark.size.y, 8.0)
	if shown.is_empty():
		for seg in segs:
			(seg as ColorRect).visible = false
		return
	var lo := INF
	var hi := -INF
	for raw in shown:
		lo = minf(lo, float(raw))
		hi = maxf(hi, float(raw))
	if is_equal_approx(lo, hi):
		lo -= 0.5
		hi += 0.5
	var step := width / float(SPARK_SEGMENTS)
	for i in range(SPARK_SEGMENTS):
		var seg: ColorRect = segs[i]
		if i >= shown.size():
			seg.visible = false
			continue
		var t := (float(shown[i]) - lo) / (hi - lo)
		var h := maxf(clampf(t, 0.0, 1.0) * height, 1.0)
		seg.visible = true
		seg.position = Vector2(float(i) * step, height - h)
		seg.size = Vector2(maxf(step - 1.0, 1.0), h)


## 布局一变（节点被拖大/窗口缩放），分段位置要按新宽度重算 ——
## 否则色块会停在旧宽度上，卡看起来像「被切掉一截」。
func _on_spark_resized(spark: Control) -> void:
	for row in _rows:
		if row.get("spark") == spark:
			var port := String(row.get("port", ""))
			if _history.has(port) or not _samples.is_empty():
				_fill_spark(row, port)
			return


## 进度条按正负决定填充方向：负数左长、正数右长，0 就是一条空条。
func _set_bar(bar: ProgressBar, value: float) -> void:
	var v := clampf(value, -1.0, 1.0)
	bar.fill_mode = ProgressBar.FILL_BEGIN_TO_END if v >= 0.0 else ProgressBar.FILL_END_TO_BEGIN
	bar.value = absf(v)


## 显示签名：判断这次推送会不会改变画面，一样就不重排。
static func _signature_of(samples: Array) -> String:
	var parts: Array[String] = []
	for item in samples:
		var sample: Dictionary = item
		parts.append("%s|%s|%s" % [String(sample.get("port", "")),
			kind_of(sample), text_of(sample)])
	return " / ".join(PackedStringArray(parts))


## 完整读数放进 tooltip：卡片放不下时鼠标停一下就能看到全部输出。
func _tooltip_of(samples: Array) -> String:
	var lines: Array[String] = []
	for item in samples:
		var sample: Dictionary = item
		var port := String(sample.get("port", ""))
		var head := port if not port.is_empty() else String(sample.get("type", ""))
		lines.append("%s = %s" % [head, text_of(sample)])
	return "\n".join(PackedStringArray(lines))

## 向量行当前的有符号值（测试用：确认方向语义与组件接线都对）。
## 进度条本身只存 0..1 的幅度，符号在 fill_mode 上，这里把它还原回来。
func bars_of(port: String) -> Vector2:
	for row in _rows:
		if String(row.get("port", "")) == port:
			var bx := row["bar_x"] as ProgressBar
			var by := row["bar_y"] as ProgressBar
			var sx := bx.value if bx.fill_mode == ProgressBar.FILL_BEGIN_TO_END else -bx.value
			var sy := by.value if by.fill_mode == ProgressBar.FILL_BEGIN_TO_END else -by.value
			return Vector2(sx, sy)
	return Vector2.ZERO
