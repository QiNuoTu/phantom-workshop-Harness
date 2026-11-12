class_name FxTimelinePanel
extends Control
## 底部关键帧轨道泳道：显示**全部节点**已打帧的属性，按节点分组。
##
## 数据仍然只有一份：FxTracks.collect(params)。面板不保存副本，
## doc / selection 变化时重建行；时间变化只重画播放头。
##
## 行结构：
##   节点组头（模糊 · blur，显示轨道数）
##     底色 · 透明度   ◆     ← layers.0.opacity 这类嵌套路径会解析成图层名
##     半径            ◆
##
## 交互：
##   · 滚轮翻轨；拖动播放头改时间
##   · 双击轨道行 = 在当前时间打 / 删关键帧（可撤销）
##   · 点左侧标签 = 选中该节点
##   · 左下角切换“全部轨道 / 仅选中节点”

const LABEL_W := 250.0
const RULER_H := 24.0
const GROUP_H := 18.0
const ROW_H := 20.0
const TOP_PAD := 6.0
const TRACK_H := 170.0
const SM_X := LABEL_W - 46.0
const KEY_HIT := 6.0

## 自绘调色板：值一律来自 FxUiKit（皮肤 token），换肤时由信号刷新。
var COLOR_BG: Color = Color("#0d1117")
var COLOR_PANEL: Color = Color("#151a22")
var COLOR_GROUP: Color = Color("#1b2230")
var COLOR_LINE: Color = Color("#2a3140")
var COLOR_TEXT: Color = Color("#c9d4e2")
var COLOR_MUTED: Color = Color("#8b949e")
var COLOR_ACCENT: Color = Color("#ffb454")
var COLOR_PLAYHEAD: Color = Color("#4cc2ff")
## 缓存状态色：红=没算过，黄=正在算/只有低质量预览，绿=已按精确质量缓存。
var COLOR_CACHE_EMPTY: Color = Color("#8f3a3a")
var COLOR_CACHE_PENDING: Color = Color("#d9a521")
var COLOR_CACHE_READY: Color = Color("#3fb950")

var store: FxDocumentStore
var shell: FxShell
## 渲染服务（由 core.render 贡献）：标尺上的逐帧缓存色块从它取状态。
## 用 Object + has_method 软探测，渲染插件没装/被停用也能照常画轨道。
var render: Object = null
var node_id: String = ""
var scope_all: bool = true

var _rows: Array[Dictionary] = []
var _scroll: float = 0.0
var _dragging: bool = false
var _fiber: FxFiber
## "" | "scrub"（拖播放头） | "key"（拖关键帧） | "box"（框选）
var _mode: String = ""
var _drag_start := Vector2.ZERO
var _drag_now := Vector2.ZERO
var _drag_row: int = -1
var _drag_key_index: int = -1
## 选中的关键帧：key = "row:key_index" -> 原始时间
var _selected_keys: Dictionary = {}
var _key_preview_delta: float = 0.0

## 帧率 / 帧数 / 循环：轨道上方的一行数字，直接写文档时间轴（可撤销）。
var _fps_spin: SpinBox
var _frames_spin: SpinBox
var _loop_check: Button
var _syncing_timeline: bool = false
## 关键帧剪贴板：{node, path, dt, value}，dt 相对复制时的最早一帧。
var _clipboard: Array[Dictionary] = []
var _clipboard_anchor: float = 0.0


func _ready() -> void:
	custom_minimum_size.y = TRACK_H
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 自绘面板要能收到 Delete / Ctrl+C 这类按键，必须可被点击聚焦。
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	_build_timeline_header()
	_sync_timeline_controls()


## 顶部一行：FPS / 帧数 / 循环。它们既是显示也是编辑入口，
## 写的是文档时间轴（store.set_timeline），所以和菜单、节点读到的是同一份数据。
func _build_timeline_header() -> void:
	# 一行放得下的紧凑布局：FPS [n] 帧 [n] 循环。LABEL_W = 250，正好不压到标尺。
	_add_header_label("FPS", Vector2(6, 4))
	_fps_spin = _make_spin(Vector2(30, 2), Vector2(72, 20), 1, 240, 1)
	_fps_spin.tooltip_text = "帧率（每秒帧数）"

	_add_header_label(FxI18n.text("帧"), Vector2(106, 4))
	_frames_spin = _make_spin(Vector2(122, 2), Vector2(72, 20), 1, 24000, 1)
	_frames_spin.tooltip_text = "总帧数；改它会同时改变时长"

	_loop_check = Button.new()
	_loop_check.text = FxI18n.text("循环")
	_loop_check.toggle_mode = true
	_loop_check.focus_mode = Control.FOCUS_NONE
	_loop_check.position = Vector2(198, 2)
	_loop_check.custom_minimum_size = Vector2(46, 20)
	_loop_check.add_theme_font_size_override("font_size", 10)
	_loop_check.tooltip_text = "播放到末尾后回到开头"
	add_child(_loop_check)

	_fps_spin.value_changed.connect(func(_v: float) -> void: _apply_timeline())
	_frames_spin.value_changed.connect(func(_v: float) -> void: _apply_timeline())
	_loop_check.toggled.connect(func(_p: bool) -> void: _apply_timeline())


