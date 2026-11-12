class_name FxProjectSaveDialog
extends ConfirmationDialog
## 保存 / 另存为面板。
##
## 两条使用路径共用这一个面板：
##   · 工程未保存过 —— Ctrl+S 与 Ctrl+Shift+S 都弹它，标题「保存工程」；
##   · 工程已保存   —— Ctrl+Shift+S 弹它，标题「另存为」，默认给一个副本文件名。
##
## 界面分三段：保存位置（表单）、打包内容（清单）、进度与状态。
##
## Godot 4.7 的 AcceptDialog 已经没有 get_vbox()：内容直接挂在窗口下，按钮栏由
## 引擎画在底部且不出现在 get_children() 里。所以这里给内容套一层带裁剪的容器，
## 底边留出按钮栏高度 —— 否则列表会一路长到窗口底部，把确定/取消压住（上一版
## 最要命的问题就是这个）。
##
## 真正写盘交给 FxProjectArchive；本类只负责「用户勾了什么」和「进度怎么显示」。

var doc: Dictionary = {}
var default_path: String = ""
var on_save: Callable = Callable()
## "save" = 首次保存；"copy" = 另存为（已保存过，默认给副本文件名）。
var save_mode: String = "save"
## 当前工程的路径（另存为时用来提示「不会覆盖」）。
var current_path: String = ""

var _path_edit: LineEdit
var _format: OptionButton
var _pack_assets: CheckBox
var _pack_plugins: CheckBox
var _list: VBoxContainer
var _rows: Array[Dictionary] = []
var _body: Control
var _progress: ProgressBar
var _progress_label: Label
var _hint: Label
var _summary_assets: Label
var _summary_plugins: Label
var _busy: bool = false
var _assets: Array = []
var _plugins: Array = []

const LABEL_W := 56
## 内容区底部给引擎画的按钮栏留的高度（按钮 ~31px + 上下内边距）。
const BAR_RESERVE := 52


static func create(p_doc: Dictionary, path: String, callback: Callable,
		options: Dictionary = {}) -> FxProjectSaveDialog:
	var dialog := FxProjectSaveDialog.new()
	# 保存是异步的（每写一个文件让出一帧），确定键不能顺手销毁面板。
	dialog.set_meta("fx_keep_open", true)
	FxUiKit.style_window(dialog)
	dialog.doc = p_doc
	dialog.default_path = path
	dialog.on_save = callback
	dialog.save_mode = String(options.get("mode", "save"))
	dialog.current_path = String(options.get("current_path", ""))
	dialog.title = "另存为" if dialog.save_mode == "copy" else "保存工程"
	dialog.min_size = Vector2i(640, 520)
	dialog.ok_button_text = "另存为" if dialog.save_mode == "copy" else "保存"
	dialog.cancel_button_text = "取消"
	dialog.confirmed.connect(dialog._on_confirm)
	dialog._build()
	return dialog


func _ready() -> void:
	# AcceptDialog 在 _ready 里会把 wrap_controls 打开（于是窗口被内容最小尺寸撑成
	# 一个又窄又高的条），这里在它之后把尺寸固定成面板该有的样子。
	wrap_controls = false
	min_size = Vector2i(680, 500)
	size = Vector2i(700, 530)



