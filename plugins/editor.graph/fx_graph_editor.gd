class_name FxGraphEditor
extends Control
## 蓝图画布面板（插件 editor.graph 提供）。
##
## 职责边界（与解释器核心解耦）：
##   · 图领域的一切访问都走 FxGraphFacade 代理，本文件不含 FxCatalog /
##     FxPortType / FxGraphDoc / FxGraphRunner 中的任何一个符号；
##   · 渲染服务只按 Node 契约连接信号，不绑定具体渲染器类型；
##   · 节点创建弹窗由 FxNodePickerBroker 从插件取，停用即安全降级；
##   · 工具栏、时间轴、预览、文件、导出都不在这里 —— 它们是别的插件。
## 因此换一个图解释器、换一个渲染后端、换一个节点选择器，都不用改蓝图。
##
## 视图与文档的同步是“文档优先”：任何结构变化先改 doc，再按 doc 重建视图与连线。
## 边存的是端口 id，不是插槽索引，所以动态端口变化不会丢连线。

var shell: FxShell
var store: FxDocumentStore
var render: Node
var graph: GraphEdit
var node_views: Dictionary = {}
var param_panel: FxNodeParams
var create_dialog: FxNodePicker

var _create_at: Vector2 = Vector2(160, 160)
var _suppress_store_rebuild: bool = false
var _syncing_selection: bool = false
var _initial_fit_done: bool = false
## 从端口把线拖到空白处时记下的上下文，选中节点后自动补上这条连线。
var _pending_link: Dictionary = {}
## 节点折叠状态属于视图，不进文档。值是显式 bool：用户展开过就存 false，
## 这样「默认收起」和「用户主动展开」不会互相覆盖。
var _collapsed_nodes: Dictionary = {}
## 蓝图加载后预览默认收起（设置项 graph.preview_collapsed，默认 true）。
const DEFAULT_COLLAPSED_SETTING := "graph.preview_collapsed"
## 用户拖出来的节点尺寸（按节点 id），同样只是视图状态。
var _node_sizes: Dictionary = {}
## 多选集合（id -> true）：GraphEdit 只在 Ctrl+C 之类的信号里给出选中节点，
## 所以自己记账，框选 / Ctrl+点选 / 橡皮筋都会经 node_selected 通知到这里。
var _selection: Dictionary = {}
## 待应用的整批选中（粘贴 / 拖拽导入 / 程序化多选）。
## 必须先等结构重建把视图造出来再选中，否则视图还不存在、选中会被重建覆盖，
## 表现为「粘贴完却选中了上一次的那批节点」。
var _pending_multi_select: Array[String] = []
## 上一次跨节点操作的时间戳（毫秒），防止「快捷键」与「GraphEdit 请求信号」各执行一次。
var _action_stamp: Dictionary = {}
## 蓝图剪贴板的内部副本：系统剪贴板不可用（无头/远程会话）时兜底。
var _clip_payload: Dictionary = {}
var _paste_step: int = 0
## 剪贴板文本格式标记：带这个头的 JSON 才是蓝图节点包，可以贴到任何文档/任何窗口。
const CLIP_SCHEMA := "phantom.graph.clipboard"
const CLIP_VERSION := 1
## 多次结构变化只排一次重建，避免同一帧反复拆建视图（GraphEdit 端口缓存会错乱）。
var _rebuild_pending: bool = false
## 最近一帧执行器解析出的参数（按节点），重建视图后补推。
var _live_params: Dictionary = {}
## 动画预览时节点卡片上的「实时参数值 / 缩略图」不跟着每帧变。
## 真实工程 103 节点一次求帧会推 100+ 组参数与 55 张预览，全是 UI 线程工作；
## 播放期间完全冻结，连续求帧时按间隔合并，停下来再补推最新的一份。
const LIVE_PUSH_INTERVAL_MS := 220
var _live_frozen: bool = false
var _live_pending: Dictionary = {}
var _preview_pending: Dictionary = {}
var _last_live_push_ms: int = 0

# ================= 文档标签条 =================
##
## 一个面板同时开多份文档，像浏览器标签：主干常驻且不可关闭，双击子图节点
## 就把子工程开成新标签。切换标签 = 换掉 store 装载的文档，因此时间轴、预览、
## 文档属性这些跟着 store 走的面板会自动同步到当前标签。
##
## 每个标签自己记文档、播放头、以及「打开/上次保存时的指纹」，
## 关标签时如果指纹变了就先写回文件，不逼用户另存。
## 结构：{id, title, path, doc, time, hash, root}

var _tabs: Array[Dictionary] = []
var _active_tab: int = 0
var _tab_strip: Control
var _tab_row: HBoxContainer
var _tab_menu: PopupMenu
var _tab_buttons: Array[Button] = []
## 切换文档时 store 会连发一串通知，这期间不要去改标签态（会自己套自己）。
var _switching_tab: bool = false

# ---- 节点右键菜单 ----
var _node_menu: PopupMenu
## 右键菜单弹出的位置（图坐标），「粘贴」这类没有落点的动作就用它。
var _menu_at: Vector2 = Vector2.ZERO

var doc: Dictionary:
	get: return store.doc if store != null else {}
var runner: RefCounted:
	get: return render.get("runner") as RefCounted if render != null else null


## 面板工厂：外壳用这个 Callable 创建实例。
static func create(ctx: Dictionary) -> Control:
	var panel := FxGraphEditor.new()
	panel.setup(ctx)
	return panel


func setup(ctx: Dictionary) -> void:
	shell = ctx.get("shell")
	store = ctx.get("store")
	render = ctx.get("render")
	name = "GraphEditorPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()
	_setup_graph_types()
	if store != null:
		store.changed.connect(_on_store_changed)
	if render != null and render.has_signal("node_previewed"):
		render.connect("node_previewed", Callable(self, "_on_node_previewed"))
	if render != null and render.has_signal("node_params_resolved"):
		render.connect("node_params_resolved", Callable(self, "_on_node_params_resolved"))
	if render != null and render.has_signal("playback_changed"):
		render.connect("playback_changed", Callable(self, "_on_playback_changed"))
	set_process(true)
	if shell != null:
		shell.provide("graph.editor", self)
	_rebuild_graph()


func _build_ui() -> void:
	# 顶部文档标签条 + 画布。标签条由本面板自己管：文档切换是「编辑器的事」，
	# 外壳不需要知道现在开的是哪张子图。
	var host := VBoxContainer.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_theme_constant_override("separation", 0)
	add_child(host)
	host.add_child(_build_tab_strip())

	graph = GraphEdit.new()
	graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.show_menu = false
	graph.show_zoom_label = true
	graph.minimap_enabled = true
	graph.minimap_size = Vector2(150, 96)
	graph.minimap_opacity = 0.32
	graph.grid_pattern = GraphEdit.GRID_PATTERN_DOTS
	# 滚轮缩放；中键拖动平移是 GraphEdit 内置行为。
	graph.panning_scheme = GraphEdit.SCROLL_ZOOMS
	graph.right_disconnects = true
	graph.connection_lines_curvature = 0.35
	graph.connection_lines_thickness = 3.0
	graph.snapping_distance = 20
	host.add_child(graph)

	graph.connection_request.connect(_on_connection_request)
	graph.disconnection_request.connect(_on_disconnection_request)
	graph.delete_nodes_request.connect(_on_delete_nodes_request)
	graph.node_selected.connect(_on_node_selected)
	graph.node_deselected.connect(_on_node_deselected)
	# GraphEdit 自己发起的剪贴板请求（Ctrl+C/X/V/D）：和我们的快捷键走同一套实现。
	graph.copy_nodes_request.connect(func() -> void: _copy_selection())
	graph.cut_nodes_request.connect(func() -> void: _cut_selection())
	graph.paste_nodes_request.connect(func() -> void: _paste_clipboard())
	graph.duplicate_nodes_request.connect(func() -> void: _duplicate_selection())
	graph.begin_node_move.connect(func() -> void:
		if store != null:
			store.begin_batch()
	)
	graph.end_node_move.connect(_on_end_node_move)
	graph.popup_request.connect(_on_popup_request)
	# 从输出口 / 输入口把线拖到空白处：打开「按端口类型限定」的节点备选。
	graph.connection_to_empty.connect(_on_connection_to_empty)
	graph.connection_from_empty.connect(_on_connection_from_empty)
	graph.connection_drag_started.connect(_on_connection_drag_started)
	graph.gui_input.connect(_on_graph_gui_input)
	# 拖文件进画布：交给 FxDropBroker，本文件不认识任何具体的导入实现。
	# 面板工厂创建时 Control 还没入树，拿不到 window，只能等入树后再接。
	_bind_window_drops.call_deferred()

	# 节点弹窗由服务代理从插件取：换实现 / 停用插件都不需要改这个文件。
	create_dialog = FxNodePickerBroker.create(shell if shell != null else self)
	if shell != null:
		shell.add_child(create_dialog)
	else:
		add_child(create_dialog)
	create_dialog.node_chosen.connect(_on_node_chosen)
	create_dialog.reload_defs()

	# 节点右键菜单：选中/未选中都走同一张表，只是可用项不同。
	_node_menu = PopupMenu.new()
	_node_menu.id_pressed.connect(_on_node_menu_id)
	add_child(_node_menu)
	# 标签条右键：关闭 / 关闭其他 / 保存 / 重载。
	_tab_menu = PopupMenu.new()
	_tab_menu.id_pressed.connect(_on_tab_menu_id)
	add_child(_tab_menu)
	_init_tabs()


# ================= 文档标签条 =================