func _add_header_label(text: String, at: Vector2) -> Label:
	var label := Label.new()
	label.text = text
	label.position = at
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", FxUiKit.MUTED)
	add_child(label)
	return label


func _make_spin(at: Vector2, box: Vector2, minimum: float, maximum: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.position = at
	spin.custom_minimum_size = box
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.add_theme_font_size_override("font_size", 10)
	spin.get_line_edit().add_theme_font_size_override("font_size", 10)
	add_child(spin)
	return spin


func _sync_timeline_controls() -> void:
	if _fps_spin == null or store == null:
		return
	var timeline := FxGraphDoc.timeline(store.doc)
	var fps := maxi(1, int(timeline.get("fps", 30)))
	var duration := maxf(0.001, float(timeline.get("duration", 1.0)))
	_syncing_timeline = true
	_fps_spin.set_value_no_signal(fps)
	_frames_spin.set_value_no_signal(maxi(1, int(round(duration * float(fps)))))
	_loop_check.set_pressed_no_signal(bool(timeline.get("loop", true)))
	_syncing_timeline = false


func _apply_timeline() -> void:
	if _syncing_timeline or store == null:
		return
	var fps := maxi(1, int(round(_fps_spin.value)))
	var frames := maxi(1, int(round(_frames_spin.value)))
	store.set_timeline(fps, float(frames) / float(fps), _loop_check.button_pressed)
	_sync_timeline_controls()
	queue_redraw()


## 面板工厂：外壳用这个 Callable 创建实例。
static func create(ctx: Dictionary) -> Control:
	var panel := FxTimelinePanel.new()
	panel.shell = ctx.get("shell")
	panel.setup(ctx.get("store"))
	return panel


func setup(p_store: FxDocumentStore) -> void:
	store = p_store
	_sync_palette()
	if shell != null and shell.has_signal("skin_changed") and not shell.skin_changed.is_connected(_sync_palette):
		shell.skin_changed.connect(_sync_palette)
	var component := FxComponent.make(["selection", "time", "doc"],
		Callable(), Callable(self, "_on_coeffects"), "timeline")
	_fiber = store.use(component, {}, null)
	_bind_render()
	# 播放推进走 store.time_ticked（不走全量广播），这里补一次重绘让播放头跟着动。
	if not store.time_ticked.is_connected(_on_time_ticked):
		store.time_ticked.connect(_on_time_ticked)
	_rebuild_tracks()
	queue_redraw()


## 皮肤切换后重取自绘颜色（Control._draw 不走 Theme）。
## 参数匹配 FxShell.skin_changed(skin_id: String)；默认值让手动调用也成立。
func _sync_palette(_skin_id: String = "") -> void:
	COLOR_BG = FxUiKit.BG
	COLOR_PANEL = FxUiKit.PANEL
	COLOR_GROUP = FxUiKit.PANEL_ALT
	COLOR_LINE = FxUiKit.BORDER
	COLOR_TEXT = FxUiKit.TEXT
	COLOR_MUTED = FxUiKit.MUTED
	COLOR_ACCENT = FxUiKit.ACCENT
	COLOR_PLAYHEAD = FxUiKit.ACCENT_COOL
	queue_redraw()


## 绑定渲染服务的缓存信号：有就订阅，没有就只是不画色块。
func _bind_render() -> void:
	if shell == null or not shell.has_method("service"):
		return
	var service: Variant = shell.call("service", "render")
	if service == null or not (service is Object):
		return
	var object := service as Object
	if not object.has_method("cache_state"):
		return
	render = object
	if object.has_signal("cache_changed") \
			and not object.is_connected("cache_changed", Callable(self, "_on_cache_changed")):
		object.connect("cache_changed", Callable(self, "_on_cache_changed"))


func _on_cache_changed(_stats: Dictionary) -> void:
	queue_redraw()


func _on_time_ticked(_t: float) -> void:
	queue_redraw()


## 标尺下沿的逐帧色带：每帧一个小方块，颜色 = 缓存状态。
## 帧多到画不下时按整步抽样（宁可少画，也不让 _draw 变成几千次调用）。
func _draw_cache_strip(font: Font, lane_x: float, lane_w: float, _duration: float) -> void:
	if render == null or not is_instance_valid(render):
		return
	if not render.has_method("cache_state") or not render.has_method("frame_count"):
		return
	var count := int(render.call("frame_count"))
	if count <= 0 or lane_w <= 4.0:
		return
	var step := maxi(1, int(ceil(float(count) / lane_w * 2.0)))
	var block := maxf(lane_w * float(step) / float(count), 1.0)
	var y := TOP_PAD + 13.0
	var h := 5.0
	var index := 0
	while index < count:
		var x := lane_x + lane_w * float(index) / float(count)
		var color := COLOR_CACHE_EMPTY
		match int(render.call("cache_state", index)):
			2:
				color = COLOR_CACHE_READY
			1:
				color = COLOR_CACHE_PENDING
		draw_rect(Rect2(x, y, maxf(block - 0.5, 1.0), h), color)
		index += step
	# 小图例：不占轨道，贴在标尺右侧空隙里。
	var legend := "%d 帧" % count
	var legend_w := font.get_string_size(legend, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
	draw_string(font, Vector2(lane_x + lane_w - legend_w - 2.0, TOP_PAD + 11.0), legend,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 9, COLOR_MUTED)


func set_node(id: String) -> void:
	node_id = id
	# 首次 setup 时组件还是 INACTIVE，激活不会回调 on_coeffects；
	# 这里总是重建一次，保证装载文档后立刻能看到轨道。
	_rebuild_tracks()
	_ensure_visible()
	queue_redraw()


func set_scope_all(value: bool) -> void:
	scope_all = value
	_scroll = 0.0
	_rebuild_tracks()
	queue_redraw()


## 命令：空格播放/暂停；菜单里另有逐帧。
static func cmd_toggle_playback(ctx: Dictionary) -> void:
	var render: FxRenderService = ctx.get("render")
	if render != null:
		render.toggle_playback()


static func cmd_goto_start(ctx: Dictionary) -> void:
	var store: FxDocumentStore = ctx.get("store")
	if store != null:
		store.set_time(0.0)


static func cmd_step(ctx: Dictionary, direction: int) -> void:
	var store: FxDocumentStore = ctx.get("store")
	if store == null:
		return
	var fps := maxf(1.0, float(FxGraphDoc.timeline(store.doc).get("fps", 30)))
	store.set_time(store.current_time + direction / fps)


static func cmd_step_back(ctx: Dictionary) -> void:
	cmd_step(ctx, -1)


static func cmd_step_forward(ctx: Dictionary) -> void:
	cmd_step(ctx, 1)


func _exit_tree() -> void:
	if _fiber != null and is_instance_valid(_fiber):
		_fiber.dispose()
		_fiber = null


func _on_coeffects(_ctx: FxContext, keys: Array) -> void:
	if keys.has("selection"):
		set_node(store.selected_id)
	elif keys.has("doc") or keys.has("structure") or keys.has("timeline"):
		var keep := _scroll
		_rebuild_tracks()
		_scroll = clampf(keep, 0.0, _max_scroll())
		_sync_timeline_controls()
	queue_redraw()


# ================= 轨道收集 =================

func _rebuild_tracks() -> void:
	_rows.clear()
	if store == null:
		return
	var doc := store.doc
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		if not scope_all and not node_id.is_empty() and id != node_id:
			continue
		if not scope_all and node_id.is_empty():
			continue
		var params: Dictionary = node_data.get("params", {})
		var collected := FxTracks.collect(params)
		if collected.is_empty():
			continue
		var def := FxCatalog.def(node_data.get("type", ""))
		var label := def.label if def != null else String(node_data.get("type", ""))
		var paths: Array = collected.keys()
		paths.sort()
		_rows.append({
			"kind": "group", "node_id": id,
			"label": "%s · %s" % [label, id],
			"count": paths.size(),
		})
		for path in paths:
			var track_def: Dictionary = collected[path]
			_rows.append({
				"kind": "track", "node_id": id,
				"path": String(path),
				"label": _track_label(params, String(path)),
				"keys": track_def.get("track", []),
				"interp": String(track_def.get("interp", "linear")),
			})


## 嵌套图层路径 → “图层名 · 属性”。其他路径退化为可读的属性名。
func _track_label(params: Dictionary, path: String) -> String:
	var parts := path.split(".", false)
	if parts.size() >= 3 and String(parts[0]) == "layers" and String(parts[1]).is_valid_int():
		var index := int(parts[1])
		var layer_name := "图层 %d" % index
		var layers: Variant = params.get("layers", [])
		if layers is Array and index < (layers as Array).size():
			var layer: Variant = (layers as Array)[index]
			if layer is Dictionary:
				layer_name = String((layer as Dictionary).get("name", layer_name))
		var suffix := ".".join(parts.slice(2))
		return "%s · %s" % [layer_name, _pretty(suffix)]
	return _pretty(path)


func _pretty(path: String) -> String:
	var table := {
		"opacity": "透明度", "offset": "位移", "visible": "显示", "blend": "混合",
		"rotation": "旋转", "scale": "缩放", "radius": "半径", "amount": "强度",
		"color": "颜色", "speed": "速度", "frame": "帧偏移", "angle": "角度",
		"brightness": "亮度", "contrast": "对比度", "gamma": "伽马",
		"cutoff": "阈值", "softness": "柔化",
	}
	if table.has(path):
		return String(table[path])
	if path.begins_with("transform."):
		return "变换 · " + _pretty(path.substr(10))
	var last := path.get_slice(".", path.get_slice_count(".") - 1)
	return String(table.get(last, last))


# ================= 绘制 =================

func _draw() -> void:
	var width := size.x
	var height := size.y
	draw_rect(Rect2(0, 0, width, height), COLOR_BG)
	if width < LABEL_W + 40.0:
		return
	draw_rect(Rect2(0, 0, LABEL_W, height), COLOR_PANEL)
	draw_line(Vector2(LABEL_W, 0), Vector2(LABEL_W, height), COLOR_LINE, 1.0)

	var font := get_theme_default_font()
	var duration := 1.0
	if store != null:
		duration = maxf(0.001, float(FxGraphDoc.timeline(store.doc).get("duration", 1.0)))
	var lane_x := LABEL_W
	var lane_w := width - LABEL_W - 10.0
	var track_count := _count_tracks()

	_draw_ruler(font, lane_x, lane_w, duration)
	_draw_cache_strip(font, lane_x, lane_w, duration)
	var lane_top := TOP_PAD + RULER_H + 4.0
	var y := lane_top - _scroll
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		var row_h := _row_height(row)
		if y + row_h >= lane_top and y <= height:
			_draw_row(font, row, i, y, row_h, lane_x, lane_w, duration, width)
		y += row_h

	if _rows.is_empty():
		var hint := "还没有关键帧：在节点参数右侧点 ○ 打帧" if store != null \
			else "选中节点后给参数打帧，轨道会出现在这里"
		draw_string(font, Vector2(10, lane_top + 18), hint,
			HORIZONTAL_ALIGNMENT_LEFT, LABEL_W * 2.0, 11, COLOR_MUTED)

	_draw_scope_toggle(font, height, track_count)
	_draw_playhead(lane_x, lane_w, duration, height)
	if _mode == "box":
		var box := Rect2(_drag_start, _drag_now - _drag_start).abs()
		draw_rect(box, Color(FxUiKit.ACCENT_COOL, 0.10))
		draw_rect(box, FxUiKit.ACCENT_COOL, false, 1.0)
	if not _selected_keys.is_empty():
		draw_string(font, Vector2(LABEL_W + 8, TOP_PAD + 12),
			"已选 %d 个关键帧 · 拖动移动 · Delete 删除" % _selected_keys.size(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, FxUiKit.ACCENT_COOL)


func _draw_row(font: Font, row: Dictionary, _index: int, y: float, row_h: float,
		lane_x: float, lane_w: float, duration: float, width: float) -> void:
	var selected := store != null and String(row.get("node_id", "")) == store.selected_id
	if String(row.get("kind", "")) == "group":
		draw_rect(Rect2(0, y, width, row_h), COLOR_GROUP)
		if selected:
			draw_rect(Rect2(0, y, 3, row_h), COLOR_ACCENT)
		draw_string(font, Vector2(10, y + 14), String(row.get("label", "")),
			HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 16, 11,
			COLOR_ACCENT if selected else COLOR_TEXT)
		draw_string(font, Vector2(LABEL_W - 58, y + 14), "%d 条" % int(row.get("count", 0)),
			HORIZONTAL_ALIGNMENT_RIGHT, 48, 10, COLOR_MUTED)
		draw_line(Vector2(0, y + row_h), Vector2(width, y + row_h), COLOR_LINE, 1.0)
		return

	if selected:
		draw_rect(Rect2(0, y, width, row_h), Color(1, 0.72, 0.33, 0.045))
	draw_line(Vector2(0, y + row_h), Vector2(width, y + row_h), Color(1, 1, 1, 0.035), 1.0)
	var track_key := FxDocumentStore.track_key(String(row.get("node_id", "")),
		String(row.get("path", "")))
	var state := store.track_state(track_key) if store != null else {}
	var animated := bool(state.get("animated", true))
	var label_color := COLOR_TEXT if animated else COLOR_MUTED
	draw_string(font, Vector2(22, y + 15), String(row.get("label", "")),
		HORIZONTAL_ALIGNMENT_LEFT, SM_X - 26, 11, label_color)
	_draw_sm_button(Rect2(SM_X, y + 3, 18, 14), "M",
		bool(state.get("muted", false)), FxUiKit.DANGER)
	_draw_sm_button(Rect2(SM_X + 22, y + 3, 18, 14), "S",
		bool(state.get("solo", false)), FxUiKit.ACCENT_COOL)
	var keys: Array = row.get("keys", [])
	for ki in range(keys.size()):
		var raw_key: Variant = keys[ki]
		if not raw_key is Array or (raw_key as Array).size() < 1:
			continue
		var t := float((raw_key as Array)[0])
		var picked := _selected_keys.has(_sel_key(_index, ki))
		if picked and _mode == "key":
			t += _key_preview_delta
		var x := lane_x + clampf(t / duration, 0.0, 1.0) * lane_w
		var cy := y + row_h * 0.5
		draw_line(Vector2(x, y + 2), Vector2(x, y + row_h - 2), Color(1, 0.72, 0.33, 0.18), 1.0)
		_draw_diamond(Vector2(x, cy),
			FxUiKit.ACCENT_COOL if picked else COLOR_ACCENT,
			5.5 if picked else 4.0)


func _draw_sm_button(rect: Rect2, text: String, on: bool, color: Color) -> void:
	draw_rect(rect, color if on else COLOR_PANEL)
	draw_rect(rect, COLOR_LINE, false, 1.0)
	draw_string(get_theme_default_font(), rect.position + Vector2(5, 11), text,
		HORIZONTAL_ALIGNMENT_LEFT, 14, 9,
		FxUiKit.BG if on else COLOR_MUTED)


func _sel_key(row: int, key_index: int) -> String:
	return "%d:%d" % [row, key_index]


func _draw_ruler(font: Font, lane_x: float, lane_w: float, duration: float) -> void:
	var y := TOP_PAD
	draw_rect(Rect2(lane_x, y, lane_w, RULER_H), COLOR_PANEL)
	var steps := 8
	for i in range(steps + 1):
		var t := duration * float(i) / float(steps)
		var x := lane_x + lane_w * float(i) / float(steps)
		draw_line(Vector2(x, y + RULER_H - 6), Vector2(x, y + RULER_H), COLOR_LINE, 1.0)
		if i % 2 == 0:
			draw_string(font, Vector2(x + 2, y + 12), "%.2fs" % t,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_MUTED)


func _draw_scope_toggle(font: Font, height: float, track_count: int) -> void:
	var rect := Rect2(6, height - 20, 130, 16)
	draw_rect(rect, COLOR_PANEL)
	draw_rect(rect, COLOR_LINE, false, 1.0)
	draw_string(font, rect.position + Vector2(6, 12),
		"全部轨道" if scope_all else "仅选中节点",
		HORIZONTAL_ALIGNMENT_LEFT, 80, 10, COLOR_TEXT if track_count > 0 else COLOR_MUTED)
	draw_string(font, rect.position + Vector2(88, 12), "切换",
		HORIZONTAL_ALIGNMENT_LEFT, 36, 10, COLOR_MUTED)
	var summary := "轨道 %d · 节点 %d" % [track_count, _count_groups()]
	draw_string(font, Vector2(144, rect.position.y + 12), summary,
		HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 148, 10, COLOR_MUTED)
	var clip := "" if _clipboard.is_empty() else " · 剪贴板 %d 帧（Ctrl+V 粘贴）" % _clipboard.size()
	draw_string(font, Vector2(LABEL_W + 8, height - 6),
		"拖动改时间 · 框选批量移动/删除 · Ctrl+C/V 复制粘贴 · M 静音 S 独奏 · 双击打帧%s" % clip,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_MUTED)


func _draw_playhead(lane_x: float, lane_w: float, duration: float, height: float) -> void:
	if store == null:
		return
	var x := lane_x + clampf(store.current_time / duration, 0.0, 1.0) * lane_w
	draw_line(Vector2(x, TOP_PAD), Vector2(x, height), COLOR_PLAYHEAD, 1.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - 4, TOP_PAD), Vector2(x + 4, TOP_PAD), Vector2(x, TOP_PAD + 6)
	]), COLOR_PLAYHEAD)


