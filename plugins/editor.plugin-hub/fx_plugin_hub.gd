class_name FxPluginHub
extends Control
## 插件中心（左右分栏）。
##
##   左：插件列表（搜索 / 状态点 / 选中态），只读 FxRegistry.plugin_infos；
##   右：选中插件的信息、依赖、贡献统计、插件功能、插件自己的设置。
##
## 左右两侧可以一键互换（标题栏的 ⇄），选择记在设置 `ui.hub_list_right` 里：
## 有人习惯「列表在左、详情在右」（默认），有人喜欢反过来，不必改代码。
##
## 全部内容来自声明式账本：没有一处 `if id == "xxx"`。所谓「插件功能」就是该插件
## 注册的 commands()，例如皮肤插件会注册「应用此皮肤」，这里直接渲染成按钮；
## 设置表单同样由 settings() 声明生成（与设置中心共用 FxSettingWidgets）。
## 因此任何第三方插件装进来就自动获得「列表项 + 详情 + 功能 + 设置」。
##
## 图标支持三种形态（见 FxVisualIcon）：字形 / 纹理 / 精灵表动图，读不出来就回退字形。

const LIST_RIGHT_SETTING := "ui.hub_list_right"

var shell: Object = null
var _list: VBoxContainer
var _detail: VBoxContainer
var _search: LineEdit
var _summary: Label
var _query: String = ""
var _selected: String = ""
var _rows: Dictionary = {}
var _columns: HSplitContainer
var _side: VBoxContainer
var _back: Button
var _scroll: ScrollContainer
var _narrow: bool = false
var _show_detail: bool = false
var _flip: Button
## 图标动图：id -> {atlas, image, grid, clock}
var _icon_anim: Array[Dictionary] = []

## 贡献种类 → 可读名（键是 FxRegistry 的 kind，值走多语言）。
const KIND_LABELS := {
	"node_file": "节点定义", "op": "算子", "time_op": "时间依赖算子",
	"param_kind": "参数控件", "exporter": "导出器", "panel": "面板",
	"window": "窗口与弹窗", "command": "命令项", "menu": "菜单", "menu_item": "菜单项",
	"toolbar": "工具栏项", "service": "服务", "skin": "皮肤与主题",
	"dock_factory": "停靠样式", "setting": "设置项", "capability": "能力",
	"quality_policy": "质量策略", "panel_feature": "面板功能", "locale": "语言包",
	"graph_access": "图能力", "render_backend": "渲染后端",
	"node_picker": "节点选择器", "error": "错误",
}


func setup(p_shell: Object) -> void:
	shell = p_shell
	name = "FxPluginHub"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	root.add_child(head)
	_back = FxUiKit.flat_button("←", FxI18n.text("返回插件列表"), 13)
	_back.custom_minimum_size = Vector2(24, 24)
	_back.visible = false
	_back.pressed.connect(func() -> void:
		_show_detail = false
		_apply_layout_mode()
	)
	head.add_child(_back)
	var title := FxUiKit.strong(FxI18n.text("插件中心"), 15)
	head.add_child(title)
	_summary = FxUiKit.label("", 10, FxUiKit.MUTED)
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(_summary)
	var settings_button := FxUiKit.button(FxI18n.text("设置中心"), 10, 24)
	settings_button.pressed.connect(_open_settings)
	head.add_child(settings_button)
	_flip = FxUiKit.flat_button("⇄", FxI18n.text("列表与详情左右互换"), 13)
	_flip.custom_minimum_size = Vector2(24, 24)
	_flip.pressed.connect(_toggle_side)
	head.add_child(_flip)

	# 左列表 / 右详情（或反过来，由设置决定）：拖动分隔条即可改变比例，
	# 窄窗口下列表仍保留最小宽度。
	var columns := HSplitContainer.new()
	_columns = columns
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 6)
	root.add_child(columns)

	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 8)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.custom_minimum_size.x = 260

	var side := VBoxContainer.new()
	_side = side
	side.add_theme_constant_override("separation", 6)
	# 侧栏固定一个舒适宽度，剩下的都给详情；用户可以再拖分隔条调整。
	side.custom_minimum_size.x = 300
	side.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_apply_side_order()

	_search = LineEdit.new()
	_search.placeholder_text = FxI18n.text("搜索插件（名称 / id / 说明 / 依赖键）")
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(text: String) -> void:
		_query = text.to_lower()
		_rebuild_list()
	)
	side.add_child(_search)

	var list_head := HBoxContainer.new()
	list_head.add_theme_constant_override("separation", 6)
	side.add_child(list_head)
	list_head.add_child(FxUiKit.label(FxI18n.text("已安装插件"), 10, FxUiKit.MUTED))
	list_head.add_child(FxUiKit.spacer(0, true))

	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_list)
	resized.connect(_on_resized)
	rebuild()
	_apply_layout_mode()