func _build() -> void:
	# 按钮栏是引擎内部画的（不接受 wrap_controls 自动计算），窗口尺寸自己定，
	# 内容区底边留 BAR_RESERVE，避免长清单压住按钮。
	# AcceptDialog 会把**直接子控件**摆成「窗口减内边距」那一块，而且它不认识自己
	# 底下还画着一条按钮栏。所以先放一个普通 Control 接住这个矩形，内容再按锚点
	# 铺在它里面、底边留出按钮栏高度 —— 这样窗口怎么缩放都不会压住按钮。
	var clip := Control.new()
	clip.name = "Body"
	clip.clip_contents = true
	add_child(clip)
	_body = clip

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 14
	box.offset_top = 12
	box.offset_right = -14
	box.offset_bottom = -BAR_RESERVE
	clip.add_child(box)
	box.add_theme_constant_override("separation", 10)

	# ---- 保存位置 ----
	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 10)
	form.add_theme_constant_override("v_separation", 8)
	box.add_child(form)

	form.add_child(_label("格式"))
	_format = OptionButton.new()
	# 说明写进选项文字里，省掉一行「格式说明」占地方。
	_format.add_item("工程包 .fxproj     ZIP 壳，可把素材与插件一起带走")
	_format.add_item("纯文本 .fxgraph   只存图，不附带任何文件")
	_format.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_format.item_selected.connect(_on_format_changed)
	form.add_child(_format)

	form.add_child(_label("保存到"))
	var path_row := HBoxContainer.new()
	path_row.add_theme_constant_override("separation", 6)
	path_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(path_row)
	_path_edit = LineEdit.new()
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.text = default_path
	_path_edit.placeholder_text = "选择保存位置与文件名"
	_path_edit.tooltip_text = default_path
	path_row.add_child(_path_edit)
	var browse := FxUiKit.button("浏览…", 12, 24)
	browse.pressed.connect(_on_browse)
	path_row.add_child(browse)

	_hint = FxUiKit.wrapped(_hint_text(), 11, FxUiKit.MUTED)
	# autowrap 的 Label 在宽度为 0 时会按「一行一个字」算最小高度（能到上千像素），
	# 从而把窗口的最小尺寸顶成一个瘦高的条。给它一个下限宽度即可。
	_hint.custom_minimum_size = Vector2(460, 0)
	box.add_child(_hint)

	# ---- 打包内容 ----
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)
	var section := FxUiKit.strong("打包内容", 12)
	head.add_child(section)
	_summary_assets = FxUiKit.label("", 11, FxUiKit.MUTED)
	head.add_child(_summary_assets)
	_summary_plugins = FxUiKit.label("", 11, FxUiKit.MUTED)
	head.add_child(_summary_plugins)
	head.add_child(FxUiKit.spacer(0, true))

	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 18)
	box.add_child(toggles)
	_pack_assets = CheckBox.new()
	_pack_assets.text = "素材"
	_pack_assets.button_pressed = true
	_pack_assets.tooltip_text = "把工程用到的外部图片 / 字体一起写进工程包"
	_pack_assets.toggled.connect(func(_on: bool) -> void: _refresh_rows())
	_flat_check(_pack_assets)
	toggles.add_child(_pack_assets)
	_pack_plugins = CheckBox.new()
	_pack_plugins.text = "插件"
	_pack_plugins.button_pressed = false
	_pack_plugins.tooltip_text = "把工程用到、且本机已安装的插件目录一起写进工程包"
	_pack_plugins.toggled.connect(func(_on: bool) -> void: _refresh_rows())
	_flat_check(_pack_plugins)
	toggles.add_child(_pack_plugins)
	toggles.add_child(FxUiKit.spacer(0, true))
	var legend := FxUiKit.label("取消勾选 = 不打包", 11, FxUiKit.MUTED)
	legend.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggles.add_child(legend)

	# 清单：带边框的滚动区，行是「勾选 + 名称 + 用途」，不再是整条通栏的复选框。
	var frame := PanelContainer.new()
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_theme_stylebox_override("panel",
		FxUiKit.solid_panel_style(FxUiKit.BG, FxUiKit.BORDER_SOFT, 3))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	frame.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 168)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 1)
	scroll.add_child(_list)
	box.add_child(frame)
	_rebuild_list()

	# ---- 进度与状态 ----
	_progress = ProgressBar.new()
	_progress.max_value = 1.0
	_progress.value = 0.0
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0, 6)
	_progress.visible = false
	box.add_child(_progress)
	_progress_label = FxUiKit.label("", 11, FxUiKit.MUTED)
	_progress_label.visible = false
	box.add_child(_progress_label)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(LABEL_W, 0)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG)
	return label


func _hint_text() -> String:
	if save_mode == "copy" and not current_path.is_empty():
		return "会另存为新文件，当前工程（%s）保持不动。" % current_path.get_file()
	return "纯文本只保存图本身；加载时若缺素材 / 插件会列出清单，可手动修复资源路径。"


# ================= 清单 =================

func _rebuild_list() -> void:
	_assets.clear()
	_plugins.clear()
	var deps := FxProjectArchive.scan_dependencies(doc)
	_assets = deps.get("assets", [])
	_plugins = deps.get("plugins", [])
	_rows.clear()
	_refresh_rows()


## 重排清单：按当前勾选状态决定每行是否可用，并更新计数。
func _refresh_rows() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	var as_zip := _format.selected == 0
	var pack_assets := as_zip and _pack_assets.button_pressed
	var pack_plugins := as_zip and _pack_plugins.button_pressed
	_pack_assets.disabled = not as_zip
	_pack_plugins.disabled = not as_zip
	_summary_assets.text = "· 素材 %d" % _assets.size()
	_summary_plugins.text = "· 插件 %d" % _plugins.size()

	if _assets.is_empty() and _plugins.is_empty():
		var empty := FxUiKit.label("当前工程没有外部依赖，直接保存即可。", 11, FxUiKit.MUTED)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.custom_minimum_size = Vector2(0, 48)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_list.add_child(empty)
		return

	if not _assets.is_empty():
		_list.add_child(_group("素材", _assets.size(), pack_assets))
		for item in _assets:
			var asset: Dictionary = item
			var ok := bool(asset.get("ok", false))
			var row := _row(String(asset.get("path", "")).get_file(),
				String(asset.get("path", "")),
				"%s · %s" % [String(asset.get("node", "")), String(asset.get("param", ""))],
				ok, pack_assets, ok)
			_rows.append({"check": row["check"], "id": String(asset.get("path", "")),
				"kind": "asset"})
	if not _plugins.is_empty():
		_list.add_child(_group("插件", _plugins.size(), pack_plugins))
		for item2 in _plugins:
			var plugin: Dictionary = item2
			var installed := bool(plugin.get("installed", false))
			var id := String(plugin.get("id", ""))
			var row2 := _row(id, id,
				"已安装" if installed else "未安装（无法打包）",
				installed, pack_plugins, installed)
			_rows.append({"check": row2["check"], "id": id, "kind": "plugin"})