func _draw_diamond(center: Vector2, color: Color, radius: float = 4.0) -> void:
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0, -radius), center + Vector2(radius, 0),
		center + Vector2(0, radius), center + Vector2(-radius, 0),
	]), color)


# ================= 交互 =================

func _gui_input(event: InputEvent) -> void:
	if store == null:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			if key.keycode == KEY_DELETE or key.keycode == KEY_BACKSPACE:
				if not _selected_keys.is_empty():
					_delete_selected_keys()
					accept_event()
					return
			elif key.keycode == KEY_ESCAPE:
				_selected_keys.clear()
				queue_redraw()
				accept_event()
				return
			elif key.keycode == KEY_A and key.ctrl_pressed:
				_select_all_keys()
				accept_event()
				return
			elif key.keycode == KEY_C and key.ctrl_pressed:
				_copy_keys()
				accept_event()
				return
			elif key.keycode == KEY_V and key.ctrl_pressed:
				_paste_keys()
				accept_event()
				return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_scroll = maxf(0.0, _scroll - ROW_H * 2.0)
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_scroll = minf(_max_scroll(), _scroll + ROW_H * 2.0)
			queue_redraw()
			accept_event()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if not mb.pressed:
			_finish_drag()
			accept_event()
			return
		if mb.position.y >= size.y - 22.0 and mb.position.x <= 140.0:
			set_scope_all(not scope_all)
			accept_event()
			return
		var row := _row_at(mb.position.y)
		if row >= 0 and _hit_sm(mb.position, row):
			accept_event()
			return
		if mb.double_click and row >= 0 and mb.position.x >= LABEL_W:
			_toggle_key(row)
			accept_event()
			return
		if row >= 0 and mb.position.x < LABEL_W:
			var id := String((_rows[row] as Dictionary).get("node_id", ""))
			if not id.is_empty():
				store.set_selection(id)
			accept_event()
			return
		_drag_start = mb.position
		_drag_now = mb.position
		if mb.position.y < TOP_PAD + RULER_H:
			_mode = "scrub"
			_dragging = true
			_set_time_from_x(mb.position.x)
		else:
			var hit := _key_at(mb.position)
			if not hit.is_empty():
				_mode = "key"
				_drag_row = int(hit["row"])
				_drag_key_index = int(hit["index"])
				var picked := _sel_key(_drag_row, _drag_key_index)
				if not _selected_keys.has(picked):
					_selected_keys.clear()
					_selected_keys[picked] = _drag_start.x
				_key_preview_delta = 0.0
			else:
				_mode = "box"
				_selected_keys.clear()
		queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_drag_now = mm.position
		match _mode:
			"scrub":
				_set_time_from_x(mm.position.x)
			"key":
				var duration := _duration()
				var lane_w := size.x - LABEL_W - 10.0
				_key_preview_delta = (mm.position.x - _drag_start.x) / maxf(lane_w, 1.0) * duration
			"box":
				pass
		queue_redraw()
		accept_event()