func _open_settings() -> void:
	if shell != null and shell.has_method("run_command"):
		shell.call("run_command", "settings.open")


## 列表是否放右边。默认 false：列表在左、详情在右（插件浏览器的常规排布）。
func _list_on_right() -> bool:
	return bool(FxSettings.typed_value(LIST_RIGHT_SETTING, false))


func _apply_side_order() -> void:
	if _columns == null or _detail == null or _side == null:
		return
	for child in [_detail, _side]:
		if child.get_parent() == _columns:
			_columns.remove_child(child)
	if _list_on_right():
		_columns.add_child(_detail)
		_columns.add_child(_side)
	else:
		_columns.add_child(_side)
		_columns.add_child(_detail)


func _toggle_side() -> void:
	FxSettings.set_value(LIST_RIGHT_SETTING, not _list_on_right())
	_apply_side_order()
	_apply_layout_mode()
	_rebuild_detail()


## 图标动图：每帧推进一次精灵表区域（只有真的动图才登记进来）。
func _process(delta: float) -> void:
	if _icon_anim.is_empty() or not visible:
		return
	for entry in _icon_anim:
		var atlas: AtlasTexture = entry.get("atlas")
		if atlas == null or not is_instance_valid(atlas):
			continue
		var grid: Dictionary = entry.get("grid", {})
		var clock := float(entry.get("clock", 0.0)) + delta
		entry["clock"] = clock
		atlas.region = FxVisualIcon.frame_rect(int(clock * float(grid.get("fps", 8.0))),
			grid, entry.get("size", Vector2i.ONE))


func rebuild() -> void:
	_rebuild_list()
	if _selected.is_empty() or not FxPluginHost.is_known(_selected):
		_selected = ""
	_rebuild_detail()


func select(plugin_id: String) -> void:
	_selected = plugin_id
	for pid in _rows.keys():
		_style_row(String(pid), String(pid) == _selected)
	# 窄面板里「点一项」就等于「进入详情」，返回按钮在标题栏左侧。
	_show_detail = true
	_rebuild_detail()
	_apply_layout_mode()
	_scroll_to_selected.call_deferred()


## 自适应：宽的时候左右并排（左详情 / 右列表）；
## 窄到放不下两栏时退化成单栏，选中插件进入详情，← 回到列表。
func _on_resized() -> void:
	var want := size.x < 430.0
	if want == _narrow:
		return
	_narrow = want
	_apply_layout_mode()


func _apply_layout_mode() -> void:
	if _columns == null or _side == null:
		return
	_back.visible = _narrow and _show_detail
	if _summary != null:
		_summary.visible = not _narrow
	# HSplitContainer 里只剩一个可见子节点时会自动占满整行，天然适配窄面板。
	if _narrow:
		_detail.visible = _show_detail
		_side.visible = not _show_detail
	else:
		_detail.visible = true
		_side.visible = true


func _infos() -> Array[Dictionary]:
	var infos: Array[Dictionary] = FxRegistry.plugin_infos.duplicate(true)
	infos.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("id", "")) < String(b.get("id", "")))
	return infos


func _matches(info: Dictionary) -> bool:
	if _query.is_empty():
		return true
	var haystack := "%s %s %s %s %s" % [
		String(info.get("id", "")), String(info.get("name", "")),
		String(info.get("description", "")), str(info.get("inject", [])),
		str(info.get("provide", [])),
	]
	return haystack.to_lower().contains(_query)


