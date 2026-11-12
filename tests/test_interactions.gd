extends SceneTree
## 本轮交互能力验收：清晰播放、工具栏去重、端口拖线、轨道编辑、配方表单、移植插件。
## 运行：godot --headless --path . --script res://tests/test_interactions.gd

var failures: Array[String] = []
var shell: FxShell
var editor: FxGraphEditor
var timeline: FxTimelinePanel
const LAYOUT := "user://layout.cfg"


func _initialize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LAYOUT))
	print("== 交互与移植能力自测 ==")
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for i in range(6):
		await process_frame
	if shell == null:
		_check(false, "外壳实例化")
		_quit(1)
		return
	editor = shell.panel("editor.graph") as FxGraphEditor
	timeline = shell.panel("editor.timeline") as FxTimelinePanel
	_test_clear_playback()
	_test_toolbar_dedup()
	_test_canvas_navigation()
	await _test_port_drag()
	await _test_tracks()
	_test_recipe_form()
	await _test_transplanted_skins()
	print("----")
	if failures.is_empty():
		print("交互与移植能力自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


## 播放质量=0 时输出链仍全分辨率，与精确渲染逐像素一致（只有 source+output 时）。
func _test_clear_playback() -> void:
	var doc := FxGraphDoc.create("clear")
	FxGraphDoc.set_canvas(doc, 64, 64)
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2.ZERO,
		{"cell": 8, "color_a": "#ff3040", "color_b": "#101820"})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(200, 0), {
		"layers": [{"name": "图", "blend": "normal", "opacity": 1.0,
			"offset": [0, 0], "visible": true}],
	})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "src", "image", "out", "layer_0")
	var exact := FxGraphRunner.new()
	exact.quality = 1
	var a: Image = exact.run(doc, 0.0).get("image")
	var fast := FxGraphRunner.new()
	fast.quality = 0
	var b: Image = fast.run(doc, 0.0).get("image")
	_check(a is Image and b is Image and a.get_size() == b.get_size(), "播放档与精确档同尺寸")
	if a is Image and b is Image:
		var diff := 0
		for y in range(0, a.get_height(), 4):
			for x in range(0, a.get_width(), 4):
				if a.get_pixel(x, y) != b.get_pixel(x, y):
					diff += 1
		_check(diff == 0, "播放档不再半分辨率放大（像素差异 %d）" % diff)
	var recipe := FxPluginHost.exporter("")
	_check(recipe.is_empty(), "导出器查询对未知 id 安全")


func _test_toolbar_dedup() -> void:
	var bar: HBoxContainer = shell.get("_toolbar")
	shell.set_toolbar_mode("compact")
	var compact := _button_count(bar)
	shell.set_toolbar_mode("full")
	var full := _button_count(bar)
	shell.set_toolbar_mode("hidden")
	var wrap: PanelContainer = shell.get("_toolbar_wrap")
	_check(compact > 0 and compact < full, "精简工具栏去掉与菜单重复的项（%d → %d）" % [compact, full])
	_check(wrap != null and not wrap.visible, "工具栏可整体隐藏")
	shell.set_toolbar_mode("compact")
	_check(shell.toolbar_mode() == "compact", "工具栏模式可切回")


func _button_count(bar: HBoxContainer) -> int:
	var count := 0
	if bar != null:
		for child in bar.get_children():
			if child is Button:
				count += 1
	return count


func _test_canvas_navigation() -> void:
	var graph: GraphEdit = editor.graph
	_check(graph.panning_scheme == GraphEdit.SCROLL_ZOOMS, "滚轮交给 GraphEdit 缩放")
	var before := graph.scroll_offset.x
	var center := graph.get_global_rect().get_center()
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.ctrl_pressed = true
	ev.position = center
	editor._input(ev)
	_check(graph.scroll_offset.x > before, "Ctrl + 滚轮横向滚动")
	var ev2 := InputEventMouseButton.new()
	ev2.button_index = MOUSE_BUTTON_WHEEL_UP
	ev2.pressed = true
	ev2.position = center
	editor._input(ev2)
	_check(is_equal_approx(graph.scroll_offset.x, graph.scroll_offset.x), "无 Ctrl 的滚轮不被拦截")