func _duration() -> float:
	return maxf(0.001, float(FxGraphDoc.timeline(store.doc).get("duration", 1.0))) if store != null else 1.0


## 返回命中的关键帧 {row, index}；空字典表示没点中菱形。
func _key_at(position: Vector2) -> Dictionary:
	var lane_w := size.x - LABEL_W - 10.0
	if lane_w <= 0.0:
		return {}
	var duration := _duration()
	var cur := TOP_PAD + RULER_H + 4.0 - _scroll
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		var h := _row_height(row)
		if String(row.get("kind", "")) == "track" and position.y >= cur and position.y < cur + h:
			var keys: Array = row.get("keys", [])
			for ki in range(keys.size()):
				var raw: Variant = keys[ki]
				if not raw is Array or (raw as Array).size() < 1:
					continue
				var t := float((raw as Array)[0])
				var x := LABEL_W + clampf(t / duration, 0.0, 1.0) * lane_w
				if absf(x - position.x) <= KEY_HIT:
					return {"row": i, "index": ki}
		cur += h
	return {}


func _hit_sm(position: Vector2, row: int) -> bool:
	var row_data: Dictionary = _rows[row]
	if String(row_data.get("kind", "")) != "track" or position.x < SM_X:
		return false
	var y := _row_y(row)
	var m_rect := Rect2(SM_X, y + 3, 18, 14)
	var s_rect := Rect2(SM_X + 22, y + 3, 18, 14)
	var key := FxDocumentStore.track_key(String(row_data.get("node_id", "")),
		String(row_data.get("path", "")))
	if m_rect.has_point(position):
		store.set_track_muted(key, not bool(store.track_state(key).get("muted", false)))
		queue_redraw()
		return true
	if s_rect.has_point(position):
		store.set_track_solo(key, not bool(store.track_state(key).get("solo", false)))
		queue_redraw()
		return true
	return false


