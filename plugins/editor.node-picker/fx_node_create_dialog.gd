class_name FxNodeCreateDialog
extends FxNodePicker
## 节点创建面板（插件 editor.node-picker 的实现）。
##
## 设计目标：**一眼看到节点的归属与效果**，不做目录树。
##   · 卡片墙：每张卡有缩略图、名称、所属插件、分类色点与能力标记；
##   · 缩略图三级回退：节点自带纹理（可动图） → 真实渲染样张 → 分类色块字形；
##   · 右侧详情：大图（时间相关的节点会真的动起来）、端口、参数、归属与说明；
##   · 顶部筛选条：全部 / 最近 / 各分类 + 插件下拉，条件相乘而不是层层展开；
##   · 搜索即过滤，↑↓←→ 在卡片间移动，回车添加，Esc 关闭，双击直接添加。
##
## 面板仍然是「编辑器内浮层」而不是独立 Window：截图能截到、不会和子窗口打架。
## 节点信息全部来自 FxGraphFacade 代理，本文件不认识任何具体节点类型。

## 默认尺寸比「铺满半个屏幕」收敛一档：这张面板是**随手一用的浮层**，
## 不是主工作区。用户拖过之后本次会话内会记住（`_last_size`）。
const PANEL_SIZE := Vector2(800, 500)
const PANEL_MIN := Vector2(540, 352)
const GRIP_SIZE := 16.0
static var _last_size: Vector2 = PANEL_SIZE
const CARD_SIZE := Vector2(156, 112)
const THUMB_SIZE := Vector2(140, 60)
const DETAIL_WIDTH := 252.0
const RECENT_LIMIT := 10
const PREVIEW_SIZE := Vector2i(140, 60)
const DETAIL_PREVIEW := Vector2i(228, 112)
## 每帧最多补几张卡片缩略图：一次算完会卡住首帧，摊到几帧里几乎无感。
const PREVIEWS_PER_FRAME := 3
## 详情大图的动画帧率：只给「画面会随时间变」的节点用，稳定下来就停。
const ANIM_FPS := 8.0
const ANIM_SETTLE := 0.6

static var _recent: Array[String] = []

var _dim: ColorRect
var _panel: PanelContainer
var _search: LineEdit
var _count_label: Label
var _plugin_filter: OptionButton
var _chips: HFlowContainer
var _chips_scroll: ScrollContainer
var _grid: GridContainer
var _grid_scroll: ScrollContainer
var _empty: Label
var _hint: Label

var _d_thumb: TextureRect
var _d_glyph: Label
var _d_name: Label
var _d_id: Label
var _d_chips: HFlowContainer
var _d_desc: Label
var _d_ports: VBoxContainer
var _d_params: VBoxContainer
var _d_add: Button

var _defs: Array[FxNodeDef] = []
var _filtered: Array[FxNodeDef] = []
var _cards: Dictionary = {}
## 缩略图懒加载队列：卡先出来，图随后补。
var _preview_queue: Array[String] = []
var _queued: Dictionary = {}
var _target := Vector2(-1, -1)
## 连线拖拽上下文：限定搜索范围到「有兼容端口」的节点。
var _port_type: StringName = &""
var _port_want_input: bool = true
var _scope_bar: HBoxContainer
var _scope_label: Label

var _filter_text: String = ""
## 当前筛选：all / recent / 具体分类名；插件过滤是独立维度。
var _chip_filter: String = "all"
var _plugin_filter_id: String = ""
var _selected_type: String = ""
var _refresh_pending: bool = false
var _render: Object = null
## 节点有没有画面可看（用于排序，避免每次比较都去问渲染服务）。
var _visual_cache: Dictionary = {}

## 详情大图的动画状态：只在画面真的在变时继续跑。
var _anim_type: String = ""
var _anim_t: float = 0.0
var _anim_clock: float = 0.0
var _anim_still: float = 0.0
var _anim_hash: int = 0
var _detail_tex: ImageTexture = null
## 图标精灵表（节点自带纹理的动图形态）用的共享底图与切分参数。
var _card_sheet: Texture2D = null
var _card_grid: Dictionary = {}
var _card_size: Vector2i = Vector2i.ONE
var _detail_atlas: AtlasTexture = null
## 面板自身的拖拽状态："" / "move" / "resize"。用 _input 跟踪是为了
## 鼠标拖出面板边界后还能继续跟手（只在控件自己的 gui_input 里会断）。
var _drag_mode: String = ""
var _drag_origin: Vector2 = Vector2.ZERO
var _drag_pos: Vector2 = Vector2.ZERO
var _drag_size: Vector2 = Vector2.ZERO
var _grip: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	z_index = 100
	_render = _resolve_render()

	_dim = ColorRect.new()
	# 0.9 的遮罩像模态框；这是随手浮层，压暗即可，底下的图还看得见。
	_dim.color = Color(FxUiKit.BG, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			hide_picker()
	)
	add_child(_dim)

	_panel = PanelContainer.new()
	# custom_minimum_size 放「最小可缩到多少」，实际尺寸单独管 ——
	# 否则一旦设成面板尺寸就再也缩不回去了。
	_panel.custom_minimum_size = PANEL_MIN
	_panel.size = _clamp_panel(_last_size)
	_panel.resized.connect(_on_panel_resized)
	_panel.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(FxUiKit.PANEL, FxUiKit.BORDER, 8))
	add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_panel.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	_build_grip()
	root.add_child(_build_header())
	_scope_bar = _build_scope_bar()
	root.add_child(_scope_bar)
	root.add_child(_build_chip_row())
	root.add_child(_build_body())
	root.add_child(_build_footer())
	reload_defs()


## 渲染服务是「有就用、没有就算了」的软依赖：面板插件不认识具体类型，
## 只按方法名问一句，停用渲染插件时缩略图自动退到分类色块。
func _resolve_render() -> Object:
	var host := get_parent()
	if host != null and host.get("render") != null:
		return host.get("render")
	return null