func _build_tab_strip() -> Control:
	_tab_strip = PanelContainer.new()
	_tab_strip.custom_minimum_size.y = 30
	_tab_strip.mouse_filter = Control.MOUSE_FILTER_STOP
	_tab_strip.add_theme_stylebox_override("panel", FxUiKit.chrome_style("dock_bar"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	_tab_strip.add_child(row)
	_tab_row = row
	_tab_row.gui_input.connect(_on_tab_row_input)
	return _tab_strip


## 首次装载：主干标签就是当前文档。
func _init_tabs() -> void:
	_reset_tabs_to_root()


## 把标签结构收成「只有主干」——外部换了文档时用。
func _reset_tabs_to_root() -> void:
	_tabs.clear()
	_active_tab = 0
	if store == null:
		_rebuild_tabs()
		return
	_tabs.append({
		"id": "root",
		"title": String(FxGraphFacade.access().doc_meta(store.doc, "name", "主干")),
		"path": "",
		"doc": store.doc,
		"time": store.current_time,
		"hash": _doc_hash(store.doc),
		"root": true,
	})
	_rebuild_tabs()


static func _doc_hash(value: Dictionary) -> int:
	return JSON.stringify(value).hash()


func _active() -> Dictionary:
	if _active_tab < 0 or _active_tab >= _tabs.size():
		return {}
	return _tabs[_active_tab]


func _rebuild_tabs() -> void:
	if _tab_row == null:
		return
	for child in _tab_row.get_children():
		_tab_row.remove_child(child)
		child.queue_free()
	_tab_buttons.clear()
	for i in range(_tabs.size()):
		_tab_row.add_child(_build_tab_cell(i))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_row.add_child(fill)


func _build_tab_cell(index: int) -> Control:
	var tab: Dictionary = _tabs[index]
	var active := index == _active_tab
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 0)
	cell.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var button := Button.new()
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.clip_text = true
	button.set_pressed_no_signal(active)
	button.custom_minimum_size = Vector2(150, 28)
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	button.add_theme_font_size_override("font_size", 11)
	button.add_theme_stylebox_override("normal", FxUiKit.tab_style(false))
	button.add_theme_stylebox_override("hover", FxUiKit.tab_style(active, true))
	button.add_theme_stylebox_override("pressed", FxUiKit.tab_style(true))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", FxUiKit.MUTED)
	button.add_theme_color_override("font_hover_color", FxUiKit.TEXT_STRONG)
	button.add_theme_color_override("font_pressed_color", FxUiKit.ACCENT)
	var dirty := _tab_dirty(index)
	var glyph := "◈" if bool(tab.get("root", false)) else "▸"
	button.text = "%s %s%s" % [glyph, String(tab.get("title", "")), " •" if dirty else ""]
	button.tooltip_text = _tab_tooltip(index)
	button.pressed.connect(func() -> void: switch_tab(index))
	button.gui_input.connect(_on_tab_button_input.bind(index))
	cell.add_child(button)
	_tab_buttons.append(button)

	# 主干常驻：没有关闭按钮，避免把「工作台」关掉。
	if not bool(tab.get("root", false)):
		var close := FxUiKit.flat_button("×", "关闭这个标签", 13)
		close.custom_minimum_size = Vector2(22, 28)
		close.add_theme_stylebox_override("normal", FxUiKit.tab_style(active))
		close.add_theme_stylebox_override("hover", FxUiKit.tab_style(active, true))
		close.pressed.connect(func() -> void: close_tab(index))
		cell.add_child(close)
	return cell


func _tab_tooltip(index: int) -> String:
	var tab: Dictionary = _tabs[index]
	var path := String(tab.get("path", ""))
	if path.is_empty():
		return "%s（主干，不可关闭）" % String(tab.get("title", ""))
	return "%s\n%s\n双击标签切换；右键有更多操作" % [String(tab.get("title", "")), path]


func _tab_dirty(index: int) -> bool:
	if index < 0 or index >= _tabs.size():
		return false
	var tab: Dictionary = _tabs[index]
	var current: Dictionary = store.doc if index == _active_tab and store != null else tab.get("doc", {})
	return _doc_hash(current) != int(tab.get("hash", 0))


## 把活动标签的现场（文档 / 播放头）存回槽位。
func _stash_active() -> void:
	if store == null or _active_tab < 0 or _active_tab >= _tabs.size():
		return
	var tab: Dictionary = _tabs[_active_tab]
	tab["doc"] = store.doc
	tab["time"] = store.current_time


func switch_tab(index: int) -> void:
	if index < 0 or index >= _tabs.size() or index == _active_tab or store == null:
		return
	_stash_active()
	_active_tab = index
	_switching_tab = true
	var tab: Dictionary = _tabs[index]
	# 换文档顺带清空视图态：折叠 / 尺寸 / 多选都是「这份文档的」。
	_collapsed_nodes.clear()
	_node_sizes.clear()
	_selection.clear()
	_pending_multi_select.clear()
	_pending_link.clear()
	_initial_fit_done = false
	store.attach((tab.get("doc", {}) as Dictionary).duplicate(true))
	# attach 会 normalize 出一份新 Dictionary：把引用收回槽位，
	# 后面「store.doc 是否还是这个标签的文档」才判得准。
	tab["doc"] = store.doc
	store.set_time(float(tab.get("time", 0.0)))
	_switching_tab = false
	_rebuild_tabs()
	_rebuild_graph()
	_fit_after_layout()
	_status("已切换到 %s" % String(tab.get("title", "")))


## 打开子图节点指向的文档；已经开着就直接切过去，不会开第二个同名标签。
func open_subgraph(node_id: String) -> bool:
	var g := FxGraphFacade.access()
	var data := g.doc_node(doc, node_id)
	if data.is_empty():
		_status("没有这个节点：%s" % node_id)
		return false
	if not g.catalog_openable(String(data.get("type", ""))):
		_status("这个节点不能进入：它不是一个把文档当节点的类型")
		return false
	var raw := String((data.get("params", {}) as Dictionary).get("path", ""))
	if raw.strip_edges().is_empty():
		_status("这个子图节点还没选文件：先在参数里挑一个 .fxgraph")
		return false
	var path := g.doc_resolve_path(raw)
	if path.is_empty():
		_status("子图文件找不到：%s" % raw)
		return false
	var existing := tab_index_of(path)
	if existing >= 0:
		switch_tab(existing)
		return true
	var loaded := g.doc_load(path)
	if loaded.is_empty():
		_status("子图文件读不出来：%s" % path.get_file())
		return false
	_stash_active()
	_tabs.append({
		"id": "sub:%d" % _tabs.size(),
		"title": String(g.doc_meta(loaded, "name", path.get_file())),
		"path": path,
		"doc": loaded,
		"time": store.current_time if store != null else 0.0,
		"hash": _doc_hash(loaded),
		"root": false,
	})
	_active_tab = _tabs.size() - 1
	_switching_tab = true
	_collapsed_nodes.clear()
	_node_sizes.clear()
	_selection.clear()
	_pending_multi_select.clear()
	_pending_link.clear()
	_initial_fit_done = false
	store.attach(loaded.duplicate(true))
	_tabs[_active_tab]["doc"] = store.doc
	_switching_tab = false
	_rebuild_tabs()
	_rebuild_graph()
	_fit_after_layout()
	_status("已进入子图：%s（关闭标签即可回到主干）" % path.get_file())
	return true


func tab_index_of(path: String) -> int:
	for i in range(_tabs.size()):
		if String(_tabs[i].get("path", "")) == path:
			return i
	return -1


func close_tab(index: int) -> void:
	if index < 0 or index >= _tabs.size():
		return
	if bool(_tabs[index].get("root", false)):
		_status("主干标签不能关闭")
		return
	var tab: Dictionary = _tabs[index]
	var path := String(tab.get("path", ""))
	var dirty := _tab_dirty(index)
	if index == _active_tab:
		_stash_active()
	# 子图是「另一个文件」：关标签前把改动写回去，否则用户会以为改动丢了。
	if dirty and not path.is_empty():
		var err := FxGraphFacade.access().doc_save(tab.get("doc", {}), path)
		if err != OK:
			_status("子图保存失败：%s（标签保留）" % error_string(err))
			return
	var was_active := index == _active_tab
	_tabs.remove_at(index)
	if was_active:
		_active_tab = clampi(index - 1, 0, _tabs.size() - 1)
		var back: Dictionary = _tabs[_active_tab]
		_switching_tab = true
		_collapsed_nodes.clear()
		_node_sizes.clear()
		_selection.clear()
		_pending_multi_select.clear()
		_initial_fit_done = false
		store.attach((back.get("doc", {}) as Dictionary).duplicate(true))
		back["doc"] = store.doc
		store.set_time(float(back.get("time", 0.0)))
		_switching_tab = false
		_rebuild_graph()
		_fit_after_layout()
	elif index < _active_tab:
		_active_tab -= 1
	_rebuild_tabs()
	_status("已关闭 %s%s" % [String(tab.get("title", "")), "（改动已保存）" if dirty else ""])


func save_tab(index: int) -> void:
	if index < 0 or index >= _tabs.size():
		return
	if index == _active_tab:
		_stash_active()
	var tab: Dictionary = _tabs[index]
	var path := String(tab.get("path", ""))
	if path.is_empty():
		_status("主干请用「文件 → 保存 / 另存为」")
		return
	var err := FxGraphFacade.access().doc_save(tab.get("doc", {}), path)
	if err != OK:
		_status("保存失败：%s" % error_string(err))
		return
	tab["hash"] = _doc_hash(tab.get("doc", {}))
	_rebuild_tabs()
	_status("✓ 已保存 %s" % path.get_file())


## 从磁盘重读当前标签（文件被外部改过时用）。
func reload_tab(index: int) -> void:
	if index < 0 or index >= _tabs.size():
		return
	var path := String(_tabs[index].get("path", ""))
	if path.is_empty():
		_status("主干请用「文件 → 重新载入」")
		return
	var loaded := FxGraphFacade.access().doc_load(path)
	if loaded.is_empty():
		_status("文件读不出来：%s" % path.get_file())
		return
	_tabs[index]["doc"] = loaded
	_tabs[index]["hash"] = _doc_hash(loaded)
	if index == _active_tab:
		store.attach(loaded.duplicate(true))
	_rebuild_tabs()
	_status("已从磁盘重读 %s" % path.get_file())


# ---- 标签条交互 ----

func _on_tab_button_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return
	_popup_tab_menu(index)
	get_viewport().set_input_as_handled()


func _on_tab_row_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return
	_popup_tab_menu(_active_tab)
	get_viewport().set_input_as_handled()


func _popup_tab_menu(index: int) -> void:
	_tab_menu.clear()
	_tab_menu.add_item("切换到此处", 0)
	_tab_menu.set_item_disabled(0, index == _active_tab)
	_tab_menu.add_separator()
	_tab_menu.add_item("保存这个标签", 1)
	_tab_menu.set_item_disabled(1, String(_tabs[index].get("path", "")).is_empty())
	_tab_menu.add_item("从磁盘重新载入", 2)
	_tab_menu.set_item_disabled(2, String(_tabs[index].get("path", "")).is_empty())
	_tab_menu.add_separator()
	var closable := not bool(_tabs[index].get("root", false))
	_tab_menu.add_item("关闭这个标签", 3)
	_tab_menu.set_item_disabled(3, not closable)
	_tab_menu.add_item("关闭其他标签", 4)
	_tab_menu.add_item("关闭全部子图标签", 5)
	_tab_menu.set_item_metadata(0, index)
	_tab_menu.set_item_metadata(1, index)
	_tab_menu.set_item_metadata(2, index)
	_tab_menu.set_item_metadata(3, index)
	var at := get_global_mouse_position()
	if _tab_buttons.size() > index:
		at = _tab_buttons[index].get_global_rect().get_center()
	_tab_menu.position = Vector2i(at) + Vector2i(0, 8)
	_tab_menu.popup()


func _on_tab_menu_id(id: int) -> void:
	var index := int(_tab_menu.get_item_metadata(id)) if _tab_menu.get_item_metadata(id) != null else -1
	match id:
		0:
			switch_tab(index)
		1:
			save_tab(index)
		2:
			reload_tab(index)
		3:
			close_tab(index)
		4:
			_close_other_tabs()
		5:
			_close_sub_tabs()


func _close_other_tabs() -> void:
	# 从后往前删，索引才不会漂。
	for i in range(_tabs.size() - 1, -1, -1):
		if i != _active_tab and not bool(_tabs[i].get("root", false)):
			close_tab(i)


func _close_sub_tabs() -> void:
	for i in range(_tabs.size() - 1, 0, -1):
		close_tab(i)


func tab_titles() -> Array[String]:
	var out: Array[String] = []
	for tab in _tabs:
		out.append(String(tab.get("title", "")))
	return out


func tab_count() -> int:
	return _tabs.size()


func active_tab() -> int:
	return _active_tab


func tab_closable(index: int) -> bool:
	if index < 0 or index >= _tabs.size():
		return false
	return not bool(_tabs[index].get("root", false))


func tab_dirty(index: int) -> bool:
	return _tab_dirty(index)


func open_tab_paths() -> Array[String]:
	var out: Array[String] = []
	for tab in _tabs:
		out.append(String(tab.get("path", "")))
	return out


## 当前标签对应的文件路径；主干返回空串。
## 文档服务用它判断「现在按 Ctrl+S 该存哪张」——两边不互相认识，只认这两个方法名。
func active_document_path() -> String:
	return String(_active().get("path", ""))


func active_tab_dirty() -> bool:
	return _tab_dirty(_active_tab)


func save_active_tab() -> void:
	save_tab(_active_tab)



func _setup_graph_types() -> void:
	for a in FxGraphFacade.access().port_order():
		for b in FxGraphFacade.access().port_order():
			if FxGraphFacade.access().port_can_connect(a, b):
				graph.add_valid_connection_type(FxGraphFacade.access().port_id_of(a), FxGraphFacade.access().port_id_of(b))


## Ctrl + 滚轮 = 横向滚动。放在 _input 里是为了抢在 GraphEdit 自己的
## 滚轮缩放之前；没有 Ctrl 的滚轮一律放行给 GraphEdit 处理。
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or graph == null or not is_instance_valid(graph):
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or not mb.ctrl_pressed:
		return
	if mb.button_index != MOUSE_BUTTON_WHEEL_UP and mb.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return
	if not graph.get_global_rect().has_point(mb.position):
		return
	var delta := -72.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 72.0
	graph.scroll_offset.x += delta / maxf(graph.zoom, 0.1)
	get_viewport().set_input_as_handled()


## 首次装载后等一帧再适应视图：此时 GraphEdit 已经拿到真实尺寸。
## 皮肤/停靠样式切换会重建面板，工厂创建 Control 时它还没入树，
## 所以这里必须先等 ready，不能直接 get_tree()。
func _fit_after_layout() -> void:
	if not is_inside_tree():
		await ready
	if not is_inside_tree() or get_tree() == null:
		return
	await get_tree().process_frame
	if not is_inside_tree():
		return
	_fit_view()


func _fit_view() -> void:
	if node_views.is_empty():
		return
	var bounds := Rect2()
	var first := true
	for id in node_views.keys():
		var view: FxGraphNodeView = node_views[id]
		var rect := Rect2(view.position_offset, view.size)
		bounds = rect if first else bounds.merge(rect)
		first = false
	if bounds.size.x <= 1.0 or bounds.size.y <= 1.0:
		return
	var available := graph.size - Vector2(80, 80)
	var zoom_value := minf(available.x / bounds.size.x, available.y / bounds.size.y)
	graph.zoom = clampf(zoom_value, graph.zoom_min, 1.0)
	graph.scroll_offset = (bounds.position + bounds.size * 0.5) * graph.zoom - graph.size * 0.5
	_status("已适应视图")


# ================= 视图重建 =================

## 折叠只是视图状态：不改文档、不进撤销栈，但要在重建后保留。
func _on_collapse_changed(node_id: String, value: bool) -> void:
	_collapsed_nodes[node_id] = value


func _on_node_size_changed(node_id: String, value: Vector2) -> void:
	_node_sizes[node_id] = value


## 布局完成后再设一次尺寸：GraphNode 会先按内容算最小尺寸，过早赋值会被它覆盖。
func _apply_node_size(view: FxGraphNodeView, value: Vector2) -> void:
	if is_instance_valid(view) and view.is_inside_tree():
		view.size = value


func _schedule_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	_rebuild_graph.call_deferred()


func _rebuild_graph() -> void:
	_rebuild_pending = false
	if graph == null:
		return
	var scroll := graph.scroll_offset
	var zoom := graph.zoom
	graph.clear_connections()
	for id in node_views.keys():
		var view: FxGraphNodeView = node_views[id]
		graph.remove_child(view)
		# 延迟释放：此刻 GraphEdit 可能还在遍历它的连线，立即 free 会让端口缓存指向死节点。
		view.queue_free()
	node_views.clear()

	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var def := FxGraphFacade.access().catalog_def(node_data.get("type", ""))
		if def == null:
			push_warning("未知节点类型：%s" % String(node_data.get("type", "")))
			continue
		var view := FxGraphNodeView.new()
		view.setup(String(node_data.get("id", "")), def, node_data, store,
			Callable(self, "_apply_param_edit"))
		var key := String(node_data.get("id", ""))
		view.set_collapsed(bool(_collapsed_nodes.get(key, _default_collapsed())))
		view.collapse_changed = Callable(self, "_on_collapse_changed")
		view.size_changed = Callable(self, "_on_node_size_changed")
		view.gui_input.connect(_on_node_gui_input.bind(view))
		graph.add_child(view)
		var pos: Array = node_data.get("pos", [0, 0])
		view.position_offset = Vector2(float(pos[0]), float(pos[1]))
		var node_key := String(node_data.get("id", ""))
		node_views[node_key] = view
		if _node_sizes.has(node_key):
			view.size = _node_sizes[node_key]
			_apply_node_size.call_deferred(view, Vector2(_node_sizes[node_key]))
		elif view.collapsed:
			# 默认收起的节点要真的变矮，而不是留着预览那一块空白。
			view.fit_collapsed.call_deferred()
	_sync_connections()
	graph.scroll_offset = scroll
	graph.zoom = zoom
	param_panel = null
	if not _initial_fit_done and not node_views.is_empty():
		_initial_fit_done = true
		_fit_after_layout()
	var selected := store.selected_id if store != null else ""
	# 重建会换掉全部视图：把旧的多选收成「还活着的 id」，再和待应用批次合并，
	# 在末尾统一应用一次。这样「粘贴一批」不会被重建打回单选。
	var keep: Array[String] = []
	for raw in _selection.keys():
		var key := String(raw)
		if node_views.has(key):
			keep.append(key)
	_selection.clear()
	if not _pending_multi_select.is_empty():
		_apply_selection_set(_pending_multi_select, selected)
	elif keep.size() > 1:
		_apply_selection_set(keep, selected)
	else:
		_apply_selection_set([selected], selected)
	# 新建的视图还没收到本帧参数：把上次广播补推过去，连线驱动值不会「空一帧」。
	_push_live_params()


func _sync_connections() -> void:
	graph.clear_connections()
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		var from_view: FxGraphNodeView = node_views.get(from_id)
		var to_view: FxGraphNodeView = node_views.get(to_id)
		if from_view == null or to_view == null:
			continue
		if from_view.right_slots.is_empty() or to_view.left_slots.is_empty():
			# 节点还没有任何输出/输入插槽时不要 connect_node：
			# GraphEdit 会缓存这条非法连线，之后每次绘制都报「port index out of bounds」。
			continue
		var from_port := from_view.output_port_index(String(edge.get("from_port", "")))
		var to_port := to_view.input_port_index(String(edge.get("to_port", "")))
		if from_port < 0 or to_port < 0:
			continue
		var err := graph.connect_node(StringName(from_id), from_port, StringName(to_id), to_port)
		if err != OK:
			push_warning("连线恢复失败：%s.%s → %s.%s" % [from_id, edge.get("from_port"), to_id, edge.get("to_port")])


# ================= 交互 =================

func _on_connection_request(from_node: StringName, from_port: int,
		to_node: StringName, to_port: int) -> void:
	var from_view: FxGraphNodeView = node_views.get(String(from_node))
	var to_view: FxGraphNodeView = node_views.get(String(to_node))
	if from_view == null or to_view == null:
		return
	var from_pid := from_view.output_port_id_at(from_port)
	var to_pid := to_view.input_port_id_at(to_port)
	if from_pid.is_empty() or to_pid.is_empty():
		return
	var result := store.connect_ports(String(from_node), from_pid, String(to_node), to_pid)
	var g := FxGraphFacade.access()
	if result == g.link_ok():
		# 不再在这里手动 _sync_connections()：文档已变，视图会整体重建并重连。
		# 在同一帧里用旧视图重连，会让 GraphEdit 缓存一条指向旧插槽的连线，
		# 之后每次绘制都报 get_output_port_position 越界。
		_status("已连接 %s.%s → %s.%s" % [from_node, from_pid, to_node, to_pid])
	elif result == g.link_type():
		_status("类型不兼容：%s → %s" % [from_pid, to_pid])
	elif result == g.link_cycle():
		_status("不能成环；循环请用“循环”节点")
	else:
		_status("端口不存在")


func _on_disconnection_request(from_node: StringName, from_port: int,
		to_node: StringName, to_port: int) -> void:
	var from_view: FxGraphNodeView = node_views.get(String(from_node))
	var to_view: FxGraphNodeView = node_views.get(String(to_node))
	if from_view == null or to_view == null:
		return
	var from_pid := from_view.output_port_id_at(from_port)
	var to_pid := to_view.input_port_id_at(to_port)
	store.disconnect_ports(String(from_node), from_pid, String(to_node), to_pid)


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	if store != null:
		store.remove_nodes(Array(nodes))


func _on_end_node_move() -> void:
	if store == null:
		return
	for id in node_views.keys():
		var view: FxGraphNodeView = node_views[id]
		store.set_node_position(id, view.position_offset)
	store.commit_batch(["positions"])


# ================= 复制 / 剪切 / 粘贴 =================
##
## 剪贴板是一个**自描述 JSON 包**，写进系统剪贴板：
##   · 贴回本程序任意文档 / 任意窗口都能重建节点与内部连线；
##   · 贴到外部编辑器里就是一段可读 JSON，改完再贴回来也能用；
##   · 包内节点保留自己的 id、参数（含轨道）、折叠状态与尺寸，
##     粘贴时换新 id 并按 id 映射重连边。
## 多选由 _selection 记账（框选 / Ctrl+点选都走 node_selected）。

## Ctrl+C / Ctrl+X / Ctrl+V / Ctrl+D。GraphEdit 的同名请求信号也走这里，
## _action_stamp 保证同一个手势不会被快捷键和信号各执行一次。
func _on_graph_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or not key.ctrl_pressed:
		return
	match key.keycode:
		KEY_C:
			_copy_selection()
		KEY_X:
			_cut_selection()
		KEY_V:
			_paste_clipboard()
		KEY_D:
			_duplicate_selection()
		_:
			return
	get_viewport().set_input_as_handled()


## 同一个手势可能先被 GraphEdit 转成 *_request 信号，再被键盘兜底处理；
## 80ms 内的重复动作直接忽略，避免一次 Ctrl+V 贴出两份。
func _claim_action(action: String) -> bool:
	var now := Time.get_ticks_msec()
	if int(_action_stamp.get(action, -1000)) > now - 80:
		return false
	_action_stamp[action] = now
	return true


func _copy_selection() -> void:
	if not _claim_action("copy"):
		return
	_write_clipboard()


func _cut_selection() -> void:
	if not _claim_action("cut"):
		return
	_write_clipboard()
	var ids := _selected_ids()
	if not ids.is_empty():
		store.remove_nodes(ids)


func _duplicate_selection() -> void:
	if not _claim_action("duplicate"):
		return
	_write_clipboard()
	_paste_clipboard(true)


# ---- 选区 ----

## 当前选中的节点 id（按名字排序，保证同样的选区生成同样的包）。
func _selected_ids() -> Array[String]:
	var out: Array[String] = []
	for raw in _selection.keys():
		var id := String(raw)
		if node_views.has(id):
			out.append(id)
	if out.is_empty() and store != null and not store.selected_id.is_empty() \
			and node_views.has(store.selected_id):
		out.append(store.selected_id)
	out.sort()
	return out


## 把一批 id 设成唯一的选中集合（GraphEdit 内部选中态一起同步）。
## fallback 只在整批 id 都不存在时兜底（例如文档里只剩一个节点）。
func _apply_selection_set(ids: Array, fallback: String = "") -> void:
	if graph == null:
		return
	var wanted: Array[String] = []
	for raw in ids:
		var id := String(raw)
		if node_views.has(id) and not wanted.has(id):
			wanted.append(id)
	if wanted.is_empty() and not fallback.is_empty() and node_views.has(fallback):
		wanted.append(fallback)
	_pending_multi_select.clear()
	_syncing_selection = true
	# 先把所有节点的 selected 抹平：`selected = true` 只加不减，
	# 不主动取消上一批就会出现「新旧两批一起高亮」。
	for raw in node_views.keys():
		var view: FxGraphNodeView = node_views[raw]
		if view.selected:
			view.selected = false
	_selection.clear()
	for id in wanted:
		(node_views[id] as FxGraphNodeView).selected = true
		_selection[id] = true
	_syncing_selection = false
	if store != null:
		store.set_selection(wanted[0] if not wanted.is_empty() else "")
	_apply_selection(store.selected_id if store != null else "")


func _select_many(ids: Array) -> void:
	if graph == null:
		return
	_pending_multi_select.clear()
	for raw in ids:
		_pending_multi_select.append(String(raw))
	if _rebuild_pending:
		# 视图还没造出来，等重建末尾统一应用（否则选中会被重建覆盖成单选）。
		return
	_apply_selection_set(_pending_multi_select)


func _on_node_selected(node: Node) -> void:
	if _syncing_selection or store == null:
		return
	var id := String(node.name)
	if not node_views.has(id):
		return
	_selection[id] = true
	var node_data := FxGraphFacade.access().doc_node(doc, id)
	var def := FxGraphFacade.access().catalog_def(node_data.get("type", ""))
	if def != null and def.is_output and FxGraphFacade.access().doc_output_id(doc).is_empty():
		store.set_output(id)
	store.set_selection(id)


func _on_node_deselected(node: Node) -> void:
	if _syncing_selection or store == null:
		return
	var id := String(node.name)
	_selection.erase(id)
	if id == store.selected_id:
		# 多选里还有别的节点时，主选中项顺延给其中一个，不要直接清空。
		var rest := _selected_ids()
		store.set_selection(rest[0] if not rest.is_empty() else "")


# ---- 打包 / 解包 ----

## 把选区打成剪贴板包并写入系统剪贴板。
func _write_clipboard() -> void:
	if store == null:
		return
	var ids := _selected_ids()
	if ids.is_empty():
		_status("先选中节点再复制")
		return
	var payload := build_clip_payload(ids)
	if payload.is_empty():
		return
	_clip_payload = payload
	_paste_step = 0
	var text := JSON.stringify(payload, "  ")
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(text)
	_status("已复制 %d 个节点（可贴到别的图或外部文本）" % ids.size())


## 纯函数：把一组节点 id 打成自描述包（不碰剪贴板，测试可直接调用）。
## 坐标系用绝对图坐标，另存 origin 便于粘贴时对齐鼠标位置。
func build_clip_payload(ids: Array) -> Dictionary:
	if store == null:
		return {}
	var wanted := {}
	for raw in ids:
		wanted[String(raw)] = true
	var nodes: Array = []
	var edges: Array = []
	var origin := Vector2(INF, INF)
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		if not wanted.has(id):
			continue
		var pos := _vec2_of(node_data.get("pos", [0, 0]))
		origin.x = minf(origin.x, pos.x)
		origin.y = minf(origin.y, pos.y)
		var params: Variant = node_data.get("params", {})
		var entry := {
			"id": id,
			"type": String(node_data.get("type", "")),
			"pos": [pos.x, pos.y],
			"params": (params as Dictionary).duplicate(true) if params is Dictionary else {},
		}
		entry["collapsed"] = bool(_collapsed_nodes.get(id, _default_collapsed()))
		if _node_sizes.has(id):
			var s: Vector2 = _node_sizes[id]
			entry["size"] = [s.x, s.y]
		nodes.append(entry)
	if nodes.is_empty():
		return {}
	if origin.x == INF:
		origin = Vector2.ZERO
	# 只要两端都在选区里的边：跨界连线贴出来会指向不存在的节点。
	for item2 in doc.get("edges", []):
		var edge: Dictionary = item2
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		if not wanted.has(from_id) or not wanted.has(to_id):
			continue
		edges.append({
			"from": from_id, "from_port": String(edge.get("from_port", "")),
			"to": to_id, "to_port": String(edge.get("to_port", "")),
		})
	return {
		"schema": CLIP_SCHEMA,
		"version": CLIP_VERSION,
		"app": "幻像工坊",
		"kind": "graph_nodes",
		"origin": [origin.x, origin.y],
		"canvas": FxGraphFacade.access().doc_canvas(store.doc),
		"nodes": nodes,
		"edges": edges,
	}


## 读系统剪贴板：既认完整包，也认被外部编辑器改过的裸 {"nodes": [...]}。
func read_clip_payload() -> Dictionary:
	var text := ""
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		text = DisplayServer.clipboard_get()
	var parsed := parse_clip_text(text)
	if not parsed.is_empty():
		return parsed
	return _clip_payload.duplicate(true)


## 纯函数：解析剪贴板文本（容错：允许前后有说明文字，只要中间是合法 JSON 对象）。
static func parse_clip_text(text: String) -> Dictionary:
	var body := text.strip_edges()
	if body.is_empty():
		return {}
	if not body.begins_with("{"):
		var start := body.find("{")
		var end := body.rfind("}")
		if start < 0 or end <= start:
			return {}
		body = body.substr(start, end - start + 1)
	var parsed: Variant = JSON.parse_string(body)
	if not parsed is Dictionary:
		return {}
	var data: Dictionary = parsed
	if data.has("schema") and String(data.get("schema", "")) != CLIP_SCHEMA:
		return {}
	var nodes: Variant = data.get("nodes")
	if not nodes is Array or (nodes as Array).is_empty():
		return {}
	for raw in nodes:
		if not raw is Dictionary or String((raw as Dictionary).get("type", "")).is_empty():
			return {}
	return data


# ---- 粘贴 ----

func _paste_clipboard(from_duplicate: bool = false) -> void:
	if not from_duplicate and not _claim_action("paste"):
		return
	if store == null:
		return
	var payload := read_clip_payload()
	if payload.is_empty():
		_status("剪贴板里没有蓝图节点")
		return
	var nodes: Array = payload.get("nodes", [])
	var origin := _vec2_of(payload.get("origin", [0, 0]))
	var anchor := _paste_anchor()
	var offset := anchor - origin
	_paste_step += 1
	if not from_duplicate:
		offset += Vector2(28, 28) * float(_paste_step - 1)
	var mapping: Dictionary = {}
	var created_ids: Array[String] = []
	store.begin_batch()
	for raw in nodes:
		var entry: Dictionary = raw
		var type := String(entry.get("type", ""))
		if FxGraphFacade.access().catalog_def(type) == null:
			continue
		var params: Variant = entry.get("params", {})
		var pos := _vec2_of(entry.get("pos", [0, 0])) + offset
		var created := store.add_node(type, "", pos,
			(params as Dictionary).duplicate(true) if params is Dictionary else {})
		var new_id := String(created.get("id", ""))
		if new_id.is_empty():
			continue
		mapping[String(entry.get("id", new_id))] = new_id
		created_ids.append(new_id)
		# 视图状态在提交前写进记录表：重建时就能按原样恢复折叠与尺寸。
		_collapsed_nodes[new_id] = bool(entry.get("collapsed", _default_collapsed()))
		var raw_size: Variant = entry.get("size", null)
		if raw_size is Array and (raw_size as Array).size() >= 2:
			_node_sizes[new_id] = Vector2(float((raw_size as Array)[0]), float((raw_size as Array)[1]))
	for raw_edge in payload.get("edges", []):
		var edge: Dictionary = raw_edge
		var from_id := String(mapping.get(String(edge.get("from", "")), ""))
		var to_id := String(mapping.get(String(edge.get("to", "")), ""))
		if from_id.is_empty() or to_id.is_empty():
			continue
		store.connect_ports(from_id, String(edge.get("from_port", "")),
			to_id, String(edge.get("to_port", "")))
	store.commit_batch()
	if created_ids.is_empty():
		_status("剪贴板里的节点类型本图不认识")
		return
	_select_many.call_deferred(created_ids)
	_status("已粘贴 %d 个节点" % created_ids.size())


## 粘贴落点：鼠标在画布上就贴到鼠标，否则贴到视图中心（图坐标）。
func _paste_anchor() -> Vector2:
	if graph == null or not is_instance_valid(graph):
		return Vector2.ZERO
	var mouse := graph.get_global_mouse_position()
	if graph.get_global_rect().has_point(mouse):
		return (graph.get_local_mouse_position() + graph.scroll_offset) / maxf(graph.zoom, 0.01)
	return (graph.scroll_offset + graph.size * 0.5) / maxf(graph.zoom, 0.01)


## 公开的落点查询：别的插件要往图里加节点时用它，不用自己算滚动与缩放。
func paste_position() -> Vector2:
	return _paste_anchor()


## 公开的多选：拖拽导入一次落下好几个节点时，让它们一起处于选中状态。
func select_nodes(ids: Array) -> void:
	_select_many(ids)


static func _vec2_of(raw: Variant) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	if raw is Dictionary:
		return Vector2(float((raw as Dictionary).get("x", 0.0)), float((raw as Dictionary).get("y", 0.0)))
	return Vector2.ZERO


## 拖文件进画布：只负责算落点，具体怎么导入由 FxDropBroker 的 provider 决定。
func _bind_window_drops() -> void:
	if not is_inside_tree():
		await ready
	if not is_inside_tree() or get_tree() == null:
		return
	var win := get_window()
	if win != null and not win.files_dropped.is_connected(_on_files_dropped):
		win.files_dropped.connect(_on_files_dropped)


func _on_files_dropped(files: PackedStringArray) -> void:
	if graph == null or not is_instance_valid(graph) or files.is_empty():
		return
	if not graph.get_global_rect().has_point(graph.get_global_mouse_position()):
		return
	if not FxDropBroker.can_handle(Array(files)):
		return
	var result := FxDropBroker.handle({
		"files": Array(files),
		"position": _paste_anchor(),
		"shell": shell,
		"store": store,
		"editor": self,
	})
	var count := int(result.get("count", 0))
	if count > 0:
		_status(String(result.get("message", "已导入 %d 个文件" % count)))
		get_viewport().set_input_as_handled()
	elif not String(result.get("message", "")).is_empty():
		_status(String(result.get("message", "")))


## 节点上的鼠标：左键双击进子图，右键出节点菜单。
##
## 空白处的右键走 GraphEdit 的 popup_request（= 添加节点面板），
## 两者不会打架：节点会吃掉自己范围内的右键，GraphEdit 只在空白处发信号。
func _on_node_gui_input(event: InputEvent, view: FxGraphNodeView) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	var node_id := view.node_id
	if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
		if FxGraphFacade.access().catalog_openable(String(
				FxGraphFacade.access().doc_node(doc, node_id).get("type", ""))):
			open_subgraph(node_id)
			get_viewport().set_input_as_handled()
		return
	if mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	_menu_at = view.position_offset + mb.position / maxf(graph.zoom, 0.01)
	_pending_link.clear()
	# 点在没选中的节点上：先把选区收成它（和主流编辑器一致），
	# 点在已选中的节点上：保留整批，菜单对整批生效。
	if not _selection.has(node_id):
		_apply_selection_set([node_id])
	_popup_node_menu(view.get_screen_position() + mb.position)
	get_viewport().set_input_as_handled()


# ================= 节点右键菜单 =================
##
## 一张声明式的表：菜单项与它的可用条件都放在 `node_menu_items()` 里，
## 测试可以直接断言这张表，不用去点弹窗。

const MENU_ENTER := "enter"
const MENU_COPY := "copy"
const MENU_CUT := "cut"
const MENU_DUP := "duplicate"
const MENU_PASTE := "paste"
const MENU_DELETE := "delete"
const MENU_COLLAPSE := "collapse"
const MENU_PACK := "pack"
const MENU_UNPACK := "unpack"
const MENU_SELECT_ALL := "select_all"
const MENU_FIT := "fit"


## 右键菜单的条目（纯数据）。`separator` 项没有 id。
func node_menu_items(ids: Array) -> Array[Dictionary]:
	var count := ids.size()
	var single := ""
	if count == 1:
		single = String(ids[0])
	var type_id := ""
	if not single.is_empty():
		type_id = String(FxGraphFacade.access().doc_node(doc, single).get("type", ""))
	var openable := not single.is_empty() \
		and FxGraphFacade.access().catalog_openable(type_id)
	var many := " %d 个节点" % count if count > 1 else ""
	return [
		{"id": MENU_ENTER, "label": "打开子图（双击）", "disabled": not openable},
		{"separator": true},
		{"id": MENU_COPY, "label": "复制%s  Ctrl+C" % many, "disabled": count == 0},
		{"id": MENU_CUT, "label": "剪切%s  Ctrl+X" % many, "disabled": count == 0},
		{"id": MENU_DUP, "label": "复制一份%s  Ctrl+D" % many, "disabled": count == 0},
		{"id": MENU_PASTE, "label": "粘贴到此处  Ctrl+V", "disabled": false},
		{"id": MENU_DELETE, "label": "删除%s  Delete" % many, "disabled": count == 0},
		{"separator": true},
		{"id": MENU_COLLAPSE, "label": "折叠 / 展开预览", "disabled": count == 0},
		{"id": MENU_PACK, "label": "打包成子图  Ctrl+G", "disabled": count == 0},
		{"id": MENU_UNPACK, "label": "展开子图  Ctrl+Shift+G", "disabled": not openable},
		{"separator": true},
		{"id": MENU_SELECT_ALL, "label": "全选  Ctrl+A", "disabled": node_views.is_empty()},
		{"id": MENU_FIT, "label": "适应视图", "disabled": node_views.is_empty()},
	]


func _popup_node_menu(at: Vector2) -> void:
	if _node_menu == null:
		return
	var ids := _selected_ids()
	_node_menu.clear()
	for item in node_menu_items(ids):
		if bool(item.get("separator", false)):
			_node_menu.add_separator()
			continue
		var index := _node_menu.item_count
		_node_menu.add_item(String(item.get("label", "")), index)
		_node_menu.set_item_disabled(index, bool(item.get("disabled", false)))
		_node_menu.set_item_metadata(index, String(item.get("id", "")))
	if _node_menu.item_count == 0:
		return
	_node_menu.position = Vector2i(at)
	_node_menu.reset_size()
	_node_menu.popup()


func _on_node_menu_id(id: int) -> void:
	var action := String(_node_menu.get_item_metadata(id)) if _node_menu.get_item_metadata(id) != null else ""
	if action.is_empty():
		return
	var ids := _selected_ids()
	match action:
		MENU_ENTER:
			if not ids.is_empty():
				open_subgraph(ids[0])
		MENU_COPY:
			_copy_selection()
		MENU_CUT:
			_cut_selection()
		MENU_DUP:
			_duplicate_selection()
		MENU_PASTE:
			_create_at = _menu_at
			_pending_link.clear()
			_paste_clipboard()
		MENU_DELETE:
			if store != null and not ids.is_empty():
				store.remove_nodes(ids)
				_status("已删除 %d 个节点" % ids.size())
		MENU_COLLAPSE:
			_toggle_collapse(ids)
		MENU_PACK:
			_pack_selection()
		MENU_UNPACK:
			_unpack_selection()
		MENU_SELECT_ALL:
			_select_all()
		MENU_FIT:
			_fit_view()


## 批量折叠：只要有一个是展开的，就把这批全收起来；全收着就全展开。
func _toggle_collapse(ids: Array) -> void:
	var any_open := false
	for id in ids:
		var view: FxGraphNodeView = node_views.get(String(id))
		if view != null and not view.collapsed:
			any_open = true
	var target := any_open
	for id in ids:
		var view: FxGraphNodeView = node_views.get(String(id))
		if view == null:
			continue
		_collapsed_nodes[String(id)] = target
		view.set_collapsed(target)
		if target:
			view.fit_collapsed.call_deferred()
	_status("%s %d 个节点" % ["已收起" if target else "已展开", ids.size()])


func _select_all() -> void:
	var ids: Array[String] = []
	for raw in node_views.keys():
		ids.append(String(raw))
	_apply_selection_set(ids)


func _on_popup_request(at_position: Vector2) -> void:
	_create_at = (at_position + graph.scroll_offset) / maxf(graph.zoom, 0.01)
	_pending_link.clear()
	var screen := graph.get_screen_position() + at_position
	create_dialog.open_at(screen)


func _popup_create_menu() -> void:
	_pending_link.clear()
	_create_at = (graph.size * 0.5 + graph.scroll_offset) / maxf(graph.zoom, 0.01)
	var screen := graph.get_screen_position() + graph.size * 0.5
	create_dialog.open_at(screen)


func _on_connection_drag_started(from_node: StringName, from_port: int,
		is_output: bool) -> void:
	var view: FxGraphNodeView = node_views.get(String(from_node))
	if view == null:
		return
	var port_id := view.output_port_id_at(from_port) if is_output \
			else view.input_port_id_at(from_port)
	if port_id.is_empty():
		return
	_status("从 %s.%s 拖出：松开后按 %s 类型筛选节点" % [
		from_node, port_id, FxGraphFacade.access().port_label_of(_port_type_of(String(from_node), port_id, is_output)),
	])


## 从输出口拖到空白：新节点必须提供一个兼容的输入端口。
func _on_connection_to_empty(from_node: StringName, from_port: int,
		release_position: Vector2) -> void:
	var view: FxGraphNodeView = node_views.get(String(from_node))
	if view == null:
		return
	var port_id := view.output_port_id_at(from_port)
	if port_id.is_empty():
		return
	var port_type := _port_type_of(String(from_node), port_id, true)
	_create_at = (release_position + graph.scroll_offset) / maxf(graph.zoom, 0.01)
	_pending_link = {
		"from_node": String(from_node), "from_port": port_id,
		"to_node": "", "to_port": "", "type": port_type, "want_input": true,
	}
	create_dialog.open_for_port(graph.get_screen_position() + release_position,
		port_type, true)


## 从输入口拖到空白：新节点必须提供一个兼容的输出端口。
func _on_connection_from_empty(to_node: StringName, to_port: int,
		release_position: Vector2) -> void:
	var view: FxGraphNodeView = node_views.get(String(to_node))
	if view == null:
		return
	var port_id := view.input_port_id_at(to_port)
	if port_id.is_empty():
		return
	var port_type := _port_type_of(String(to_node), port_id, false)
	_create_at = (release_position + graph.scroll_offset) / maxf(graph.zoom, 0.01)
	_pending_link = {
		"from_node": "", "from_port": "",
		"to_node": String(to_node), "to_port": port_id,
		"type": port_type, "want_input": false,
	}
	create_dialog.open_for_port(graph.get_screen_position() + release_position,
		port_type, false)


func _port_type_of(node_id: String, port_id: String, is_output: bool) -> StringName:
	var data := FxGraphFacade.access().doc_node(doc, node_id)
	var def := FxGraphFacade.access().catalog_def(data.get("type", ""))
	if def == null:
		return FxGraphFacade.access().port_any()
	var ports := FxGraphFacade.access().catalog_ports(def, data.get("params", {}))
	var list: Array = ports.get("outputs", []) if is_output else ports.get("inputs", [])
	return FxGraphFacade.access().port_normalize(FxGraphFacade.access().catalog_find_port(list, port_id).get("type", FxGraphFacade.access().port_any()))


func _on_node_chosen(type: String) -> void:
	var def := FxGraphFacade.access().catalog_def(type)
	if def == null:
		_status("节点类型不存在：%s" % type)
		return
	var data := store.add_node(type, "", _create_at)
	var new_id := String(data.get("id", ""))
	store.set_selection(new_id)
	_status("已添加 %s" % def.label)
	if not _pending_link.is_empty():
		_complete_pending_link(new_id, data)


## 候选列表只给出兼容端口，这里再按同一张类型表挑第一个可用端口并连线。
func _complete_pending_link(new_id: String, new_data: Dictionary) -> void:
	var pending := _pending_link.duplicate()
	_pending_link.clear()
	var def := FxGraphFacade.access().catalog_def(new_data.get("type", ""))
	if def == null:
		return
	var ports := FxGraphFacade.access().catalog_ports(def, new_data.get("params", {}))
	var list: Array = ports.get("inputs", []) if bool(pending["want_input"]) \
			else ports.get("outputs", [])
	var source_type: StringName = pending["type"]
	var picked := ""
	for raw in list:
		if not raw is Dictionary:
			continue
		var spec: Dictionary = raw
		var candidate := FxGraphFacade.access().port_normalize(spec.get("type", FxGraphFacade.access().port_any()))
		var compatible := FxGraphFacade.access().port_can_connect(source_type, candidate) \
				if bool(pending["want_input"]) \
				else FxGraphFacade.access().port_can_connect(candidate, source_type)
		if compatible:
			picked = String(spec.get("id", ""))
			break
	if picked.is_empty():
		_status("新节点没有兼容端口，已跳过连线")
		return
	var result := 0
	if bool(pending["want_input"]):
		result = store.connect_ports(String(pending["from_node"]),
			String(pending["from_port"]), new_id, picked)
	else:
		result = store.connect_ports(new_id, picked,
			String(pending["to_node"]), String(pending["to_port"]))
	if result == FxGraphFacade.access().link_ok():
		_sync_connections()
		_status("已添加节点并自动连线")
	else:
		_status("自动连线失败（%d）" % result)


func _select(id: String) -> void:
	var view: FxGraphNodeView = node_views.get(id)
	if view == null:
		return
	_syncing_selection = true
	graph.set_selected(view)
	_syncing_selection = false
	store.set_selection(id)


# ================= 参数 / 上下文 =================

## 节点内联编辑器的写回回调：全部走可逆效果，滑块连续修改会合并成一个撤销点。
func _apply_param_edit(node_id: String, param_id: String, value: Variant, structural: bool) -> void:
	if store != null:
		store.apply_param(node_id, param_id, value, structural)


func _apply_selection(id: String) -> void:
	var selected_view: FxGraphNodeView = node_views.get(id)
	param_panel = selected_view.params_ui if selected_view != null else null


## 上下文的反应式入口：只处理与本次变化相关的键，不做全量刷新。
## store 通知的键是 "param:<node>:<id>" / "node:<id>"，不是单个 "param"。
func _on_store_changed(keys: Array) -> void:
	if _switching_tab:
		# 切标签期间的通知由 switch_tab / close_tab 自己收尾，别在这里二次重建。
		return
	if not _tabs.is_empty() and _active_tab < _tabs.size():
		# 外部换了文档（打开工程 / 新建 / 欢迎页）：标签立刻作废。
		# 不这么做的话，子图标签里再按 Ctrl+S 会把新文档写进旧子图文件。
		if not store.doc.is_empty() and not is_same(_tabs[_active_tab].get("doc"), store.doc):
			_reset_tabs_to_root()
	if keys.has("selection"):
		# 外部改选中（拖拽导入 / 打开文档）要同步进多选集合；
		# 但多选内部切换主选中项时不能把集合清成 1 个。
		if store.selected_id.is_empty():
			_selection.clear()
		elif not _selection.has(store.selected_id):
			_selection = {store.selected_id: true}
		_apply_selection(store.selected_id)
	if _touches_params(keys):
		_refresh_param_views(keys)
	if keys.has("structure") and not _suppress_store_rebuild:
		_schedule_rebuild()
	if _touches_content(keys):
		_refresh_tab_titles()


## 除了「播放头 / 选中 / 轨道静音」这些纯视图键，其余都算改过内容（标签要打点）。
func _touches_content(keys: Array) -> bool:
	for key in keys:
		var text := String(key)
		if text == "time" or text == "selection" or text == "tracks":
			continue
		return true
	return false


## 标签标题带没带「未保存」的点，只改文本不重建按钮（重建会闪、也会抢焦点）。
func _refresh_tab_titles() -> void:
	for i in range(mini(_tab_buttons.size(), _tabs.size())):
		var button := _tab_buttons[i]
		if not is_instance_valid(button):
			continue
		var tab: Dictionary = _tabs[i]
		var glyph := "◈" if bool(tab.get("root", false)) else "▸"
		button.text = "%s %s%s" % [glyph, String(tab.get("title", "")),
			" •" if _tab_dirty(i) else ""]


func _touches_params(keys: Array) -> bool:
	for key in keys:
		var text := String(key)
		if text.begins_with("param:") or text.begins_with("node:"):
			return true
	return false


func _default_collapsed() -> bool:
	return bool(FxSettings.typed_value(DEFAULT_COLLAPSED_SETTING, true))


func _refresh_param_views(keys: Array) -> void:
	var only := ""
	for key in keys:
		var text := String(key)
		if text.begins_with("node:"):
			only = text.substr(5)
			break
	if only.is_empty():
		for id in node_views.keys():
			var each: FxGraphNodeView = node_views[id]
			each.sync_document_data(FxGraphFacade.access().doc_node(doc, id))
			each.sync_params()
		return
	var view: FxGraphNodeView = node_views.get(only)
	if view != null:
		view.sync_document_data(FxGraphFacade.access().doc_node(doc, only))
		view.sync_params()


## 本帧参数广播：只推给有被驱动参数的节点视图，其余视图不做无谓刷新。
func _on_node_params_resolved(params_by_node: Dictionary) -> void:
	_live_params = params_by_node
	_live_pending = params_by_node
	if _live_frozen:
		return
	if Time.get_ticks_msec() - _last_live_push_ms < LIVE_PUSH_INTERVAL_MS:
		return
	_flush_live()


func _flush_live() -> void:
	_last_live_push_ms = Time.get_ticks_msec()
	if _live_pending.is_empty():
		return
	for key in _live_pending.keys():
		var view: FxGraphNodeView = node_views.get(String(key))
		if view == null:
			continue
		var values: Variant = _live_pending[key]
		if values is Dictionary:
			view.apply_live_params(values)
	_live_pending.clear()


func _flush_previews() -> void:
	if _preview_pending.is_empty():
		return
	for key in _preview_pending.keys():
		var view: FxGraphNodeView = node_views.get(String(key))
		if view != null:
			view.set_preview(_preview_pending[key] as Image)
	_preview_pending.clear()


func _on_playback_changed(playing: bool) -> void:
	_live_frozen = playing
	if playing:
		_live_pending.clear()
		_preview_pending.clear()
		return
	# 停下来：补推最新的一帧，节点卡片不会停在动画中途的旧值上。
	_flush_live()
	_flush_previews()


func _process(_delta: float) -> void:
	if _live_frozen:
		return
	# 连续拖动时间轴 / 改参数时，攒够间隔再统一刷一次 UI。
	if Time.get_ticks_msec() - _last_live_push_ms < LIVE_PUSH_INTERVAL_MS:
		return
	_flush_live()
	_flush_previews()


## 重建后新视图还没拿到本帧参数，补推一次（否则要等下一帧才显示上游值）。
func _push_live_params() -> void:
	if _live_params.is_empty():
		return
	for key in _live_params.keys():
		var view: FxGraphNodeView = node_views.get(String(key))
		var values: Variant = _live_params[key]
		if view != null and values is Dictionary:
			view.apply_live_params(values)


func _on_node_previewed(node_id: String, image: Image) -> void:
	if _live_frozen:
		return
	_preview_pending[node_id] = image
	if Time.get_ticks_msec() - _last_live_push_ms >= LIVE_PUSH_INTERVAL_MS:
		_flush_live()
		_flush_previews()


func _status(message: String) -> void:
	if shell != null:
		shell.status(message)


# ================= 命令入口（静态，供插件注册） =================

static func cmd_add_node(ctx: Dictionary) -> void:
	var panel: FxGraphEditor = ctx["shell"].panel("editor.graph")
	if panel != null:
		panel.call("_popup_create_menu")


static func cmd_fit_view(ctx: Dictionary) -> void:
	var panel: FxGraphEditor = ctx["shell"].panel("editor.graph")
	if panel != null:
		panel.call("_fit_view")


static func cmd_arrange(ctx: Dictionary) -> void:
	var panel: FxGraphEditor = ctx["shell"].panel("editor.graph")
	if panel != null:
		panel.graph.arrange_nodes()
		panel.call("_on_end_node_move")
		panel.call("_status", "已自动排列")


# ================= 节点打包 / 解包（预合成） =================
##
## 打包 = AE 的 pre-compose：把选中的一堆节点收进一个新的子图文档，
## 原图里只留一个 graph.subgraph 节点。
##
## 跨边界的连线不会丢：进来的每条线在子图里换成一个「子图输入」节点，
## 出去（按源端口去重）换成「子图输出」节点，原图那一侧的连线接到子图节点
## 对应端口上。执行流（exec）边没法用值表达，所以直接拒绝并说清原因。

const PACK_DIR := "user://graphs"

func _pack_selection() -> void:
	if store == null:
		return
	var ids := _selected_ids()
	if ids.is_empty():
		_status("先选中要打包的节点")
		return
	var g := FxGraphFacade.access()
	var inside := {}
	for id in ids:
		inside[id] = true

	var incoming: Array = []
	var outgoing: Array = []
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		var from_in := inside.has(String(edge.get("from", "")))
		var to_in := inside.has(String(edge.get("to", "")))
		if from_in and not to_in:
			outgoing.append(edge)
		elif to_in and not from_in:
			incoming.append(edge)

	var bad := ""
	for edge in incoming + outgoing:
		var from_id := String(edge.get("from", ""))
		var from_port := String(edge.get("from_port", ""))
		if _boundary_type(_port_type_of(from_id, from_port, true)).is_empty():
			bad = "%s.%s" % [from_id, from_port]
			break
	if not bad.is_empty():
		_status("打包只支持图像 / 数值 / 向量 / 颜色 / 布尔 / 文本穿过边界（%s 不行），先改接或断开" % bad)
		return

	# 子图文档：保留节点 id、参数（含轨道）与内部连线，位置归一化到左上角。
	var sub := g.doc_new("%s · 打包" % String(FxGraphFacade.access().doc_meta(doc, "name", "图")))
	g.set_doc_canvas(sub, g.doc_canvas(doc))
	var origin := Vector2(INF, INF)
	var far := Vector2(-INF, -INF)
	for id in ids:
		var nd := g.doc_node(doc, id)
		var pos := _vec2_of(nd.get("pos", [0, 0]))
		origin = Vector2(minf(origin.x, pos.x), minf(origin.y, pos.y))
		far = Vector2(maxf(far.x, pos.x), maxf(far.y, pos.y))
	if origin.x == INF:
		origin = Vector2.ZERO
		far = Vector2.ZERO
	for id in ids:
		var nd2 := g.doc_node(doc, id)
		var params: Variant = nd2.get("params", {})
		g.doc_add_node(sub, String(nd2.get("type", "")), String(nd2.get("id", id)),
			_vec2_of(nd2.get("pos", [0, 0])) - origin,
			(params as Dictionary).duplicate(true) if params is Dictionary else {})
	for item2 in doc.get("edges", []):
		var edge2: Dictionary = item2
		var f := String(edge2.get("from", ""))
		var t := String(edge2.get("to", ""))
		if inside.has(f) and inside.has(t):
			g.doc_connect(sub, f, String(edge2.get("from_port", "")), t,
				String(edge2.get("to_port", "")))

	# 外部输入 → 子图输入节点；外部输出（按源端口去重）→ 子图输出节点。
	var in_links: Array = []
	var y := 0.0
	for edge in incoming:
		var from_id := String(edge.get("from", ""))
		var from_port := String(edge.get("from_port", ""))
		var kind := _boundary_type(_port_type_of(from_id, from_port, true))
		var made := g.doc_add_node(sub, "graph.input", "",
			Vector2(origin.x - 340.0, y), {"name": _port_label(from_id, from_port), "type": kind})
		var port_id := String(made.get("id", ""))
		if port_id.is_empty():
			continue
		g.doc_connect(sub, port_id, "value", String(edge.get("to", "")), String(edge.get("to_port", "")))
		in_links.append({"source": from_id, "port": from_port, "boundary": port_id})
		y += 150.0

	var out_links: Array = []
	var seen := {}
	y = 0.0
	for edge in outgoing:
		var src_id := String(edge.get("from", ""))
		var src_port := String(edge.get("from_port", ""))
		var key := "%s|%s" % [src_id, src_port]
		if seen.has(key):
			continue
		seen[key] = true
		var kind2 := _boundary_type(_port_type_of(src_id, src_port, true))
		var made2 := g.doc_add_node(sub, "graph.output", "",
			Vector2(far.x + 340.0, y), {"name": _port_label(src_id, src_port), "type": kind2})
		var port2 := String(made2.get("id", ""))
		if port2.is_empty():
			continue
		g.doc_connect(sub, src_id, src_port, port2, "value")
		out_links.append({"boundary": port2, "target": String(edge.get("to", "")),
			"port": String(edge.get("to_port", ""))})
		y += 150.0

	# 子图自己的「主输出」：优先用对外的图像出口，否则挑一个图像节点。
	var image_source := ""
	for edge in outgoing:
		if _boundary_type(_port_type_of(String(edge.get("from", "")),
				String(edge.get("from_port", "")), true)) == "image":
			image_source = String(edge.get("from", ""))
			break
	if image_source.is_empty():
		image_source = _pick_image_source(ids)
	if image_source.is_empty() and out_links.is_empty():
		_status("选区里没有图像输出，也没有对外连线，无法作为子图")
		return
	g.doc_set_output(sub, image_source)

	var path := _pack_path()
	var err := g.doc_save(sub, path)
	if err != OK:
		_status("子图写入失败：%s" % error_string(err))
		return

	# 当前图：换成子图节点，跨边界的连线改接到子图节点声明的端口上。
	var centroid := Vector2.ZERO
	for id in ids:
		centroid += _vec2_of(g.doc_node(doc, id).get("pos", [0, 0]))
	centroid /= float(ids.size())
	store.begin_batch()
	var created := store.add_node("graph.subgraph", "", centroid,
		{"path": path, "fit": "contain"})
	var new_id := String(created.get("id", ""))
	for link in in_links:
		store.connect_ports(String(link["source"]), String(link["port"]), new_id,
			String(link["boundary"]))
	for link2 in out_links:
		store.connect_ports(new_id, String(link2["boundary"]), String(link2["target"]),
			String(link2["port"]))
	store.remove_nodes(ids)
	store.commit_batch()
	_collapsed_nodes.erase(new_id)
	_select_many.call_deferred([new_id])
	_status("已打包 %d 个节点（%d 个输入口 / %d 个输出口）→ %s（Ctrl+Z 可撤销）"
		% [ids.size(), in_links.size(), out_links.size(), path.get_file()])


## 穿过子图边界的值类型：exec / 图层这类没法用一个值表达，返回空串表示不支持。
func _boundary_type(port_type: StringName) -> String:
	match String(port_type):
		"image", "image_object":
			return "image"
		"number", "int":
			return "number"
		"vec2", "color", "bool", "string":
			return String(port_type)
	return ""


## 边界端口的显示名：「源节点 · 源端口」比孤零零一个 image 好认。
func _port_label(node_id: String, port_id: String) -> String:
	var g := FxGraphFacade.access()
	var data := g.doc_node(doc, node_id)
	var def := g.catalog_def(String(data.get("type", "")))
	var label := String(def.label) if def != null else node_id
	if label.is_empty():
		label = node_id
	return "%s · %s" % [label, port_id]



func _unpack_selection() -> void:
	if store == null:
		return
	var ids := _selected_ids()
	if ids.is_empty():
		_status("先选中一个子图节点")
		return
	var id := ids[0]
	var nd := FxGraphFacade.access().doc_node(doc, id)
	if String(nd.get("type", "")) != "graph.subgraph":
		_status("选中的不是子图节点")
		return
	var params: Dictionary = nd.get("params", {})
	var path := String(params.get("path", "")).strip_edges()
	var g := FxGraphFacade.access()
	var sub := g.doc_load(path)
	if sub.is_empty():
		_status("子图文件读不到或为空：%s" % path)
		return

	# 父图里连进 / 连出子图节点的线：解包时用它们替换边界节点，连线不会丢。
	var into: Dictionary = {}
	for item in doc.get("edges", []):
		var pe: Dictionary = item
		if String(pe.get("to", "")) == id:
			into[String(pe.get("to_port", ""))] = pe

	var sub_output := g.doc_output_id(sub)
	var base := _vec2_of(nd.get("pos", [0, 0]))
	var mapping: Dictionary = {}
	var boundary_in: Dictionary = {}
	var boundary_out: Dictionary = {}
	store.begin_batch()
	for item in sub.get("nodes", []):
		var sub_node: Dictionary = item
		var type_id := String(sub_node.get("type", ""))
		var sid := String(sub_node.get("id", ""))
		if type_id == "graph.input":
			var feeder: Dictionary = into.get(sid, {})
			if not feeder.is_empty():
				boundary_in[sid] = {"from": String(feeder.get("from", "")),
					"from_port": String(feeder.get("from_port", ""))}
			continue
		if type_id == "graph.output":
			boundary_out[sid] = true
			continue
		var sp: Variant = sub_node.get("params", {})
		var made := store.add_node(type_id, "",
			base + _vec2_of(sub_node.get("pos", [0, 0])),
			(sp as Dictionary).duplicate(true) if sp is Dictionary else {})
		var new_sub_id := String(made.get("id", ""))
		if new_sub_id.is_empty():
			continue
		mapping[sid] = new_sub_id
	for item2 in sub.get("edges", []):
		var e: Dictionary = item2
		var from_raw := String(e.get("from", ""))
		var to_raw := String(e.get("to", ""))
		if boundary_out.has(to_raw):
			# 进「子图输出」的线：记下来，等会儿接到父图原来的下游上。
			boundary_out[to_raw] = {"from": from_raw, "from_port": String(e.get("from_port", ""))}
			continue
		var from_port := String(e.get("from_port", ""))
		var to_port := String(e.get("to_port", ""))
		if boundary_in.has(from_raw):
			var src: Dictionary = boundary_in[from_raw]
			var target := String(mapping.get(to_raw, ""))
			if not target.is_empty():
				store.connect_ports(String(src["from"]), String(src["from_port"]), target, to_port)
			continue
		var from_id := String(mapping.get(from_raw, ""))
		var to_id := String(mapping.get(to_raw, ""))
		if from_id.is_empty() or to_id.is_empty():
			continue
		store.connect_ports(from_id, from_port, to_id, to_port)
	# 子图节点的每个出口，接回父图里原来的下游。
	for item3 in doc.get("edges", []):
		var out_edge: Dictionary = item3
		if String(out_edge.get("from", "")) != id:
			continue
		var out_port := String(out_edge.get("from_port", ""))
		var origin_id := ""
		var origin_port := ""
		if out_port == "image":
			origin_id = String(mapping.get(sub_output, ""))
			origin_port = "image"
		elif boundary_out.has(out_port):
			var up: Variant = boundary_out[out_port]
			if up is Dictionary:
				origin_id = String(mapping.get(String((up as Dictionary).get("from", "")), ""))
				origin_port = String((up as Dictionary).get("from_port", ""))
		if origin_id.is_empty():
			continue
		store.connect_ports(origin_id, origin_port, String(out_edge.get("to", "")),
			String(out_edge.get("to_port", "")))
	store.remove_nodes([id])
	store.commit_batch()
	var expanded: Array = mapping.values()
	if not expanded.is_empty():
		_select_many.call_deferred(expanded)
	_status("已展开子图：%d 个节点" % expanded.size())


## 没有对外连线时，挑一个图像输出节点当子图输出（优先接不到下游的那个）。
func _pick_image_source(ids: Array[String]) -> String:
	var g := FxGraphFacade.access()
	for id in ids:
		var nd := g.doc_node(doc, id)
		var def := g.catalog_def(String(nd.get("type", "")))
		if def == null:
			continue
		for p in def.outputs:
			if String((p as Dictionary).get("type", "")) == "image":
				return id
	return ""


## 打包文件路径：user://graphs/<名字>_pack_<n>.fxgraph，重复就加序号。
func _pack_path() -> String:
	if not DirAccess.dir_exists_absolute(PACK_DIR):
		DirAccess.make_dir_recursive_absolute(PACK_DIR)
	var stem := String(FxGraphFacade.access().doc_meta(doc, "name", "graph")).strip_edges()
	stem = stem.replace("/", "_").replace("\\", "_")
	if stem.is_empty():
		stem = "graph"
	var index := 1
	var path := "%s/%s_pack_%d.fxgraph" % [PACK_DIR, stem, index]
	while FileAccess.file_exists(path):
		index += 1
		path = "%s/%s_pack_%d.fxgraph" % [PACK_DIR, stem, index]
	return path


static func cmd_pack(ctx: Dictionary) -> void:
	var panel: FxGraphEditor = ctx["shell"].panel("editor.graph")
	if panel != null:
		panel.call("_pack_selection")


static func cmd_unpack(ctx: Dictionary) -> void:
	var panel: FxGraphEditor = ctx["shell"].panel("editor.graph")
	if panel != null:
		panel.call("_unpack_selection")