func _row_y(index: int) -> float:
	var cur := TOP_PAD + RULER_H + 4.0 - _scroll
	for i in range(mini(index, _rows.size())):
		cur += _row_height(_rows[i])
	return cur


func _finish_drag() -> void:
	match _mode:
		"key":
			_commit_key_drag()
		"box":
			_apply_box_selection()
	_mode = ""
	_dragging = false
	_key_preview_delta = 0.0
	queue_redraw()


## 拖动关键帧：按行分组，一次 batch 合成一个撤销点。
func _commit_key_drag() -> void:
	if absf(_key_preview_delta) < 0.0005:
		return
	var duration := _duration()
	var by_row: Dictionary = {}
	for raw_key in _selected_keys.keys():
		var parts := String(raw_key).split(":")
		if parts.size() < 2:
			continue
		var row := int(parts[0])
		var ki := int(parts[1])
		if not by_row.has(row):
			by_row[row] = []
		(by_row[row] as Array).append(ki)
	if by_row.is_empty():
		return
	store.begin_batch()
	for row_key in by_row.keys():
		var row_index := int(row_key)
		if row_index < 0 or row_index >= _rows.size():
			continue
		var row: Dictionary = _rows[row_index]
		if String(row.get("kind", "")) != "track":
			continue
		var node_data := FxGraphDoc.node(store.doc, String(row.get("node_id", "")))
		if node_data.is_empty():
			continue
		var path := String(row.get("path", ""))
		var raw: Variant = FxCatalog.value_at(node_data.get("params", {}), path)
		if not raw is Dictionary or not (raw as Dictionary).has("track"):
			continue
		var keys: Array = ((raw as Dictionary).get("track", []) as Array).duplicate(true)
		for ki2 in (by_row[row_key] as Array):
			var index := int(ki2)
			if index < 0 or index >= keys.size() or not keys[index] is Array:
				continue
			var pair: Array = keys[index]
			pair[0] = clampf(float(pair[0]) + _key_preview_delta, 0.0, duration)
		store.apply_path(String(row.get("node_id", "")), path, {
			"track": FxTracks.normalize(keys, duration),
			"interp": String((raw as Dictionary).get("interp", "linear")),
		}, false, _fresh_merge_key(String(row.get("node_id", "")), path))
	store.commit_batch()
	_selected_keys.clear()