# ================= 布局 =================

## 右下角的缩放手柄。PanelContainer 只能有一个孩子，所以它挂在面板外面，
## 每次面板移动/缩放后同步到右下角。
func _build_grip() -> void:
	_grip = Control.new()
	_grip.name = "ResizeGrip"
	_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	_grip.tooltip_text = "拖动改变面板大小"
	_grip.z_index = 6
	var mark := FxUiKit.label("◢", 13, FxUiKit.MUTED)
	mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	mark.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_grip.add_child(mark)
	_grip.gui_input.connect(_on_grip_input)
	add_child(_grip)
	_sync_grip()


func _sync_grip() -> void:
	if _grip == null or _panel == null:
		return
	_grip.size = Vector2(GRIP_SIZE, GRIP_SIZE)
	_grip.position = _panel.position + _panel.size - _grip.size


## 把尺寸夹进「最小尺寸 ~ 视口」之间。视口比最小尺寸还小时以最小尺寸为准，
## 由外层滚动/裁切兜底，不让面板缩成一条。
func _clamp_panel(value: Vector2) -> Vector2:
	var area := get_viewport_rect().size
	if area.x <= 1.0:
		area = size
	var limit := Vector2(maxf(PANEL_MIN.x, area.x - 24.0),
		maxf(PANEL_MIN.y, area.y - 24.0))
	return Vector2(clampf(value.x, PANEL_MIN.x, limit.x),
		clampf(value.y, PANEL_MIN.y, limit.y))


func _on_panel_resized() -> void:
	_last_size = _panel.size
	_update_columns()
	_sync_grip()


## origin 用**视口坐标**，和 InputEventMouse{:Motion}.position 同一空间，
## 这样拖拽位移既不用做坐标变换，也可以在测试里直接构造事件验证。
func _begin_drag(mode: String, origin: Vector2) -> void:
	_drag_mode = mode
	_drag_origin = origin
	_drag_pos = _panel.position
	_drag_size = _panel.size


func _end_drag() -> void:
	if _drag_mode.is_empty():
		return
	_drag_mode = ""
	_last_size = _panel.size
	_update_columns()


## 拖拽跟手放在 _input：鼠标移出标题条/抓手范围后依旧要继续移动面板。
func _input(event: InputEvent) -> void:
	if _drag_mode.is_empty() or not visible:
		return
	if event is InputEventMouseButton:
		if not (event as InputEventMouseButton).pressed:
			_end_drag()
		return
	if not (event is InputEventMouseMotion):
		return
	var delta := (event as InputEventMouseMotion).position - _drag_origin
	if _drag_mode == "move":
		var area := get_viewport_rect().size
		var pos := _drag_pos + delta
		# 允许拖到边缘外一点，但不让标题条彻底消失（否则再也抓不回来）。
		pos.x = clampf(pos.x, -_panel.size.x + 140.0, maxf(0.0, area.x - 140.0))
		pos.y = clampf(pos.y, 0.0, maxf(0.0, area.y - 44.0))
		_panel.position = pos
		_sync_grip()
	else:
		var target := _clamp_panel(_drag_size + delta)
		# 先把列数按目标宽度收好，再改尺寸：否则这一帧会被「上一帧的列数」
		# 算出的最小宽度顶回去，拖小会像卡住一样。
		_update_columns_for(target.x)
		_panel.size = target
		_sync_grip()
	get_viewport().set_input_as_handled()


func _on_header_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if mb.double_click:
		# 双击标题：回到居中，等于「我刚把面板挪丢了」的复位键。
		_target = Vector2(-1, -1)
		_place_panel()
		get_viewport().set_input_as_handled()
		return
	_begin_drag("move", get_viewport().get_mouse_position())
	get_viewport().set_input_as_handled()


func _on_grip_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	_begin_drag("resize", get_viewport().get_mouse_position())
	get_viewport().set_input_as_handled()


func _build_header() -> Control:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	# 标题条当拖拽把手：点「添加节点」这几个字就能挪面板，双击回到居中。
	head.mouse_default_cursor_shape = Control.CURSOR_MOVE
	head.tooltip_text = "拖动标题可移动面板 · 双击回到居中"
	head.gui_input.connect(_on_header_input)
	var title := FxUiKit.strong("添加节点", 15)
	head.add_child(title)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索：名称 / id / 分类 / 说明…"
	_search.custom_minimum_size = Vector2(0, 32)
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.clear_button_enabled = true
	_search.add_theme_font_size_override("font_size", 13)
	_search.text_changed.connect(func(text: String) -> void:
		_filter_text = text
		_request_refresh()
	)
	_search.gui_input.connect(_on_key_input)
	head.add_child(_search)

	_plugin_filter = OptionButton.new()
	_plugin_filter.custom_minimum_size = Vector2(168, 32)
	_plugin_filter.add_theme_font_size_override("font_size", 11)
	_plugin_filter.tooltip_text = "只看某个插件贡献的节点"
	_plugin_filter.item_selected.connect(func(index: int) -> void:
		_plugin_filter_id = String(_plugin_filter.get_item_metadata(index))
		_request_refresh()
	)
	head.add_child(_plugin_filter)

	_count_label = FxUiKit.label("", 10, FxUiKit.MUTED)
	head.add_child(_count_label)
	return head


func _build_scope_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bar.visible = false
	_scope_label = FxUiKit.label("", 11, FxUiKit.ACCENT)
	_scope_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_scope_label)
	var clear_scope := FxUiKit.button("显示全部节点", 10, 22)
	clear_scope.pressed.connect(clear_port_filter)
	bar.add_child(clear_scope)
	return bar