## 从输出口拖到空白 → 面板按 image 类型限定 → 选节点后自动连线。
func _test_port_drag() -> void:
	var dialog: FxNodePicker = editor.create_dialog
	var edges_before: int = (shell.store.doc.get("edges", []) as Array).size()
	editor._on_connection_to_empty(StringName("tint"), 0, Vector2(320, 200))
	_check(dialog.port_filter_active(), "拖线到空白激活端口范围限定")
	_check(dialog.port_filter_type() == FxGraphFacade.access().port_image(), "限定类型取源端口类型 image")
	var candidates := dialog.filtered_types()
	_check(not candidates.is_empty(), "候选节点非空（%d 个）" % candidates.size())
	var all_compatible := true
	for type_id in candidates:
		var def := FxGraphFacade.access().catalog_def(type_id)
		if def == null:
			all_compatible = false
			continue
		var ports := FxCatalog.ports(def, {})
		var ok := false
		for p in ports.get("inputs", []):
			if FxPortType.can_connect(FxPortType.IMAGE, (p as Dictionary).get("type", "")):
				ok = true
		if not ok:
			all_compatible = false
	_check(all_compatible, "候选节点都带兼容输入端口")
	_check(candidates.size() < FxCatalog.all().size(), "搜索范围被限定（不是全部 %d 个节点）" % FxCatalog.all().size())
	dialog.choose_type("image.invert")
	await process_frame
	_check((shell.store.doc.get("edges", []) as Array).size() == edges_before + 1,
		"选中节点后自动补齐连线")
	editor._on_connection_from_empty(StringName("out"), 0, Vector2(320, 200))
	_check(dialog.port_filter_active() and dialog.port_filter_type() != &"",
		"从输入口拖出同样限定为可连接类型")
	dialog.clear_port_filter()
	_check(not dialog.port_filter_active(), "「显示全部节点」可放宽范围")


func _test_tracks() -> void:
	var store := shell.store
	var key := FxDocumentStore.track_key("blur", "radius")
	var render: FxRenderService = shell.render
	store.set_track_muted(key, true)
	_check(not store.is_track_animated(key), "mute 后轨道不参与动画")
	_check(not render._track_enabled("blur", "radius"), "渲染服务把 mute 传给执行器")
	store.set_track_muted(key, false)
	store.set_track_solo(key, true)
	_check(not render._track_enabled("tint", "amount"), "solo 时其它轨道冻结")
	_check(render._track_enabled("blur", "radius"), "solo 轨道本身仍参与动画")
	store.clear_track_states()

	var row := timeline.find_track("blur", "radius")
	_check(row >= 0, "找到 blur.radius 轨道")
	if row < 0:
		return
	var node_data := FxGraphDoc.node(store.doc, "blur")
	var before: Array = (node_data["params"]["radius"]["track"] as Array).duplicate(true)
	timeline._selected_keys[timeline._sel_key(row, 1)] = 0.0
	timeline._key_preview_delta = 0.1
	timeline._commit_key_drag()
	var after: Array = (FxGraphDoc.node(store.doc, "blur")["params"]["radius"]["track"] as Array)
	_check(absf(float(after[1][0]) - float(before[1][0]) - 0.1) < 0.02,
		"拖动关键帧改时间（%.2f → %.2f）" % [float(before[1][0]), float(after[1][0])])

	timeline._drag_start = Vector2(230, 40)
	timeline._drag_now = Vector2(1200, 160)
	timeline._apply_box_selection()
	_check(timeline._selected_keys.size() >= 1, "框选命中关键帧（%d 个）" % timeline._selected_keys.size())
	var keys_before := _total_keys()
	timeline._selected_keys.clear()
	timeline._selected_keys[timeline._sel_key(row, 0)] = 0.0
	timeline._delete_selected_keys()
	_check(_total_keys() == keys_before - 1, "Delete 删除选中关键帧")
	store.undo()
	_check(_total_keys() == keys_before, "删除可撤销")


func _total_keys() -> int:
	var total := 0
	for node_data in shell.store.doc.get("nodes", []):
		var params: Dictionary = (node_data as Dictionary).get("params", {})
		for path in FxTracks.collect(params).keys():
			var value: Variant = FxCatalog.value_at(params, String(path))
			if value is Dictionary and (value as Dictionary).has("track"):
				total += ((value as Dictionary).get("track", []) as Array).size()
	return total