func _apply_box_selection() -> void:
	var box := Rect2(_drag_start, _drag_now - _drag_start).abs()
	if box.size.x < 3.0 and box.size.y < 3.0:
		return
	var lane_w := size.x - LABEL_W - 10.0
	var duration := _duration()
	var cur := TOP_PAD + RULER_H + 4.0 - _scroll
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		var h := _row_height(row)
		if String(row.get("kind", "")) == "track":
			var keys: Array = row.get("keys", [])
			for ki in range(keys.size()):
				var raw: Variant = keys[ki]
				if not raw is Array or (raw as Array).size() < 1:
					continue
				var t := float((raw as Array)[0])
				var pos := Vector2(LABEL_W + clampf(t / duration, 0.0, 1.0) * lane_w,
					cur + h * 0.5)
				if box.has_point(pos):
					_selected_keys[_sel_key(i, ki)] = pos.x
		cur += h


func _select_all_keys() -> void:
	_selected_keys.clear()
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		if String(row.get("kind", "")) != "track":
			continue
		for ki in range((row.get("keys", []) as Array).size()):
			_selected_keys[_sel_key(i, ki)] = 0.0
	queue_redraw()


func _delete_selected_keys() -> void:
	if _selected_keys.is_empty():
		return
	var by_row: Dictionary = {}
	for raw_key in _selected_keys.keys():
		var parts := String(raw_key).split(":")
		if parts.size() < 2:
			continue
		var row := int(parts[0])
		if not by_row.has(row):
			by_row[row] = []
		(by_row[row] as Array).append(int(parts[1]))
	store.begin_batch()
	for row_key in by_row.keys():
		var row_index := int(row_key)
		if row_index < 0 or row_index >= _rows.size():
			continue
		var row: Dictionary = _rows[row_index]
		var node_id := String(row.get("node_id", ""))
		var path := String(row.get("path", ""))
		var node_data := FxGraphDoc.node(store.doc, node_id)
		if node_data.is_empty():
			continue
		var raw: Variant = FxCatalog.value_at(node_data.get("params", {}), path)
		if not raw is Dictionary or not (raw as Dictionary).has("track"):
			continue
		var keys: Array = ((raw as Dictionary).get("track", []) as Array).duplicate(true)
		var to_remove: Array = (by_row[row_key] as Array).duplicate()
		to_remove.sort()
		for i in range(to_remove.size() - 1, -1, -1):
			var index := int(to_remove[i])
			if index >= 0 and index < keys.size():
				keys.remove_at(index)
		if keys.is_empty():
			store.apply_path(node_id, path, FxTracks.sample(raw, store.current_time),
				false, _fresh_merge_key(node_id, path))
		else:
			store.apply_path(node_id, path, {
				"track": FxTracks.normalize(keys, _duration()),
				"interp": String((raw as Dictionary).get("interp", "linear")),
			}, false, _fresh_merge_key(node_id, path))
	store.commit_batch()
	_selected_keys.clear()