func _build_chip_row() -> Control:
	_chips_scroll = ScrollContainer.new()
	_chips_scroll.custom_minimum_size = Vector2(0, 32)
	_chips_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_chips_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chips = HFlowContainer.new()
	_chips.add_theme_constant_override("h_separation", 6)
	_chips.add_theme_constant_override("v_separation", 4)
	_chips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chips_scroll.add_child(_chips)
	return _chips_scroll


func _build_body() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	_grid_scroll = ScrollContainer.new()
	_grid_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 必须允许横向滚动：DISABLED 时 ScrollContainer 会把内容的最小宽度传给父级，
	# 卡片是 GridContainer，于是「列数」反过来把面板宽度钉死，拖不小。
	# 列数本来就是按面板宽度算的，正常不会出现横向滚动条。
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	left.add_child(_grid_scroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.add_child(_grid)
	# 面板宽度会变（停靠 / 分离 / 拖拽），列数跟着重算，卡片不要被拉成一张大黑块。
	_grid_scroll.resized.connect(_update_columns)
	_empty = FxUiKit.wrapped("没有匹配的节点。换个关键词，或点「显示全部节点」放宽范围。",
		11, FxUiKit.MUTED)
	_empty.visible = false
	left.add_child(_empty)

	row.add_child(_build_detail())
	return row


func _build_detail() -> Control:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = Vector2(DETAIL_WIDTH, 0)
	wrap.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(FxUiKit.PANEL_ALT, FxUiKit.BORDER_SOFT, 6))
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	wrap.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	margin.add_child(col)

	# 大图：透明底用深色压一层，图像效果看得清。
	var thumb_wrap := PanelContainer.new()
	thumb_wrap.custom_minimum_size = Vector2(DETAIL_PREVIEW.x, DETAIL_PREVIEW.y)
	thumb_wrap.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(Color("#14161a"), Color(FxUiKit.BORDER_SOFT, 0.7), 4))
	col.add_child(thumb_wrap)
	_d_thumb = TextureRect.new()
	_d_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_d_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_d_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_wrap.add_child(_d_thumb)
	_d_glyph = FxUiKit.strong("◇", 40)
	_d_glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_d_glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_d_glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_d_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_wrap.add_child(_d_glyph)

	_d_name = FxUiKit.strong("", 14)
	_d_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_d_name)
	_d_id = FxUiKit.label("", 9, FxUiKit.MUTED)
	_d_id.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_d_id)
	_d_chips = HFlowContainer.new()
	_d_chips.add_theme_constant_override("h_separation", 4)
	_d_chips.add_theme_constant_override("v_separation", 4)
	col.add_child(_d_chips)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 7)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	_d_desc = FxUiKit.wrapped("", 11, FxUiKit.TEXT)
	body.add_child(_d_desc)
	_d_ports = VBoxContainer.new()
	_d_ports.add_theme_constant_override("separation", 3)
	body.add_child(_d_ports)
	_d_params = VBoxContainer.new()
	_d_params.add_theme_constant_override("separation", 2)
	body.add_child(_d_params)

	_d_add = FxUiKit.button("添加节点", 12, 30)
	_d_add.pressed.connect(func() -> void:
		if not _selected_type.is_empty():
			_emit_choice_type(_selected_type)
	)
	col.add_child(_d_add)
	return wrap


func _build_footer() -> Control:
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	_hint = FxUiKit.label("↑↓←→ 选择 · 回车添加 · 双击直接添加 · Esc 关闭", 10, FxUiKit.MUTED)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_hint)
	var close := FxUiKit.button("关闭", 10, 24)
	close.pressed.connect(hide_picker)
	foot.add_child(close)
	return foot


# ================= 数据 =================

func reload_defs() -> void:
	_defs = FxGraphFacade.access().catalog_all()
	_rebuild_plugin_filter()
	_rebuild_chips()
	_refresh(_filter_text)


func _request_refresh() -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	_refresh_later.call_deferred()


func _refresh_later() -> void:
	_refresh_pending = false
	_refresh(_filter_text)


## screen_position 是屏幕坐标；面板会夹在编辑器可见区域内。
## 普通打开会清除连线范围限定。
func open_at(screen_position: Vector2) -> void:
	_clear_port_filter_internal()
	_open_internal(screen_position)


## 从端口拖线到空白处打开：只列出能接上这个端口的节点。
## want_input = true 表示新节点需要提供输入端口（源是输出口）。
func open_for_port(screen_position: Vector2, port_type: StringName,
		want_input: bool) -> void:
	_port_type = FxGraphFacade.access().port_normalize(port_type)
	_port_want_input = want_input
	_open_internal(screen_position)


func _open_internal(screen_position: Vector2) -> void:
	_render = _resolve_render()
	var local := screen_position - get_global_rect().position
	_target = local
	visible = true
	move_to_front()
	if _search != null:
		_search.text = ""
		_filter_text = ""
		_refresh("")
		FxUiKit.focus_later(_search)
	_place_panel()
	FxUiKit.focus_later(_search)


func clear_port_filter() -> void:
	_clear_port_filter_internal()
	_search.text = ""
	_filter_text = ""
	_refresh("")
	FxUiKit.focus_later(_search)


func _clear_port_filter_internal() -> void:
	_port_type = &""
	_port_want_input = true


func port_filter_active() -> bool:
	return _port_type != &""


func port_filter_type() -> StringName:
	return _port_type


func scope_count() -> int:
	return _filtered.size()


func set_filter(text: String) -> void:
	_filter_text = text
	if _search != null:
		_search.text = text
	_refresh(text)


func filtered_types() -> Array[String]:
	var out: Array[String] = []
	for def in _filtered:
		out.append(String(def.id))
	return out


func choose_type(type: String) -> bool:
	for def in _defs:
		if String(def.id) == type:
			_emit_choice(def)
			return true
	return false