func _group(title: String, count: int, active: bool) -> Control:
	var label := FxUiKit.label("%s  %d" % [title, count], 11,
		FxUiKit.TEXT if active else FxUiKit.MUTED)
	label.custom_minimum_size = Vector2(0, 22)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


## 扁平复选框：默认主题的 CheckBox 会把整条底色画出来（聚焦时还是一块实心蓝），
## 长清单里非常花。只留勾选框本身，文字照常。
func _flat_check(check: CheckBox) -> void:
	for style_name in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		check.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	# 不可用的行也别淡到看不见：统一成次要文字色。
	check.add_theme_color_override("font_disabled_color", FxUiKit.MUTED)


## 一行：复选框（扁平，不要通栏高亮）+ 名称 + 右侧用途说明。
func _row(name: String, full: String, detail: String, available: bool,
		active: bool, checked: bool) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_child(line)

	var check := CheckBox.new()
	check.text = name
	check.button_pressed = checked and active
	check.disabled = not (available and active)
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.tooltip_text = full
	check.add_theme_font_size_override("font_size", 11)
	_flat_check(check)
	line.add_child(check)

	var tail := FxUiKit.label(detail, 10, FxUiKit.MUTED if available else FxUiKit.DANGER)
	tail.size_flags_horizontal = Control.SIZE_SHRINK_END
	tail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	tail.custom_minimum_size = Vector2(120, 0)
	tail.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tail.tooltip_text = detail
	line.add_child(tail)
	return {"check": check, "line": line}


# ================= 交互 =================

func _on_format_changed(index: int) -> void:
	var text := _path_edit.text.strip_edges()
	var as_zip := index == 0
	if not text.is_empty():
		_path_edit.text = FxProjectArchive.normalize_path(
			FxProjectArchive.stem_of(text), as_zip)
	_refresh_rows()


func _on_browse() -> void:
	var dialog := FileDialog.new()
	FxUiKit.style_window(dialog)
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = FxUiKit.native_file_dialogs()
	dialog.add_filter("*.fxproj ; 工程包")
	dialog.add_filter("*.fxgraph ; 纯文本")
	dialog.current_file = _path_edit.text.get_file()
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		_path_edit.text = path
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.6])


func _on_confirm() -> void:
	if _busy or not on_save.is_valid():
		return
	var exclude: Array[String] = []
	for row in _rows:
		var box: CheckBox = row["check"]
		if not box.button_pressed:
			exclude.append(String(row["id"]))
	_set_busy(true)
	on_save.call({
		"path": _path_edit.text.strip_edges(),
		"as_zip": _format.selected == 0,
		"options": {
			"include_assets": _pack_assets.button_pressed,
			"include_plugins": _pack_plugins.button_pressed,
			"exclude": exclude,
		},
		"progress": _on_progress,
		"done": _on_done,
	})


func _set_busy(busy: bool) -> void:
	_busy = busy
	get_ok_button().disabled = busy
	get_cancel_button().disabled = busy
	_path_edit.editable = not busy
	_format.disabled = busy
	_progress.visible = busy
	_progress_label.visible = busy
	if busy:
		_progress.value = 0.0
		_progress_label.text = "准备写入…"
		_progress_label.add_theme_color_override("font_color", FxUiKit.MUTED)


## 写盘进度：done/total 是文件序号，label 是当前条目名。
func _on_progress(done: int, total: int, label: String) -> void:
	if _progress == null or not is_instance_valid(_progress):
		return
	_progress.max_value = float(maxi(total, 1))
	_progress.value = float(done)
	_progress_label.text = "正在写入 %d/%d · %s" % [done, maxi(total, 1), label]


func _on_done(ok: bool, message: String) -> void:
	if ok:
		# 成功：直接销毁，不经过 hide()（内嵌窗口隐藏会踩引擎的焦点索引缺陷）。
		FxUiKit.dismiss(self)
		return
	_set_busy(false)
	_progress.visible = false
	_progress_label.visible = true
	_progress_label.text = message
	_progress_label.add_theme_color_override("font_color", FxUiKit.DANGER)