# ================= 复制 / 粘贴 =================

## 复制：选中了就复制选中的；没选就复制播放头这一帧；再没有就复制全部可见轨道。
func _copy_keys() -> void:
	var picked := _collect_selected_keys()
	if picked.is_empty():
		picked = _collect_frame_keys()
	if picked.is_empty():
		picked = _collect_all_keys()
	_clipboard = picked
	_clipboard_anchor = 0.0
	if _clipboard.is_empty():
		return
	var earliest := INF
	for entry in _clipboard:
		earliest = minf(earliest, float(entry.get("time", 0.0)))
	_clipboard_anchor = 0.0 if earliest == INF else earliest
	for entry in _clipboard:
		entry["dt"] = float(entry.get("time", 0.0)) - _clipboard_anchor
	if shell != null:
		shell.status("已复制 %d 个关键帧（Ctrl+V 粘贴到播放头）" % _clipboard.size())
	queue_redraw()


func _collect_selected_keys() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw_key in _selected_keys.keys():
		var parsed := _parse_sel_key(String(raw_key))
		if parsed.is_empty():
			continue
		var entry := _key_entry(int(parsed["row"]), int(parsed["index"]))
		if not entry.is_empty():
			out.append(entry)
	return out


func _collect_frame_keys() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var at := store.current_time if store != null else 0.0
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		if String(row.get("kind", "")) != "track":
			continue
		var keys: Array = row.get("keys", [])
		for ki in range(keys.size()):
			var raw: Variant = keys[ki]
			if raw is Array and (raw as Array).size() >= 1 \
					and absf(float((raw as Array)[0]) - at) < 0.02:
				var entry := _key_entry(i, ki)
				if not entry.is_empty():
					out.append(entry)
	return out


func _collect_all_keys() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		if String(row.get("kind", "")) != "track":
			continue
		for ki in range((row.get("keys", []) as Array).size()):
			var entry := _key_entry(i, ki)
			if not entry.is_empty():
				out.append(entry)
	return out


func _parse_sel_key(raw: String) -> Dictionary:
	var parts := raw.split(":")
	if parts.size() < 2:
		return {}
	return {"row": int(parts[0]), "index": int(parts[1])}


func _key_entry(row_index: int, key_index: int) -> Dictionary:
	if row_index < 0 or row_index >= _rows.size():
		return {}
	var row: Dictionary = _rows[row_index]
	if String(row.get("kind", "")) != "track":
		return {}
	var keys: Array = row.get("keys", [])
	if key_index < 0 or key_index >= keys.size():
		return {}
	var raw: Variant = keys[key_index]
	if not raw is Array or (raw as Array).size() < 2:
		return {}
	return {
		"node": String(row.get("node_id", "")),
		"path": String(row.get("path", "")),
		"time": float((raw as Array)[0]),
		"value": (raw as Array)[1],
	}