# ---- 给测试与外部工具的最小只读视图（不做业务，只报状态） ----

func card_count() -> int:
	return _cards.size()


## 这张卡当前是「自带纹理/渲染样张」还是「分类字形回退」。
func card_has_image(type_id: String) -> bool:
	var info: Dictionary = _cards.get(type_id, {})
	var thumb: TextureRect = info.get("thumb")
	return thumb != null and is_instance_valid(thumb) and thumb.texture != null


func card_owner(type_id: String) -> String:
	var def := _find_def(type_id)
	return def.owner_plugin if def != null else ""


func card_category(type_id: String) -> String:
	var def := _find_def(type_id)
	return def.category if def != null else ""


func selected_type() -> String:
	return _selected_type


func active_chip() -> String:
	return _chip_filter


## 切到某个筛选标签（"all" / "recent" / 分类名）。等价于点一下那颗 chip。
func set_chip(key: String) -> void:
	_chip_filter = key
	_rebuild_chips()
	_refresh(_filter_text)


func preview_queue_size() -> int:
	return _preview_queue.size()


func hide_picker() -> void:
	_stop_anim()
	# 正在拖拽时被 Esc 关掉：不清状态的话，下次一开面板就会跟着鼠标跳。
	_drag_mode = ""
	hide()


func _place_panel() -> void:
	if _panel == null:
		return
	var area := get_viewport_rect().size
	if area.x <= 1.0:
		area = size
	var panel_size := _clamp_panel(_panel.size)
	_panel.size = panel_size
	var pos := _target - Vector2(panel_size.x * 0.28, 40.0)
	if _target.x < 0.0:
		pos = (area - panel_size) * 0.5
	pos.x = clampf(pos.x, 8.0, maxf(8.0, area.x - panel_size.x - 8.0))
	pos.y = clampf(pos.y, 8.0, maxf(8.0, area.y - panel_size.y - 8.0))
	_panel.position = pos
	_sync_grip()
	_update_columns()


## 只读视图：给测试和截图脚本用，验证尺寸确实是「可改」的。
func panel_size() -> Vector2:
	return _panel.size if _panel != null else PANEL_SIZE


func panel_position() -> Vector2:
	return _panel.position if _panel != null else Vector2.ZERO


func resize_panel(value: Vector2) -> void:
	if _panel == null:
		return
	var target := _clamp_panel(value)
	_panel.size = target
	# 注意用 target 而不是 _panel.size：这一帧面板已被内容最小宽度撑到更大，
	# 读回来就会算出「3 列」，于是永远缩不下去。
	_update_columns_for(target.x)
	_last_size = target
	_sync_grip()


func move_panel_to(value: Vector2) -> void:
	if _panel == null:
		return
	_panel.position = value
	_sync_grip()


func dragging() -> bool:
	return not _drag_mode.is_empty()


# ================= 筛选条 =================

func _rebuild_plugin_filter() -> void:
	if _plugin_filter == null:
		return
	var counts := {}
	for def in _defs:
		var owner := def.owner_plugin
		counts[owner] = int(counts.get(owner, 0)) + 1
	var owners: Array[String] = []
	for key in counts.keys():
		owners.append(String(key))
	owners.sort()
	_plugin_filter.clear()
	_plugin_filter.add_item("全部插件（%d）" % _defs.size())
	_plugin_filter.set_item_metadata(0, "")
	for owner in owners:
		var label := (owner if not owner.is_empty() else "未标注插件") + "（%d）" % int(counts[owner])
		_plugin_filter.add_item(label)
		_plugin_filter.set_item_metadata(_plugin_filter.item_count - 1, owner)
		if owner == _plugin_filter_id:
			_plugin_filter.select(_plugin_filter.item_count - 1)


func _rebuild_chips() -> void:
	if _chips == null:
		return
	for child in _chips.get_children():
		_chips.remove_child(child)
		child.queue_free()
	var counts := {}
	for def in _defs:
		if not _accepts_port(def):
			continue
		counts[def.category] = int(counts.get(def.category, 0)) + 1
	var categories: Array[String] = []
	for key in counts.keys():
		categories.append(String(key))
	categories.sort()
	var entries: Array[Array] = [["all", "全部", _defs.size()]]
	if not _recent.is_empty():
		entries.append(["recent", "最近", _recent.size()])
	for category in categories:
		entries.append([category, category, int(counts[category])])
	for entry in entries:
		var key := String(entry[0])
		var text := String(entry[1])
		var count := int(entry[2])
		var color := FxUiKit.ACCENT if key == "all" else FxVisualIcon.category_color(key)
		var button := _chip_button("%s %d" % [FxI18n.text(text), count], color, key == _chip_filter)
		button.pressed.connect(func() -> void:
			_chip_filter = key
			_rebuild_chips()
			_refresh(_filter_text)
		)
		_chips.add_child(button)


func _chip_button(text: String, color: Color, active: bool) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 24)
	button.add_theme_font_size_override("font_size", 10)
	button.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG if active else color)
	button.add_theme_color_override("font_hover_color", FxUiKit.TEXT_STRONG)
	var bg := Color(color, 0.22) if active else Color(color, 0.08)
	var border := Color(color, 0.85) if active else Color(color, 0.30)
	button.add_theme_stylebox_override("normal", _chip_style(bg, border))
	button.add_theme_stylebox_override("hover", _chip_style(Color(color, 0.26), Color(color, 0.7)))
	button.add_theme_stylebox_override("pressed", _chip_style(Color(color, 0.3), color))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return button


func _chip_style(bg: Color, border: Color) -> StyleBoxFlat:
	var style := FxUiKit.panel_style(bg, border, 11)
	style.content_margin_left = 9.0
	style.content_margin_right = 9.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	return style


# ================= 过滤 / 排序 =================