func _rebuild_list() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	_icon_anim.clear()
	var infos := _infos()
	var shown := 0
	for info in infos:
		if not _matches(info):
			continue
		var pid := String(info.get("id", ""))
		var row := _row(info)
		_list.add_child(row)
		_rows[pid] = row
		shown += 1
		if _selected.is_empty():
			_selected = pid
	var diag := FxPluginHost.diagnostics()
	_summary.text = (FxI18n.text("共 %d / %d · 激活 %d · 依赖环 %d · 缺失 %d") % [
		shown, infos.size(), (diag.get("active", []) as Array).size(),
		(diag.get("cycles", []) as Array).size(), (diag.get("missing", []) as Array).size(),
	])
	_scroll_to_selected.call_deferred()


func _scroll_to_selected() -> void:
	if _scroll == null or _selected.is_empty():
		return
	var row: Variant = _rows.get(_selected)
	if row is Control and is_instance_valid(row):
		_scroll.ensure_control_visible(row)


## 列表项：状态点 + 名称 + id，整块可点。不用 Button 是为了保留两行排版。
func _row(info: Dictionary) -> Control:
	var pid := String(info.get("id", ""))
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.tooltip_text = "%s · v%s" % [pid, String(info.get("version", "1.0"))]
	card.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				select(pid)
	)
	card.mouse_entered.connect(func() -> void:
		if pid != _selected:
			_style_row(pid, false, card, true)
	)
	card.mouse_exited.connect(func() -> void:
		if pid != _selected:
			_style_row(pid, false, card, false)
	)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	card.add_child(row)
	var active := FxPluginHost.is_active(pid)
	var enabled := bool(info.get("enabled", true))
	var dot := FxUiKit.label("●", 9, FxUiKit.OK if active else (FxUiKit.ACCENT if enabled else FxUiKit.MUTED))
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dot)
	var texts := VBoxContainer.new()
	texts.add_theme_constant_override("separation", 0)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(texts)
	var name_label := FxUiKit.label(String(info.get("name", pid)), 11,
		FxUiKit.TEXT_STRONG if active else FxUiKit.MUTED)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(name_label)
	var id_label := FxUiKit.label(pid, 9, FxUiKit.MUTED)
	id_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(id_label)
	_style_row(pid, pid == _selected, card)
	return card


## 列表项是「平铺行」而不是卡片：选中才有强调底色，悬停只有淡底。
func _style_row(pid: String, selected: bool, card: Control = null, hover: bool = false) -> void:
	var target: Control = card if card != null else _rows.get(pid)
	if target == null or not is_instance_valid(target):
		return
	var panel := target as PanelContainer
	if panel == null:
		return
	var bg := Color(0, 0, 0, 0)
	var border := Color(0, 0, 0, 0)
	if selected:
		bg = Color(FxUiKit.ACCENT, 0.16)
		border = Color(FxUiKit.ACCENT, 0.75)
	elif hover:
		bg = FxUiKit.PANEL_ALT
	panel.add_theme_stylebox_override("panel", FxUiKit.panel_style(bg, border, 3))


func _rebuild_detail() -> void:
	if _detail == null:
		return
	for child in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()
	_icon_anim.clear()
	var info := _info(_selected)
	if info.is_empty():
		var empty := FxUiKit.wrapped(FxI18n.text("还没有选中插件。从列表里挑一个，看看它提供了什么。"),
			11, FxUiKit.MUTED)
		_detail.add_child(empty)
		return
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	box.add_child(_header_card(info))
	var desc := String(info.get("description", ""))
	if not desc.is_empty():
		box.add_child(_section(FxI18n.text("说明")))
		box.add_child(FxUiKit.wrapped(FxI18n.text(desc), 11, FxUiKit.TEXT))
	box.add_child(_section(FxI18n.text("依赖")))
	box.add_child(_deps_box(info))
	box.add_child(_section(FxI18n.text("贡献")))
	box.add_child(_contrib_box(info))
	var features := _features_box(info)
	if features != null:
		box.add_child(_section(FxI18n.text("插件功能")))
		box.add_child(features)
	var own: Array[Dictionary] = FxRegistry.settings_of(_selected)
	if not own.is_empty():
		box.add_child(_section(FxI18n.text("插件设置（%d）") % own.size()))
		var form := VBoxContainer.new()
		form.add_theme_constant_override("separation", 6)
		box.add_child(form)
		for entry in own:
			form.add_child(FxSettingWidgets.row(entry, FxSettingsApi.write))
	var tail := Control.new()
	tail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(tail)