## 粘贴到播放头：按「相对最早一帧」的偏移落位，所以整段节奏不会变形。
func _paste_keys() -> void:
	if _clipboard.is_empty() or store == null:
		return
	var duration := _duration()
	var at := store.current_time
	var by_track: Dictionary = {}
	for entry in _clipboard:
		var key := "%s\u0001%s" % [entry.get("node", ""), entry.get("path", "")]
		if not by_track.has(key):
			by_track[key] = []
		(by_track[key] as Array).append(entry)
	var pasted := 0
	store.begin_batch()
	for key in by_track.keys():
		var group: Array = by_track[key]
		if group.is_empty():
			continue
		var head: Dictionary = group[0]
		var node_id := String(head.get("node", ""))
		var path := String(head.get("path", ""))
		var node_data := FxGraphDoc.node(store.doc, node_id)
		if node_data.is_empty():
			continue
		var raw: Variant = FxCatalog.value_at(node_data.get("params", {}), path)
		var keys: Array = []
		var interp := "linear"
		if raw is Dictionary and (raw as Dictionary).has("track"):
			keys = ((raw as Dictionary).get("track", []) as Array).duplicate(true)
			interp = String((raw as Dictionary).get("interp", "linear"))
		for entry in group:
			keys = FxTracks.upsert(keys, clampf(at + float(entry.get("dt", 0.0)),
				0.0, duration), entry.get("value"), duration)
			pasted += 1
		store.apply_path(node_id, path,
			{"track": FxTracks.normalize(keys, duration), "interp": interp},
			false, _fresh_merge_key(node_id, path))
	store.commit_batch()
	_selected_keys.clear()
	if shell != null:
		shell.status("已粘贴 %d 个关键帧到 %.2fs" % [pasted, at])
	_rebuild_tracks()
	queue_redraw()


func _row_at(y: float) -> int:
	var cur := TOP_PAD + RULER_H + 4.0 - _scroll
	for i in range(_rows.size()):
		var h := _row_height(_rows[i])
		if y >= cur and y < cur + h:
			return i
		cur += h
	return -1


func _set_time_from_x(x: float) -> void:
	var lane_w := size.x - LABEL_W - 10.0
	if lane_w <= 0.0 or x < LABEL_W:
		return
	var duration := maxf(0.001, float(FxGraphDoc.timeline(store.doc).get("duration", 1.0)))
	var t := clampf((x - LABEL_W) / lane_w, 0.0, 1.0) * duration
	store.set_time(t)
	queue_redraw()


func _toggle_key(row_index: int) -> void:
	if row_index < 0 or row_index >= _rows.size():
		return
	var row: Dictionary = _rows[row_index]
	if String(row.get("kind", "")) != "track":
		return
	var path := String(row.get("path", ""))
	var id := String(row.get("node_id", ""))
	var node_data := FxGraphDoc.node(store.doc, id)
	if node_data.is_empty():
		return
	var raw: Variant = FxCatalog.value_at(node_data.get("params", {}), path)
	if not raw is Dictionary or not (raw as Dictionary).has("track"):
		return
	var track_def: Dictionary = raw
	var keys: Array = (track_def.get("track", []) as Array).duplicate(true)
	var found := -1
	for i in range(keys.size()):
		if absf(float((keys[i] as Array)[0]) - store.current_time) < 0.02:
			found = i
			break
	if found >= 0:
		var sample_value: Variant = FxTracks.sample(track_def, store.current_time)
		keys.remove_at(found)
		if keys.is_empty():
			store.apply_path(id, path, sample_value, false, _fresh_merge_key(id, path))
			return
	else:
		keys.append([snappedf(store.current_time, 0.001),
			FxTracks.sample(track_def, store.current_time)])
	var duration := float(FxGraphDoc.timeline(store.doc).get("duration", 1.0))
	var normalized := FxTracks.normalize(keys, duration)
	store.apply_path(id, path, {
		"track": normalized,
		"interp": String(track_def.get("interp", "linear")),
	}, false, _fresh_merge_key(id, path))


# ================= 工具 =================

func _row_height(row: Dictionary) -> float:
	return GROUP_H if String(row.get("kind", "")) == "group" else ROW_H


func _count_tracks() -> int:
	var count := 0
	for row in _rows:
		if String((row as Dictionary).get("kind", "")) == "track":
			count += 1
	return count


func _count_groups() -> int:
	var count := 0
	for row in _rows:
		if String((row as Dictionary).get("kind", "")) == "group":
			count += 1
	return count


## 每次打/删帧都必须是独立撤销点，不能被 600ms 的参数合并吃掉。
func _fresh_merge_key(id: String, path: String) -> String:
	return "track:%s:%s:%d" % [id, path, Time.get_ticks_usec()]


## 供测试/外部定位某条轨道；返回行下标，找不到返回 -1。
func find_track(track_node_id: String, path: String) -> int:
	for i in range(_rows.size()):
		var row: Dictionary = _rows[i]
		if String(row.get("kind", "")) != "track":
			continue
		if String(row.get("node_id", "")) == track_node_id \
				and String(row.get("path", "")) == path:
			return i
	return -1


func _max_scroll() -> float:
	var total := 0.0
	for row in _rows:
		total += _row_height(row)
	var visible := size.y - TOP_PAD - RULER_H - 10.0
	return maxf(0.0, total - visible)


## 选中节点后滚到它的第一行，避免“选中了却看不见”。
func _ensure_visible() -> void:
	if node_id.is_empty() or _rows.is_empty():
		return
	var lane_top := TOP_PAD + RULER_H + 4.0
	var y := 0.0
	for row in _rows:
		var h := _row_height(row)
		if String((row as Dictionary).get("node_id", "")) == node_id \
				and String((row as Dictionary).get("kind", "")) == "group":
			var visible := size.y - lane_top
			if y < _scroll or y + h > _scroll + visible:
				_scroll = maxf(0.0, y - 4.0)
			return
		y += h