func _refresh(filter_text: String) -> void:
	if _grid == null:
		return
	_filter_text = filter_text
	var needle := filter_text.strip_edges().to_lower()
	# 端口范围变了以后，原先选中的分类可能一个节点都不剩：回到「全部」而不是给空墙。
	if _chip_filter != "all" and _chip_filter != "recent":
		var alive := false
		for def in _defs:
			if def.category == _chip_filter and _accepts_port(def):
				alive = true
				break
		if not alive:
			_chip_filter = "all"
			_rebuild_chips()
	var scored: Array[Dictionary] = []
	for def in _defs:
		if not _accepts_port(def):
			continue
		if not _accepts_chip(def):
			continue
		if not _plugin_filter_id.is_empty() and def.owner_plugin != _plugin_filter_id:
			continue
		var score := _score(def, needle)
		if score < 0:
			continue
		scored.append({"def": def, "score": score})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := int(a["score"])
		var sb := int(b["score"])
		if sa != sb:
			return sa < sb
		var da: FxNodeDef = a["def"]
		var db: FxNodeDef = b["def"]
		# 有画面的节点排前面：默认打开面板就该看见「效果」，而不是一屏数值节点。
		var va := _has_visual(da)
		var vb := _has_visual(db)
		if va != vb:
			return va
		if da.category != db.category:
			return da.category < db.category
		return da.label < db.label
	)
	_filtered.clear()
	for item in scored:
		_filtered.append(item["def"])
	_rebuild_grid()
	_update_scope_bar()
	_update_count()
	var hint := "%d 个节点" % _filtered.size()
	if port_filter_active():
		hint += " · 已按端口类型限定"
	hint += " · ↑↓←→ 选择 · 回车添加 · Esc 关闭"
	_hint.text = hint


func _accepts_chip(def: FxNodeDef) -> bool:
	if _chip_filter == "all" or _chip_filter.is_empty():
		return true
	if _chip_filter == "recent":
		return _recent.has(String(def.id))
	return def.category == _chip_filter


func _update_count() -> void:
	if _count_label == null:
		return
	_count_label.text = "%d / %d" % [_filtered.size(), _defs.size()]


## 只保留存在兼容端口的节点定义。端口类型来自图能力代理（与连线校验同一张表），
## 所以候选列表永远不会给出「拖过去却连不上」的节点。
func _accepts_port(def: FxNodeDef) -> bool:
	if _port_type == &"":
		return true
	var ports := FxGraphFacade.access().catalog_ports(def, {})
	var candidates: Array = ports.get("inputs", []) if _port_want_input \
			else ports.get("outputs", [])
	for raw in candidates:
		if not raw is Dictionary:
			continue
		var candidate := FxGraphFacade.access().port_normalize((raw as Dictionary).get("type", &"any"))
		if _port_want_input:
			if FxGraphFacade.access().port_can_connect(_port_type, candidate):
				return true
		elif FxGraphFacade.access().port_can_connect(candidate, _port_type):
			return true
	return false


func _update_scope_bar() -> void:
	if _scope_bar == null:
		return
	var active := port_filter_active()
	_scope_bar.visible = active
	if active:
		var direction := "输入" if _port_want_input else "输出"
		_scope_label.text = "范围：仅显示能接上 %s 端口（%s）的节点 · %d 个可用" % [
			FxI18n.text(FxGraphFacade.access().port_label_of(_port_type)), direction, _filtered.size(),
		]


## 返回 -1 表示不匹配；0 起越小越靠前。负数只用于“最近使用”加权，
## 不能同时当“无匹配”哨兵，否则前缀命中会被误过滤。
func _score(def: FxNodeDef, needle: String) -> int:
	var recent_boost := -3 if _recent.has(String(def.id)) else 0
	if needle.is_empty():
		return recent_boost
	var label := def.label.to_lower()
	var id := String(def.id).to_lower()
	var category := def.category.to_lower()
	var desc := def.description.to_lower()
	if label.begins_with(needle) or id.begins_with(needle):
		return recent_boost
	if label.contains(needle):
		return recent_boost + 4
	if id.contains(needle):
		return recent_boost + 5
	if category.contains(needle):
		return recent_boost + 6
	if desc.contains(needle):
		return recent_boost + 7
	return -1


# ================= 卡片墙 =================

func _rebuild_grid() -> void:
	if _grid == null:
		return
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cards.clear()
	_preview_queue.clear()
	_queued.clear()
	_update_columns()
	for def in _filtered:
		var card := _build_card(def)
		_grid.add_child(card)
	_empty.visible = _filtered.is_empty()
	_grid.visible = not _filtered.is_empty()
	# 选中项还在就保留，否则选第一个，右侧详情永远有内容。
	if _selected_type.is_empty() or not _filtered.has(_find_def(_selected_type)):
		_selected_type = String(_filtered[0].id) if not _filtered.is_empty() else ""
	_apply_card_selection()
	_update_detail()


func _find_def(type_id: String) -> FxNodeDef:
	for def in _filtered:
		if String(def.id) == type_id:
			return def
	return null


## 卡片列数：按可用宽度算，最多 6 列，最少 1 列。
##
## 宽度从**面板尺寸**推算，而不是问 ScrollContainer：面板第一次打开时它还没排版，
## 读到的会是 0 或上一轮的旧值 —— 表现就是「明明拖宽了还是两列」。
func _update_columns() -> void:
	if _panel == null:
		return
	_update_columns_for(_panel.size.x)


func _update_columns_for(panel_width: float) -> void:
	if _grid == null or not is_instance_valid(_grid):
		return
	var available := panel_width - 24.0 - DETAIL_WIDTH - 10.0
	if available <= 1.0:
		available = PANEL_SIZE.x - DETAIL_WIDTH - 34.0
	var columns := int(floor((available - 12.0) / (CARD_SIZE.x + 8.0)))
	_grid.columns = clampi(columns, 1, 6)