func _section(title: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(FxUiKit.label(title, 10, FxUiKit.ACCENT))
	var line := ColorRect.new()
	line.color = FxUiKit.BORDER_SOFT
	line.custom_minimum_size = Vector2(0, 1)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(line)
	return row


func _header_card(info: Dictionary) -> Control:
	var pid := String(info.get("id", ""))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(FxUiKit.PANEL_ALT, FxUiKit.BORDER_SOFT, 7))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	row.add_child(_icon(info, 52))
	var texts := VBoxContainer.new()
	texts.add_theme_constant_override("separation", 2)
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(texts)
	var name_label := FxUiKit.strong(String(info.get("name", pid)), 16)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texts.add_child(name_label)
	var meta := "v%s · %s" % [String(info.get("version", "1.0")), pid]
	if not String(info.get("author", "")).is_empty():
		meta += " · " + String(info.get("author", ""))
	texts.add_child(FxUiKit.wrapped(meta, 10, FxUiKit.MUTED))
	var active := FxPluginHost.is_active(pid)
	var enabled := bool(info.get("enabled", true))
	var state := "ACTIVE" if active else (FxI18n.text("等待依赖") if enabled else FxI18n.text("已停用"))
	var state_color := FxUiKit.OK if active else (FxUiKit.ACCENT if enabled else FxUiKit.MUTED)
	texts.add_child(FxUiKit.label(state, 9, state_color))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	box.add_child(actions)
	var toggle := CheckButton.new()
	toggle.text = FxI18n.text("启用")
	toggle.set_pressed_no_signal(enabled)
	toggle.tooltip_text = FxI18n.text("停用后该插件的全部贡献会被逆序撤回")
	toggle.toggled.connect(func(pressed: bool) -> void:
		FxPluginHost.set_enabled(pid, pressed)
		rebuild.call_deferred()
	)
	actions.add_child(toggle)
	actions.add_child(FxUiKit.spacer(0, true))
	if not FxRegistry.settings_of(pid).is_empty():
		var open_settings := FxUiKit.button(FxI18n.text("打开设置中心"), 10, 24)
		open_settings.pressed.connect(_open_settings)
		actions.add_child(open_settings)
	return card


func _icon(info: Dictionary, size_px: int) -> Control:
	var holder := PanelContainer.new()
	holder.custom_minimum_size = Vector2(size_px, size_px)
	holder.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var tint := Color.from_string(String(info.get("color", "#4cc2ff")), FxUiKit.ACCENT)
	holder.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(Color(tint, 0.18), Color(tint, 0.55), 8))
	var base_dir := String(info.get("dir", ""))
	# 三种图标形态共用一套解析：`icon` 是纹理路径就用纹理，否则当字形。
	var raw := String(info.get("icon", ""))
	var file_hint := String(info.get("icon_file", ""))
	var candidate := ""
	if not file_hint.is_empty():
		candidate = file_hint
	elif FxVisualIcon.is_image_path(raw):
		candidate = raw
	if not candidate.is_empty():
		var full := FxVisualIcon.resolve(base_dir, candidate)
		var image := FxVisualIcon.image_of(full)
		if image != null:
			var rect := TextureRect.new()
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			var grid := FxVisualIcon.frames(info.get("icon_anim", {}), image.get_size())
			if bool(grid.get("animated", false)):
				var atlas := AtlasTexture.new()
				atlas.atlas = ImageTexture.create_from_image(image)
				atlas.region = FxVisualIcon.frame_rect(0, grid, image.get_size())
				rect.texture = atlas
				_icon_anim.append({"atlas": atlas, "grid": grid, "clock": 0.0,
					"size": image.get_size()})
			else:
				rect.texture = ImageTexture.create_from_image(image)
			holder.add_child(rect)
			return holder
	var glyph := raw
	if glyph.is_empty() or FxVisualIcon.is_image_path(glyph):
		glyph = String(info.get("id", "?")).substr(0, 1).to_upper()
	var label := FxUiKit.strong(glyph, int(size_px * 0.48))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	holder.add_child(label)
	return holder