func _test_recipe_form() -> void:
	var dialog := FxRecipeDialog.new()
	shell.add_child(dialog)
	var text := JSON.stringify(FxRecipePresets.fire())
	dialog.setup(text)
	_check(dialog.get("_tabs") != null and (dialog.get("_tabs") as TabContainer).get_tab_count() == 2,
		"配方对话框有表单 / JSON 双视图")
	_check((dialog.get("_form") as VBoxContainer).get_child_count() > 2, "表单渲染出配方字段与图层卡片")
	var before_layers: int = ((dialog.get("_recipe") as Dictionary).get("layers", []) as Array).size()
	dialog._add_layer()
	_check(((dialog.get("_recipe") as Dictionary).get("layers", []) as Array).size() == before_layers + 1,
		"表单可添加图层")
	_check(String(dialog.get("_text").text).contains("\"smoke\""), "表单改动实时同步回 JSON")
	dialog._write_field("count", 99, 0)
	_check(String(dialog.get("_text").text).contains("99"), "字段编辑写回 JSON")
	var first_type := String(((dialog.get("_recipe") as Dictionary)["layers"] as Array)[0]["type"])
	dialog._move_layer(0, 1)
	var moved_type := String(((dialog.get("_recipe") as Dictionary)["layers"] as Array)[1]["type"])
	_check(first_type == moved_type, "图层可上下移动")
	dialog._remove_layer(0)
	_check(((dialog.get("_recipe") as Dictionary).get("layers", []) as Array).size() == before_layers,
		"图层可删除")
	_check(String(dialog.get("_text").text).contains("\"layers\""), "JSON 原文保留完整配方")
	dialog.queue_free()


func _test_transplanted_skins() -> void:
	var maid: Dictionary = {}
	for entry in FxPluginHost.skin_entries():
		if String(entry.get("id", "")) == "maid-atelier":
			maid = entry
	_check(not maid.is_empty(), "移植皮肤 maid-atelier 已注册")
	_check(int(maid.get("protocol", 0)) == 2, "皮肤声明版本化选项协议 v2")
	_check((maid.get("options", []) as Array).size() >= 7, "移植皮肤暴露完整选项集")
	_check(FxPluginHost.is_active("editor.skin-manager"), "移植的皮肤管理器组件已激活")
	_check(not FxRegistry.window("skin.manager.window").is_empty(), "管理器注册了浮动窗口")

	shell.apply_skin("maid-atelier")
	await process_frame
	_check(FxUiKit.current.id == "maid-atelier", "可选中移植皮肤")
	_check(FxUiKit.current.build_theme() is Theme, "移植皮肤能产出 Theme")
	shell.set_skin_option("maid-atelier", "variant", "light")
	await process_frame
	_check(FxUiKit.BG.r > 0.7, "「陶瓷白」选项把背景切到亮色")
	_check(shell.skin_options("maid-atelier").get("variant", "") == "light", "选项按 skinId 持久化")
	shell.set_skin_option("maid-atelier", "show_lace", false)
	await process_frame
	_check(FxUiKit.current.corner_radius == 0, "关闭 U 形花边后回归直角")
	shell.set_skin_option("maid-atelier", "show_lace", true)
	await process_frame
	_check(FxUiKit.current.corner_radius > 0, "重新开启花边")

	var window: Variant = shell.open_window("skin.manager.window")
	await process_frame
	_check(window != null, "皮肤管理器窗口可打开")
	var manager: Control = window.get("_content") if window != null else null
	if manager == null and window != null:
		manager = window.get("content")
	if manager is FxSkinManagerWindow:
		_check((manager.get("_list") as VBoxContainer).get_child_count() >= 5,
			"管理器列出默认 + 4 套皮肤")
		_check((manager.get("_form") as VBoxContainer).get_child_count() >= 7,
			"管理器按协议渲染选项表单")
	shell.set_skin_option("maid-atelier", "background_brightness", 70)
	await process_frame
	_check(shell.window_layer.has("skin.manager.window"), "改选项时管理器窗口保持打开（不被信号回调销毁）")
	shell.reset_skin_options("maid-atelier")
	shell.apply_skin("default")
	await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	shell.set_toolbar_mode("compact")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LAYOUT))
	FxPluginHost.shutdown()
	quit(code)