## 一张卡片：缩略图 + 名称 + 归属与标记。点击选中，双击添加。
func _build_card(def: FxNodeDef) -> Control:
	var type_id := String(def.id)
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.tooltip_text = "%s\n%s · %s" % [type_id, def.category,
		def.owner_plugin if not def.owner_plugin.is_empty() else "未标注插件"]
	card.gui_input.connect(_on_card_input.bind(type_id))
	card.mouse_entered.connect(func() -> void: _style_card(type_id, true))
	card.mouse_exited.connect(func() -> void: _style_card(type_id, false))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	card.add_child(col)
	var thumb_wrap := PanelContainer.new()
	thumb_wrap.custom_minimum_size = THUMB_SIZE
	thumb_wrap.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(Color("#14161a"), Color(FxUiKit.BORDER_SOFT, 0.5), 4))
	thumb_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(thumb_wrap)
	var thumb := TextureRect.new()
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_wrap.add_child(thumb)
	var glyph := FxUiKit.strong(FxVisualIcon.category_glyph(def.category), 30)
	glyph.add_theme_color_override("font_color",
		Color(FxVisualIcon.category_color(def.category), 0.85))
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb_wrap.add_child(glyph)

	var name_label := FxUiKit.label(FxI18n.text(def.label), 11, FxUiKit.TEXT_STRONG)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_label)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 4)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(foot)
	var dot := FxUiKit.label("●", 8, FxVisualIcon.category_color(def.category))
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_child(dot)
	var owner_label := FxUiKit.label(_short_owner(def), 9, FxUiKit.MUTED)
	owner_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	owner_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	owner_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_child(owner_label)
	if def.gpu:
		foot.add_child(FxUiKit.label("GPU", 8, FxUiKit.DANGER))
	if def.is_output:
		foot.add_child(FxUiKit.label("OUT", 8, FxUiKit.OK))

	var info := {
		"root": card, "thumb": thumb, "glyph": glyph,
		"sheet": null, "frames": {}, "image_size": Vector2i.ZERO,
		"anim_clock": 0.0,
	}
	_cards[type_id] = info
	_style_card(type_id, false)
	_prime_thumbnail(def, info)
	return card


func _short_owner(def: FxNodeDef) -> String:
	if def.owner_plugin.is_empty():
		return def.category
	return def.owner_plugin


func _style_card(type_id: String, hover: bool) -> void:
	var info: Dictionary = _cards.get(type_id, {})
	var card: Control = info.get("root")
	if card == null or not is_instance_valid(card):
		return
	var selected := type_id == _selected_type
	var bg := FxUiKit.PANEL_ALT
	var border := Color(FxUiKit.BORDER_SOFT, 0.9)
	if selected:
		bg = Color(FxUiKit.ACCENT, 0.16)
		border = Color(FxUiKit.ACCENT, 0.85)
	elif hover:
		bg = Color(FxUiKit.PANEL_ALT, 1.0).lightened(0.04)
		border = Color(FxUiKit.ACCENT, 0.45)
	(card as PanelContainer).add_theme_stylebox_override("panel",
		FxUiKit.panel_style(bg, border, 6))


func _apply_card_selection() -> void:
	for key in _cards.keys():
		_style_card(String(key), false)


func _on_card_input(event: InputEvent, type_id: String) -> void:
	if not event is InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.double_click:
		_emit_choice_type(type_id)
		return
	if mb.pressed:
		_selected_type = type_id
		_apply_card_selection()
		_update_detail()
		get_viewport().set_input_as_handled()


# ================= 缩略图（三级回退） =================

## 第一级：节点自带纹理（可动图）；第二级：排进渲染样张队列；第三级：分类字形。
func _prime_thumbnail(def: FxNodeDef, info: Dictionary) -> void:
	var type_id := String(def.id)
	if not def.icon.is_empty():
		var base := def.source_file.get_base_dir()
		var full := FxVisualIcon.resolve(base, def.icon)
		var image := FxVisualIcon.image_of(full)
		if image != null:
			var size := image.get_size()
			var grid := FxVisualIcon.frames(def.icon_anim, size)
			if bool(grid.get("animated", false)):
				var atlas := AtlasTexture.new()
				atlas.atlas = ImageTexture.create_from_image(image)
				atlas.region = FxVisualIcon.frame_rect(0, grid, size)
				info["sheet"] = atlas
				info["frames"] = grid
				info["image_size"] = size
				(info["thumb"] as TextureRect).texture = atlas
			else:
				(info["thumb"] as TextureRect).texture = ImageTexture.create_from_image(image)
			(info["glyph"] as Label).visible = false
			return
	if _can_preview(type_id):
		if not _queued.has(type_id):
			_queued[type_id] = true
			_preview_queue.append(type_id)
		return
	# 三级回退：分类色块 + 字形（已经画好了，什么都不用做）。


func _can_preview(type_id: String) -> bool:
	return _render != null and _render.has_method("can_preview_node") \
		and bool(_render.call("can_preview_node", type_id))


## 这个节点打开面板时有没有画面可看（自带纹理 || 能渲染样张）。
## 排序比较器会被调用很多次，所以结果按类型缓存。
func _has_visual(def: FxNodeDef) -> bool:
	var type_id := String(def.id)
	if _visual_cache.has(type_id):
		return bool(_visual_cache[type_id])
	var visual := not def.icon.is_empty() or _can_preview(type_id)
	_visual_cache[type_id] = visual
	return visual


func _process(delta: float) -> void:
	if not visible:
		return
	_drain_preview_queue()
	_advance_card_animation(delta)
	_advance_detail_animation(delta)