func _deps_box(info: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	for spec in [["inject", FxI18n.text("接受"), FxUiKit.ACCENT],
			["provide", FxI18n.text("提供"), FxUiKit.OK]]:
		var keys: Array = info.get(String(spec[0]), [])
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 5)
		row.add_theme_constant_override("v_separation", 5)
		var tag := FxUiKit.label(String(spec[1]), 10, FxUiKit.MUTED)
		tag.custom_minimum_size = Vector2(34, 0)
		row.add_child(tag)
		if keys.is_empty():
			row.add_child(FxUiKit.label("—", 10, FxUiKit.MUTED))
		for key in keys:
			row.add_child(_chip(String(key), spec[2]))
		box.add_child(row)
	return box


func _contrib_box(info: Dictionary) -> Control:
	var pid := String(info.get("id", ""))
	var counts := FxRegistry.contributions_by_kind(pid)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 5)
	flow.add_theme_constant_override("v_separation", 5)
	if counts.is_empty():
		flow.add_child(FxUiKit.label("—", 10, FxUiKit.MUTED))
	for kind in counts.keys():
		var label := "%s %d" % [
			FxI18n.text(String(KIND_LABELS.get(String(kind), kind))), int(counts[kind])]
		flow.add_child(_chip(label, FxUiKit.MUTED))
	return flow


## 「插件功能」：该插件注册的命令 + 它贡献的皮肤。没有就返回 null，不占版面。
func _features_box(info: Dictionary) -> Control:
	var pid := String(info.get("id", ""))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var any := false
	var skins := FxRegistry.skins_of(pid)
	if not skins.is_empty():
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 6)
		row.add_theme_constant_override("v_separation", 6)
		var current := ""
		if shell != null and shell.has_method("current_skin_id"):
			current = String(shell.call("current_skin_id"))
		for entry in skins:
			var skin_id := String(entry.get("id", ""))
			if skin_id.is_empty():
				continue
			var button := FxUiKit.button(
				(FxI18n.text("当前皮肤") if skin_id == current else FxI18n.text("应用皮肤"))
					+ " · " + FxI18n.text(String(entry.get("name", skin_id))), 10, 26)
			button.disabled = skin_id == current
			button.pressed.connect(func() -> void: _apply_skin(skin_id))
			row.add_child(button)
			any = true
		if any:
			box.add_child(row)
	var commands := FxRegistry.commands_of(pid)
	if not commands.is_empty():
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		for entry2 in commands:
			var label := FxI18n.text(String(entry2.get("label", entry2.get("id", ""))))
			var shortcut := String(entry2.get("shortcut", ""))
			var button2 := FxUiKit.button(label if shortcut.is_empty() else "%s   %s" % [label, shortcut],
				10, 26)
			var command_id := String(entry2.get("id", ""))
			button2.tooltip_text = command_id
			button2.pressed.connect(func() -> void: _run(command_id))
			flow.add_child(button2)
			any = true
		box.add_child(flow)
	if not any:
		box.add_child(FxUiKit.wrapped(FxI18n.text("这个插件没有注册可执行功能。"), 10, FxUiKit.MUTED))
	return box


func _apply_skin(skin_id: String) -> void:
	if shell != null and shell.has_method("apply_skin"):
		shell.call("apply_skin", skin_id)
	_rebuild_detail()


func _run(command_id: String) -> void:
	if shell != null and shell.has_method("run_command"):
		shell.call("run_command", command_id)


func _info(plugin_id: String) -> Dictionary:
	for item in FxRegistry.plugin_infos:
		if String((item as Dictionary).get("id", "")) == plugin_id:
			return item
	return {}


func _chip(text: String, color: Color) -> Control:
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(Color(color, 0.12), Color(color, 0.38), 4))
	var label := FxUiKit.label(text, 9, color)
	chip.add_child(label)
	return chip