func _drain_preview_queue() -> void:
	if _render == null or _preview_queue.is_empty():
		return
	var budget := PREVIEWS_PER_FRAME
	# 详情大图优先：用户正盯着它。
	if not _selected_type.is_empty() and _queued.has(_selected_type):
		_take_preview(_selected_type)
		_queued.erase(_selected_type)
		budget -= 1
	while budget > 0 and not _preview_queue.is_empty():
		var type_id: String = _preview_queue.pop_front()
		if not _queued.has(type_id) or not _cards.has(type_id):
			continue
		_take_preview(type_id)
		_queued.erase(type_id)
		budget -= 1


func _take_preview(type_id: String) -> void:
	var image: Variant = _render.call("preview_node", type_id, PREVIEW_SIZE, -1.0, true)
	if not image is Image:
		return
	var texture := ImageTexture.create_from_image(image as Image)
	var info: Dictionary = _cards.get(type_id, {})
	if not info.is_empty():
		var thumb: TextureRect = info.get("thumb")
		if thumb != null and is_instance_valid(thumb):
			thumb.texture = texture
			var glyph: Label = info.get("glyph")
			if glyph != null:
				glyph.visible = false
	if type_id == _selected_type:
		_show_detail_texture(image as Image)


func _advance_card_animation(delta: float) -> void:
	for key in _cards.keys():
		var info: Dictionary = _cards[key]
		var frames: Dictionary = info.get("frames", {})
		if frames.is_empty() or not bool(frames.get("animated", false)):
			continue
		var atlas: AtlasTexture = info.get("sheet")
		if atlas == null:
			continue
		var fps := float(frames.get("fps", 8.0))
		var clock := float(info.get("anim_clock", 0.0)) + delta
		info["anim_clock"] = clock
		var index := int(clock * fps)
		atlas.region = FxVisualIcon.frame_rect(index, frames, info.get("image_size", Vector2i.ONE))


# ================= 详情 =================

func _update_detail() -> void:
	_stop_anim()
	var def := _find_def(_selected_type)
	if def == null:
		_d_name.text = ""
		_d_id.text = ""
		_d_desc.text = ""
		_d_glyph.visible = true
		_d_thumb.texture = null
		_d_add.disabled = true
		for box in [_d_chips, _d_ports, _d_params]:
			for child in box.get_children():
				box.remove_child(child)
				child.queue_free()
		return
	_d_add.disabled = false
	_d_name.text = FxI18n.text(def.label)
	_d_id.text = "%s · %s" % [String(def.id), def.category]
	_d_desc.text = FxI18n.text(def.description) if not def.description.is_empty() else "（这个节点没有写说明）"
	_rebuild_detail_chips(def)
	_rebuild_detail_ports(def)
	_rebuild_detail_params(def)
	_show_detail_visual(def)


func _rebuild_detail_chips(def: FxNodeDef) -> void:
	for child in _d_chips.get_children():
		_d_chips.remove_child(child)
		child.queue_free()
	var color := FxVisualIcon.category_color(def.category)
	_d_chips.add_child(_pill(FxI18n.text(def.category), color))
	var owner := def.owner_plugin
	if owner.is_empty():
		_d_chips.add_child(_pill("未标注插件", FxUiKit.MUTED))
	else:
		_d_chips.add_child(_pill(owner, FxUiKit.ACCENT_COOL))
	if def.gpu:
		_d_chips.add_child(_pill("GPU · 主线程", FxUiKit.DANGER))
	if def.evaluate_always:
		_d_chips.add_child(_pill("每帧求值", FxUiKit.OK))
	if def.is_output:
		_d_chips.add_child(_pill("输出节点", FxUiKit.OK))


func _rebuild_detail_ports(def: FxNodeDef) -> void:
	for child in _d_ports.get_children():
		_d_ports.remove_child(child)
		child.queue_free()
	if not def.inputs.is_empty():
		_d_ports.add_child(_port_row("输入", def.inputs))
	if not def.outputs.is_empty():
		_d_ports.add_child(_port_row("输出", def.outputs))


func _port_row(title: String, ports: Array[Dictionary]) -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 4)
	var tag := FxUiKit.label(FxI18n.text(title), 9, FxUiKit.MUTED)
	tag.custom_minimum_size = Vector2(26, 0)
	row.add_child(tag)
	for port in ports:
		var type_name: StringName = FxGraphFacade.access().port_normalize(port.get("type", &"any"))
		var color := FxGraphFacade.access().port_color_of(type_name)
		var text := FxI18n.text(String(port.get("label", port.get("id", ""))))
		if String(port.get("id", "")).is_empty():
			continue
		row.add_child(_pill("%s · %s" % [text, FxGraphFacade.access().port_label_of(type_name)], color))
	return row


func _rebuild_detail_params(def: FxNodeDef) -> void:
	for child in _d_params.get_children():
		_d_params.remove_child(child)
		child.queue_free()
	if def.params.is_empty():
		return
	var head := FxUiKit.label("参数（%d）" % def.params.size(), 9, FxUiKit.ACCENT)
	_d_params.add_child(head)
	var shown := 0
	for param in def.params:
		if shown >= 6:
			_d_params.add_child(FxUiKit.label("…还有 %d 项" % (def.params.size() - shown), 9, FxUiKit.MUTED))
			break
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_label := FxUiKit.label(FxI18n.text(String(param.get("label", param.get("id", "")))), 10, FxUiKit.TEXT)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(name_label)
		var value := FxUiKit.label(_param_preview(param), 9, FxUiKit.MUTED)
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(value)
		_d_params.add_child(row)
		shown += 1


func _param_preview(param: Dictionary) -> String:
	var value: Variant = param.get("default", "")
	if value is String:
		return value if value.length() <= 14 else value.substr(0, 13) + "…"
	if value is Array:
		return "[%d]" % (value as Array).size()
	if value is Dictionary:
		return "{…}"
	if value is float:
		return "%.2f" % value
	return str(value)


func _show_detail_visual(def: FxNodeDef) -> void:
	_d_thumb.texture = null
	# 第一级：节点自带纹理（可动图，动图交给详情动画推进）。
	if not def.icon.is_empty():
		var base := def.source_file.get_base_dir()
		var full := FxVisualIcon.resolve(base, def.icon)
		var image := FxVisualIcon.image_of(full)
		if image != null:
			var grid := FxVisualIcon.frames(def.icon_anim, image.get_size())
			if bool(grid.get("animated", false)):
				_start_anim(String(def.id), image, grid)
			else:
				_d_thumb.texture = ImageTexture.create_from_image(image)
			_d_glyph.visible = false
			return
	# 第二级：真实渲染样张（时间相关的会动）。
	if _can_preview(String(def.id)):
		var image: Variant = _render.call("preview_node", String(def.id), DETAIL_PREVIEW, -1.0, true)
		if image is Image:
			_show_detail_texture(image as Image)
			_start_time_anim(String(def.id))
			return
	# 第三级：分类色块 + 字形。
	_d_glyph.visible = true
	_d_glyph.text = FxVisualIcon.category_glyph(def.category)
	_d_glyph.add_theme_color_override("font_color",
		Color(FxVisualIcon.category_color(def.category), 0.9))


func _show_detail_texture(image: Image) -> void:
	if _detail_tex == null:
		_detail_tex = ImageTexture.create_from_image(image)
	else:
		_detail_tex.set_image(image)
	_d_thumb.texture = _detail_tex
	_d_glyph.visible = false


func _start_time_anim(type_id: String) -> void:
	_anim_type = type_id
	_anim_t = 0.0
	_anim_clock = 0.0
	_anim_still = 0.0
	_anim_hash = 0


func _start_anim(type_id: String, image: Image, grid: Dictionary) -> void:
	_anim_type = type_id
	_card_sheet = ImageTexture.create_from_image(image)
	_card_grid = grid
	_card_size = image.get_size()
	_anim_clock = 0.0
	if _detail_atlas == null:
		_detail_atlas = AtlasTexture.new()
	_detail_atlas.atlas = _card_sheet
	_detail_atlas.region = FxVisualIcon.frame_rect(0, grid, _card_size)
	_d_thumb.texture = _detail_atlas
	_d_glyph.visible = false


func _stop_anim() -> void:
	_anim_type = ""
	_anim_clock = 0.0
	_card_sheet = null
	_anim_hash = 0


## 详情大图的两种动画：精灵表按帧切；渲染样张按时间轴推进。
## 画面连续几帧没变化就停下来，别让静态节点白白吃 CPU。
func _advance_detail_animation(delta: float) -> void:
	if _anim_type.is_empty():
		return
	if _card_sheet != null:
		_anim_clock += delta
		var index := int(_anim_clock * float(_card_grid.get("fps", 8.0)))
		if _detail_atlas != null:
			_detail_atlas.region = FxVisualIcon.frame_rect(index, _card_grid, _card_size)
		return
	_anim_clock += delta
	if _anim_clock < 1.0 / ANIM_FPS:
		return
	_anim_clock = 0.0
	_anim_t = fmod(_anim_t + 1.0 / ANIM_FPS, 1.0)
	var image: Variant = _render.call("preview_node", _anim_type, DETAIL_PREVIEW, _anim_t, false)
	if not image is Image:
		_stop_anim()
		return
	var made := image as Image
	var stamp := hash(made.get_data())
	_show_detail_texture(made)
	if stamp == _anim_hash:
		_anim_still += 1.0 / ANIM_FPS
		if _anim_still >= ANIM_SETTLE:
			_anim_type = ""
	else:
		_anim_hash = stamp
		_anim_still = 0.0


# ================= 小控件 =================

func _pill(text: String, color: Color) -> Control:
	var chip := PanelContainer.new()
	var style := FxUiKit.panel_style(Color(color, 0.14), Color(color, 0.42), 4)
	style.content_margin_left = 5.0
	style.content_margin_right = 5.0
	style.content_margin_top = 1.0
	style.content_margin_bottom = 1.0
	chip.add_theme_stylebox_override("panel", style)
	var label := FxUiKit.label(text, 9, color)
	chip.add_child(label)
	chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return chip


# ================= 键盘 =================

func _on_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_DOWN:
			_move_selection(1)
			get_viewport().set_input_as_handled()
		KEY_UP:
			_move_selection(-1)
			get_viewport().set_input_as_handled()
		KEY_RIGHT:
			_move_selection(maxi(1, _grid.columns))
			get_viewport().set_input_as_handled()
		KEY_LEFT:
			_move_selection(-maxi(1, _grid.columns))
			get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER:
			if not _selected_type.is_empty():
				_emit_choice_type(_selected_type)
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			hide_picker()
			get_viewport().set_input_as_handled()


func _move_selection(delta: int) -> void:
	if _filtered.is_empty():
		return
	var index := 0
	for i in range(_filtered.size()):
		if String(_filtered[i].id) == _selected_type:
			index = i
			break
	index = clampi(index + delta, 0, _filtered.size() - 1)
	_selected_type = String(_filtered[index].id)
	_apply_card_selection()
	_update_detail()
	var info: Dictionary = _cards.get(_selected_type, {})
	var card: Control = info.get("root")
	if card != null and is_instance_valid(card):
		_grid_scroll.ensure_control_visible(card)


func _emit_choice_type(type_id: String) -> void:
	var def := FxGraphFacade.access().catalog_def(type_id)
	if def == null:
		return
	_emit_choice(def)


func _emit_choice(def: FxNodeDef) -> void:
	var id := String(def.id)
	_recent.erase(id)
	_recent.push_front(id)
	while _recent.size() > RECENT_LIMIT:
		_recent.pop_back()
	node_chosen.emit(id)
	hide_picker()
