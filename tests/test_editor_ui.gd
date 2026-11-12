extends SceneTree
## P2 编辑器冒烟测试：节点/连线/关键帧/图层动态端口/保存读回。
##
## 注意：main.tscn 的根节点已经是 FxShell（基座），蓝图/时间轴/预览/文档
## 全部是插件面板。测试通过 shell.panel(id) / shell.service(id) 取到它们，
## 不再假设编辑器就是场景根。
## 运行：
##   godot --headless --path . --script res://tests/test_editor_ui.gd

var failures: Array[String] = []
var shell: FxShell
var store: FxDocumentStore
var editor: FxGraphEditor
var timeline: FxTimelinePanel
var preview: FxPreviewPanel
var document: FxDocumentActions
var out_dir := "user://graph_test"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("== P2 编辑器冒烟测试（插件化工作台） ==")
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		push_error("主场景加载失败")
		_quit(1)
		return
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _bind() -> bool:
	store = shell.store
	editor = shell.panel("editor.graph") as FxGraphEditor
	timeline = shell.panel("editor.timeline") as FxTimelinePanel
	preview = shell.panel("editor.preview") as FxPreviewPanel
	document = shell.service("document") as FxDocumentActions
	_check(shell != null and editor != null, "外壳与蓝图面板都已实例化")
	_check(timeline != null, "时间轴面板由插件注册")
	_check(preview != null, "预览面板由插件注册")
	_check(document != null, "文档服务由插件提供")
	return editor != null and timeline != null and document != null


func _run() -> void:
	for i in range(6):
		await process_frame
	if not _bind():
		_quit(1)
		return
	var doc: Dictionary = store.doc
	_check((doc.get("nodes", []) as Array).size() == 6, "示例图有 6 个节点")
	_check(editor.node_views.size() == 6, "6 个节点视图")
	_check((doc.get("edges", []) as Array).size() == 6, "6 条连线")
	# 求帧可能在后台线程上，等它出第一张图（同步路径第一帧就有）。
	for i in range(240):
		if preview.preview_rect.texture != null:
			break
		await process_frame
	_check(preview.preview_rect.texture != null, "启动即渲染出输出预览")
	var blur_view: FxGraphNodeView = editor.node_views.get("blur")
	_check(blur_view != null and blur_view.params_ui != null, "节点自带参数编辑器")
	if blur_view != null and blur_view.params_ui != null:
		_check(blur_view.params_ui._rows.size() == 1, "模糊节点只有 1 行参数（半径）")
		var radius_port := blur_view.input_port_index("radius")
		_check(radius_port >= 0 and blur_view.left_slots.size() == 2, "半径是可绑定端口，和图像端口各占一行")
		var row: Control = (blur_view.params_ui._rows[0] as Dictionary).get("row")
		_check(row != null and blur_view.slot_left.has(row.get_index()), "参数行左侧就是端口插槽")

	_test_keyframe()
	await _test_timeline_scope()
	await _test_layers()
	await _test_add_delete()
	await _test_connect_and_save()
	await _test_export()
	await _test_space_and_undo()
	await _test_incremental_plugin_toggle()
	_test_color_tracks()
	await _test_canvas_display()
	await _test_popup_later()
	await _test_color_keyframes()
	await _test_plugin_hub_side()
	await _test_bound_param_display()
	await _test_tabs_and_menus()
	await _test_frame_cache()

	print("----")
	if failures.is_empty():
		print("P2 冒烟测试全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _test_keyframe() -> void:
	editor._select("blur")
	var radius_row := timeline.find_track("blur", "radius")
	_check(radius_row >= 0, "底部轨道显示 blur.radius")
	_check((timeline.get("_rows") as Array).size() >= 2, "轨道按节点分组（组头 + 轨道行）")
	var panel := editor.param_panel
	var blur := FxGraphDoc.node(store.doc, "blur")
	var before: Array = (blur["params"]["radius"]["track"] as Array).duplicate(true)
	# 当前时间 0，删掉 0 帧 → 2 帧；再加回来 → 3 帧。
	panel._toggle_track("radius")
	var after_remove: Array = blur["params"]["radius"]["track"]
	_check(after_remove.size() == before.size() - 1, "在当前时间删除关键帧（%d → %d）" % [before.size(), after_remove.size()])
	panel._toggle_track("radius")
	var after_add: Array = blur["params"]["radius"]["track"]
	_check(after_add.size() == before.size(), "再次点击恢复关键帧（%d）" % after_add.size())
	timeline._toggle_key(radius_row)
	var after_timeline_remove: Array = blur["params"]["radius"]["track"]
	_check(after_timeline_remove.size() == before.size() - 1, "底部轨道双击删除关键帧")
	timeline._toggle_key(radius_row)
	var after_timeline_add: Array = blur["params"]["radius"]["track"]
	_check(after_timeline_add.size() == before.size(), "底部轨道再次双击恢复关键帧")


func _test_timeline_scope() -> void:
	# 给输出层 0 的不透明度打一条轨道，验证“层所属属性”能被展开显示。
	store.apply_path("out", "layers.0.opacity", {
		"track": [[0.0, 1.0], [0.5, 0.35]], "interp": "linear",
	})
	await process_frame
	var row := timeline.find_track("out", "layers.0.opacity")
	_check(row >= 0, "轨道收集到 layers.0.opacity")
	if row >= 0:
		var label := String((timeline.get("_rows")[row] as Dictionary).get("label", ""))
		_check(label.contains("底色") and label.contains("透明度"), "轨道标签解析为“底色 · 透明度”（实际 %s）" % label)
		var before: Variant = ((FxGraphDoc.node(store.doc, "out")["params"]["layers"][0]) as Dictionary)["opacity"]
		var before_keys: int = (before["track"] as Array).size()
		timeline._toggle_key(row)
		var after: Variant = ((FxGraphDoc.node(store.doc, "out")["params"]["layers"][0]) as Dictionary)["opacity"]
		_check((after["track"] as Array).size() == before_keys - 1, "轨道双击删除当前时间的关键帧")
		store.undo()
		var undone: Variant = ((FxGraphDoc.node(store.doc, "out")["params"]["layers"][0]) as Dictionary)["opacity"]
		_check(undone is Dictionary and (undone["track"] as Array).size() == before_keys, "轨道打帧可用 Ctrl+Z 撤销")
		store.redo()
		var redone: Variant = ((FxGraphDoc.node(store.doc, "out")["params"]["layers"][0]) as Dictionary)["opacity"]
		_check(redone is Dictionary and (redone["track"] as Array).size() == before_keys - 1, "重做恢复删除结果")
	# 仅选中过滤：选中 blur 时不应再显示 out 的轨道。
	timeline.set_scope_all(false)
	timeline.set_node("blur")
	_check(timeline.find_track("out", "layers.0.opacity") < 0, "“仅选中”过滤掉其他节点轨道")
	_check(timeline.find_track("blur", "radius") >= 0, "“仅选中”保留当前节点轨道")
	timeline.set_scope_all(true)
	_check(timeline.find_track("out", "layers.0.opacity") >= 0, "切回“全部轨道”恢复显示")


func _test_layers() -> void:
	editor._select("out")
	var panel := editor.param_panel
	var out_node := FxGraphDoc.node(store.doc, "out")
	panel._add_layer()
	for i in range(4):
		await process_frame
	var layers: Array = out_node["params"]["layers"]
	_check(layers.size() == 4, "添加图层后 layers=4（实际 %d）" % layers.size())
	var def := FxCatalog.def("output.final")
	var ports := FxCatalog.ports(def, out_node["params"])
	var has_layer3 := false
	for p in ports.get("inputs", []):
		if String((p as Dictionary).get("id", "")) == "layer_3":
			has_layer3 = true
	_check(has_layer3, "动态生成 layer_3 端口")
	var view: FxGraphNodeView = editor.node_views.get("out")
	_check(view != null and view.left_slots.size() >= 8,
		"输出节点视图含背景 / 4 个图层 / 3 个参数插槽（实际 %d）" % (view.left_slots.size() if view else -1))
	_check(view != null and view.input_port_index("layer_3") >= 0, "图层端口是普通输入插槽")
	_check(view != null and view.input_port_index("canvas_width") >= 0, "画布宽也能连线")
	panel = editor.param_panel
	panel._delete_layer(3)
	for i in range(4):
		await process_frame
	_check((out_node["params"]["layers"] as Array).size() == 3, "删除图层后恢复为 3")


func _test_add_delete() -> void:
	var dialog: FxNodePicker = editor.create_dialog
	_check(dialog != null, "节点创建弹窗存在")
	dialog.set_filter("反相")
	_check(dialog.filtered_types().has("image.invert"), "搜索“反相”能命中 image.invert")
	dialog.set_filter("zzz-no-such-node")
	_check(dialog.filtered_types().is_empty(), "无匹配时列表为空")
	dialog.set_filter("")
	_check(dialog.filtered_types().size() >= 20, "清空搜索后显示全部节点")
	dialog.set_filter("配方")
	_check(dialog.filtered_types().has("image.recipe"), "搜索“配方”能命中 VfxEngine 配方节点")
	var recipe_dialog := FxRecipeDialog.new()
	shell.add_child(recipe_dialog)
	recipe_dialog.setup("{}")
	_check(recipe_dialog.get_ok_button().disabled, "缺少 layers 的配方禁用“应用”")
	recipe_dialog.queue_free()
	dialog.set_filter("")
	# 卡片墙：一张卡一个节点，归属与分类来自节点定义（面板不再用目录树/纯文本列表）。
	_check(dialog.card_count() == dialog.filtered_types().size(),
		"卡片数等于筛选结果数（%d / %d）" % [dialog.card_count(), dialog.filtered_types().size()])
	dialog.open_at(Vector2(-1, -1))
	dialog.set_filter("模糊")
	for i in range(8):
		await process_frame
	var blur_thumb := false
	var owner_ok := false
	var category_ok := false
	if dialog.get("_cards").has("image.blur"):
		owner_ok = dialog.card_owner("image.blur") == "core.image"
		category_ok = dialog.card_category("image.blur") == "图像/处理"
		blur_thumb = dialog.card_has_image("image.blur")
	_check(owner_ok, "卡片能报出节点所属插件（core.image）")
	_check(category_ok, "卡片能报出节点分类（图像/处理）")
	_check(blur_thumb, "有画面的节点出真实渲染样张")
	dialog.set_filter("数值")
	for i in range(4):
		await process_frame
	var number_visual := true
	if dialog.get("_cards").has("math.number"):
		number_visual = dialog.card_has_image("math.number")
	_check(not number_visual, "纯数值节点没有样张，回退成分类字形")
	dialog.set_filter("")
	dialog.set_chip("图像/处理")
	_check(dialog.active_chip() == "图像/处理", "点分类标签能筛出该分类")
	_check(dialog.filtered_types().has("image.blur"), "分类筛选含 image.blur")
	_check(not dialog.filtered_types().has("anim.ease"), "分类筛选不含别的分类节点")
	dialog.set_chip("all")
	_check(dialog.filtered_types().size() >= 20, "回到“全部”后恢复完整列表")
	dialog.choose_type("image.invert")
	_check((store.doc.get("nodes", []) as Array).size() == 7, "弹窗添加节点后为 7 个")
	var new_id := ""
	for n in store.doc.get("nodes", []):
		if String((n as Dictionary).get("type", "")) == "image.invert":
			new_id = String((n as Dictionary).get("id", ""))
	_check(not new_id.is_empty(), "新节点有 id")
	var names: Array[StringName] = [StringName(new_id)]
	editor._on_delete_nodes_request(names)
	await process_frame
	await process_frame
	_check((store.doc.get("nodes", []) as Array).size() == 6, "删除节点后恢复为 6")


func _test_connect_and_save() -> void:
	var out_view: FxGraphNodeView = editor.node_views.get("out")
	var tint_view: FxGraphNodeView = editor.node_views.get("tint")
	# 重新添加一层，把 tint 连到 layer_2。
	editor._select("out")
	editor.param_panel._add_layer()
	for i in range(4):
		await process_frame
	out_view = editor.node_views.get("out")
	tint_view = editor.node_views.get("tint")
	var out_port := tint_view.output_port_index("image")
	var in_port := out_view.input_port_index("layer_3")
	_check(out_port >= 0 and in_port >= 0, "图层 3 的端口索引存在")
	var edges_before: int = (store.doc.get("edges", []) as Array).size()
	editor._on_connection_request(StringName("tint"), out_port, StringName("out"), in_port)
	await process_frame
	_check((store.doc.get("edges", []) as Array).size() == edges_before + 1, "连线写入文档")
	# 图层换序后，端口 id 应跟着图层走，而不是跟着下标走。
	editor.param_panel._move_layer(3, -1)
	for i in range(3):
		await process_frame
	var still_connected := false
	for e in store.doc.get("edges", []):
		if String((e as Dictionary).get("to_port", "")) == "layer_3":
			still_connected = true
	_check(still_connected, "图层换序后连线仍指向同一个图层")
	var result: Dictionary = editor.runner.call("run", store.doc, 0.5)
	_check(result.get("image") is Image, "连线后仍能渲染")
	var path := out_dir.path_join("ui_smoke.fxgraph")
	document.save_to(path)
	_check(FileAccess.file_exists(path), "保存文件")
	document.open_path(path)
	for i in range(3):
		await process_frame
	var loaded: Dictionary = store.doc
	_check((loaded.get("nodes", []) as Array).size() == 6, "读回节点数")
	_check((loaded.get("edges", []) as Array).size() == 7, "读回连线数（含新增图层连线）")
	var out_node := FxGraphDoc.node(loaded, "out")
	_check((out_node.get("params", {}).get("layers", []) as Array).size() == 4, "读回图层数")


func _test_export() -> void:
	FxGraphDoc.set_timeline(store.doc, 30, 0.2, true)
	var frame_path := out_dir.path_join("export_frame.png")
	shell.export_now("png.frame", frame_path)
	_check(FileAccess.file_exists(frame_path), "导出当前帧 PNG")
	var sheet_path := out_dir.path_join("export_sheet.png")
	shell.export_now("png.sheet", sheet_path)
	_check(FileAccess.file_exists(sheet_path), "导出精灵图集 PNG")
	var json_path := sheet_path.get_basename() + ".json"
	_check(FileAccess.file_exists(json_path), "导出图集 JSON")
	if FileAccess.file_exists(json_path):
		var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
		if payload is Dictionary:
			var pfx: Dictionary = (payload as Dictionary).get("meta", {}).get("pixelfx", {})
			_check(int(pfx.get("frames", 0)) == 6, "图集记录 6 帧（0.2s × 30fps）")
			_check(int(pfx.get("columns", 0)) == 3, "6 帧排成 3 列")
	var seq_dir := out_dir.path_join("seq")
	shell.export_now("png.sequence", seq_dir)
	var seq_files := DirAccess.get_files_at(seq_dir)
	_check(seq_files.size() == 6, "序列帧导出 6 张（实际 %d）" % seq_files.size())


func _test_space_and_undo() -> void:
	# 前面的导出测试把时长改成了 0.2s；无头帧间隔较大时会回绕，这里恢复成长时长再测播放。
	store.set_timeline(30, 2.0, true)
	shell.render.set_playing(false)
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	shell._input(space)
	await process_frame
	_check(shell.render.playing, "空格开始播放")
	var time_before := store.current_time
	for i in range(3):
		await process_frame
	_check(store.current_time > time_before, "播放推进时间（%.3f → %.3f）" % [time_before, store.current_time])
	var space2 := InputEventKey.new()
	space2.keycode = KEY_SPACE
	space2.pressed = true
	shell._input(space2)
	_check(not shell.render.playing, "再次空格暂停")

	var blur := FxGraphDoc.node(store.doc, "blur")
	var before: Variant = (blur["params"] as Dictionary).get("radius")
	store.apply_param("blur", "radius", 6.0, false)
	var after_write: Variant = (FxGraphDoc.node(store.doc, "blur")["params"] as Dictionary).get("radius")
	_check(is_equal_approx(FxPortType.as_number(after_write, -1), 6.0), "内联编辑写入文档")
	store.undo()
	var after_undo: Variant = (FxGraphDoc.node(store.doc, "blur")["params"] as Dictionary).get("radius")
	_check(str(after_undo) == str(before), "Ctrl+Z 撤销回到旧值")
	store.redo()
	var after_redo: Variant = (FxGraphDoc.node(store.doc, "blur")["params"] as Dictionary).get("radius")
	_check(is_equal_approx(FxPortType.as_number(after_redo, -1), 6.0), "重做恢复新值")

	# 粒子图集走 0.2s × 30fps = 6 帧，期望 3×2 网格。
	store.set_timeline(30, 0.2, true)
	var scene_path := out_dir.path_join("emitter.tscn")
	shell.export_now("godot.particles", scene_path, {"source": "sheet"})
	_check(FileAccess.file_exists(scene_path), "导出 Godot 粒子发生器 .tscn")
	if FileAccess.file_exists(scene_path):
		var text := FileAccess.get_file_as_string(scene_path)
		_check(text.contains("GPUParticles2D") and text.contains("ParticleProcessMaterial"), "场景包含粒子节点与粒子材质")
		_check(text.contains("shader_parameter/columns = 3.0") and text.contains("shader_parameter/rows = 2.0"), "翻转书按 3×2 取帧")
		_check(FileAccess.file_exists(scene_path.get_basename() + "_flipbook.gdshader"), "导出翻转书着色器")
		var loaded_scene: Resource = load(scene_path)
		_check(loaded_scene is PackedScene, "导出的粒子场景能被 Godot 解析")
		if loaded_scene is PackedScene:
			var instance := (loaded_scene as PackedScene).instantiate()
			_check(instance is GPUParticles2D, "场景根节点是 GPUParticles2D")
			if instance != null:
				instance.free()


## 停用插件应走增量协调：只撤回该插件，其它面板实例保持同一个对象。
func _test_incremental_plugin_toggle() -> void:
	var graph_before: Control = shell.panel("editor.graph")
	var timeline_before: Control = shell.panel("editor.timeline")
	_check(FxCatalog.has_def("image.glow"), "停用前 glow 节点存在")
	FxPluginHost.set_enabled("glow", false)
	for i in range(3):
		await process_frame
	_check(not FxCatalog.has_def("image.glow"), "停用插件后节点定义增量移除")
	_check(shell.panel("editor.graph") == graph_before, "蓝图面板实例未被重建")
	_check(shell.panel("editor.timeline") == timeline_before, "时间轴面板实例未被重建")
	_check(FxCatalog.has_def("image.blur"), "其它插件的节点定义保留")
	FxPluginHost.set_enabled("glow", true)
	for i in range(3):
		await process_frame
	_check(FxCatalog.has_def("image.glow"), "重新启用后节点定义恢复")
	_check(shell.panel("editor.graph") == graph_before, "重新启用后蓝图面板仍是同一实例")


## 颜色 / 数值数组轨道：必须真正插值，而不是到下一帧才跳变。
func _test_color_tracks() -> void:
	var track := {"track": [[0.0, "#ff0000"], [1.0, "#0000ff"]], "interp": "linear"}
	var mid: Variant = FxTracks.sample(track, 0.5)
	var color: Color = FxPortType.as_color(mid, Color.WHITE)
	_check(absf(color.r - 0.5) < 0.03 and absf(color.b - 0.5) < 0.03,
		"颜色关键帧中间帧插值（%s）" % str(mid))
	var last: Color = FxPortType.as_color(FxTracks.sample(track, 1.0), Color.WHITE)
	_check(last.b > 0.9 and last.r < 0.1, "颜色轨道终点取到末帧")
	var arr: Variant = FxTracks.sample({"track": [[0.0, [1, 2, 3, 4]], [1.0, [5, 6, 7, 8]]]}, 0.5)
	_check(arr is Array and absf(float((arr as Array)[0]) - 3.0) < 0.001,
		"等长数值数组逐元素插值（%s）" % str(arr))
	var text: Variant = FxTracks.sample({"track": [[0.0, "left"], [1.0, "right"]]}, 0.5)
	_check(String(text) == "left", "非颜色文本仍按 step 处理")


## 最终输出节点的「画布宽/高」：0 = 跟随文档，编辑框要显示实际值。
func _test_canvas_display() -> void:
	var writes: Array = []
	var ctx := {
		"param": {"id": "canvas_width", "kind": "int", "min": 0, "max": 4096, "step": 1},
		"get": func() -> Variant: return 0,
		"set": func(value: Variant) -> void: writes.append(value),
		"fallback_get": func() -> float: return 64.0,
		"host": null,
	}
	var built := FxWidgetRegistry.build("int", ctx)
	var control: Control = built.get("control")
	root.add_child(control)   # SpinBox 的 LineEdit 提交处理要入树后才接上
	await process_frame
	var spin: SpinBox = null
	for child in control.get_children():
		if child is SpinBox:
			spin = child as SpinBox
	_check(spin != null and spin.value == 64.0, "0=跟随时显示实际画布宽（64）")
	if spin != null:
		_check(spin.get_line_edit().text == "64", "宽编辑框文本正确（%s）" % spin.get_line_edit().text)
		# SpinBox.value 的程序赋值不会发 value_changed（正是 sync 需要的）；模拟用户编辑。
		spin.get_line_edit().text = "80"
		spin.get_line_edit().emit_signal("text_submitted", "80")
		await process_frame
		_check(writes.size() == 1 and int(writes[0]) == 80, "改成别的值才写入覆盖值")
		spin.get_line_edit().text = "64"
		spin.get_line_edit().emit_signal("text_submitted", "64")
		await process_frame
		_check(writes.size() == 2 and int(writes[1]) == 0, "改回有效值恢复『跟随文档』")
	control.queue_free()
	var out_view: FxGraphNodeView = editor.node_views.get("out")
	if out_view != null and out_view.params_ui != null:
		var declared := false
		for row in out_view.params_ui._rows:
			if String((row as Dictionary).get("pid", "")) == "canvas_width":
				declared = true
		_check(declared, "输出节点有画布宽参数行")


## 颜色关键帧：经真实参数行写回（不是直接构造轨道），确认存储格式与插值都对。
func _test_color_keyframes() -> void:
	var doc := FxGraphDoc.create("color")
	FxGraphDoc.set_timeline(doc, 10, 1.0, true)
	FxGraphDoc.add_node(doc, "image.solid", "s", Vector2.ZERO, {})
	var store2 := FxDocumentStore.new()
	store2.attach(doc)
	var view := FxGraphNodeView.new()
	view.setup("s", FxCatalog.def("image.solid"), FxGraphDoc.node(doc, "s"), store2, Callable())
	root.add_child(view)
	await process_frame
	var ui: FxNodeParams = view.params_ui
	ui.set_time(0.0)
	ui.call("_toggle_track", "color")
	ui.set_time(1.0)
	ui.call("_write", "color", Color(1, 0, 0, 1))
	var track: Variant = (FxGraphDoc.node(doc, "s").get("params", {}) as Dictionary).get("color")
	_check(track is Dictionary and (track as Dictionary).has("track"), "点 ◆ 后颜色参数变成轨道")
	var keys: Array = (track as Dictionary).get("track", []) if track is Dictionary else []
	_check(keys.size() == 2, "在 0s / 1s 各留一个关键帧（%d）" % keys.size())
	if keys.size() == 2:
		_check(String((keys[0] as Array)[1]).begins_with("#"),
			"颜色按 #rrggbb 存储（%s）" % str((keys[0] as Array)[1]))
	ui.set_time(0.5)
	var mid := FxPortType.as_color(ui.call("_display_value", "color"), Color.BLACK)
	_check(mid.r > 0.3 and mid.b < 0.4, "中间帧是插值结果而不是端点（%s）" % mid.to_html())
	# 旧文档里可能存的是 Color.to_html() 的裸十六进制（没有 #）
	var legacy: Variant = FxTracks.sample({"track": [[0.0, "000000ff"], [1.0, "ffffffff"]]}, 0.5)
	_check(FxPortType.as_color(legacy, Color.BLACK).r > 0.3, "旧文档的裸十六进制颜色也能插值")
	view.queue_free()
	await process_frame


## 参数被连线驱动：行上立刻显示上游值，并且不可编辑。
func _test_bound_param_display() -> void:
	var doc := FxGraphDoc.create("bound")
	FxGraphDoc.set_canvas(doc, 8, 8)
	FxGraphDoc.add_node(doc, "math.number", "num", Vector2.ZERO, {"op": "add", "a": 7.0, "b": 0.0})
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2(0, 120), {"cell": 4})
	FxGraphDoc.add_node(doc, "image.blur", "blur", Vector2(200, 0), {"radius": 2})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(420, 0), {})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "num", "number", "blur", "radius")
	FxGraphDoc.connect_ports(doc, "src", "image", "blur", "image")
	FxGraphDoc.connect_ports(doc, "blur", "image", "out", "layer_0")
	var store2 := FxDocumentStore.new()
	store2.attach(doc)
	var view := FxGraphNodeView.new()
	view.setup("blur", FxCatalog.def("image.blur"), FxGraphDoc.node(doc, "blur"), store2, Callable())
	root.add_child(view)
	await process_frame
	var ui: FxNodeParams = view.params_ui
	_check(ui._bound.has("radius"), "连线后该参数行被标记为驱动")
	_check(int(ui.call("_display_value", "radius")) == 2, "拿到本帧数值前先显示文档值")
	var result := FxGraphRunner.new().run(doc, 0.0)
	view.apply_live_params(result.get("node_params", {}).get("blur", {}))
	_check(int(ui.call("_display_value", "radius")) == 7, "连上之后立刻显示上游值（7）")
	var frozen := false
	for row in ui._rows:
		if String(row.get("pid", "")) == "radius":
			var control: Control = (row.get("row") as Control).get_child(1)
			frozen = control.mouse_filter == Control.MOUSE_FILTER_IGNORE
	_check(frozen, "被驱动的参数控件不可编辑")
	# 断开连线后重建视图：参数恢复可编辑
	FxGraphDoc.disconnect_ports(store2.doc, "num", "number", "blur", "radius")
	var fresh := FxGraphNodeView.new()
	fresh.setup("blur", FxCatalog.def("image.blur"), FxGraphDoc.node(store2.doc, "blur"), store2, Callable())
	root.add_child(fresh)
	await process_frame
	_check(fresh.params_ui != null and not fresh.params_ui._bound.has("radius"),
		"断开连线后参数不再被驱动")
	view.queue_free()
	fresh.queue_free()
	await process_frame


## 弹窗时序与生命周期：延后弹出（viewport 登记完子窗口才 grab_focus），
## 关闭只销毁不 hide（hide 会触发引擎的 subwindow 焦点索引错误 viewport.cpp:440）。
func _test_popup_later() -> void:
	var dialog := AcceptDialog.new()
	FxUiKit.style_window(dialog)
	root.add_child(dialog)
	FxUiKit.popup_later(dialog)
	await process_frame
	await process_frame
	_check(dialog.visible, "内嵌弹窗在登记完成后才显示")
	# 无头没有原生窗口：设置默认想要独立窗口，但平台不支持时如实回落内嵌。
	_check(not dialog.force_native, "无头环境下弹窗回落为内嵌窗口")
	_check(not FxUiKit.native_windows(), "无头环境下「弹窗独立窗口」判定为否")
	_check(not dialog.dialog_hide_on_ok, "确定键不让对话框自己 hide")
	_check(not dialog.dialog_close_on_escape, "Esc 不让对话框自己 hide")
	dialog.confirmed.emit()
	await process_frame
	await process_frame
	_check(not is_instance_valid(dialog), "确定后对话框直接销毁")

	var second := AcceptDialog.new()
	FxUiKit.style_window(second)
	root.add_child(second)
	FxUiKit.popup_later(second)
	await process_frame
	await process_frame
	second.canceled.emit()
	await process_frame
	await process_frame
	_check(not is_instance_valid(second), "取消后对话框直接销毁")
	_check(not FxUiKit.native_file_dialogs() or
		DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE),
		"无头/无原生支持时文件面板回落内嵌")


## 文档标签：子图开新标签、主干不可关、关标签写回文件；
## 顺带覆盖节点右键菜单表与「只有空白处才弹添加面板」的分工。
## 逐帧缓存：渲染出来的帧进缓存，预渲染把整段补齐，清理后归零。
## 时间轴标尺与状态栏都从同一份状态取数，所以一起验。
func _test_frame_cache() -> void:
	var render: FxRenderService = shell.service("render")
	_check(render != null, "渲染服务可用")
	if render == null:
		return
	render.set_playing(false)
	render.request_render()
	for i in range(120):
		await process_frame
		if render.frame_count() > 0 and render.last_image() != null:
			break
	var total := render.frame_count()
	_check(total > 0, "缓存按帧率切出总帧数（%d）" % total)
	var index := render.frame_index()
	for i in range(60):
		await process_frame
		if render.cache_state(index) == 2:
			break
	_check(render.cache_state(index) == 2, "刚渲染过的当前帧标绿（已缓存）")
	var stats := render.cache_stats()
	_check(int(stats.get("ready", 0)) >= 1, "缓存统计里有已缓存帧")
	# 时间轴面板从渲染服务取状态：没绑上就画不出色带。
	var bound: Variant = timeline.get("render")
	_check(bound != null, "时间轴面板绑定了渲染服务")
	# 状态栏：底部要能看到「缓存 x/y」。
	var label: Label = shell.get("_stats_label")
	_check(label != null and label.text.contains("缓存"), "状态栏显示缓存进度（%s）" % (label.text if label != null else ""))
	# 预渲染：无头环境允许手动触发，跑完应该整段都绿。
	var started: bool = render.start_prefetch()
	_check(started, "手动预渲染可以启动")
	if started:
		for i in range(600):
			await process_frame
			if not render.prefetching():
				break
		var after := render.cache_stats()
		_check(not render.prefetching(), "预渲染在超时前结束")
		_check(int(after.get("ready", 0)) >= int(after.get("total", 1)),
			"预渲染把整段补齐（%d/%d）" % [int(after.get("ready", 0)), int(after.get("total", 1))])
	# 设置里的「清理帧缓存」是按钮型条目（kind=action），不是可存的开关。
	var entry := FxRegistry.setting("render.cache_clear")
	_check(String(entry.get("kind", "")) == "action", "设置里有「清理帧缓存」按钮项")
	_check((entry.get("action", Callable()) as Callable).is_valid(), "按钮绑定了可执行动作")
	var built := FxSettingWidgets.build(entry, func(_id: String, _v: Variant) -> void: pass)
	_check(built is Button, "按钮型设置渲染成 Button")
	if built is Button:
		built.queue_free()
	# 并行预渲染：帧彼此独立，多条线程同时算（真实工程 60 帧 36s → 约 2.5s）。
	var progress: Dictionary = render.prefetch_progress()
	_check(int(progress.get("workers", 0)) >= 2,
		"预渲染启用多条并行线程（%d 条）" % int(progress.get("workers", 0)))

	# 播放时间推进必须走轻量通道：set_time() 的全量 coeffect 广播在 103 节点
	# 工程实测每帧约 120ms，会把 UI 拖死；静默版本只发 time_ticked。
	# GDScript 的 lambda 对 int 是值捕获，计数要放进 Array 才能回写。
	var counts := [0, 0]
	var on_changed := func(_keys: Array) -> void: counts[0] += 1
	var on_tick := func(_t: float) -> void: counts[1] += 1
	store.changed.connect(on_changed)
	store.time_ticked.connect(on_tick)
	var tl: Dictionary = FxGraphDoc.timeline(store.doc)
	var duration := maxf(float(tl.get("duration", 1.0)), 0.2)
	var target := clampf(store.current_time + 0.1, 0.0, duration)
	if absf(target - store.current_time) < 0.001:
		target = 0.0
	store.set_time_silent(target)
	_check(counts[0] == 0, "播放推进时间不触发全量 coeffect 广播")
	_check(counts[1] == 1, "播放推进时间发出轻量 time_ticked")
	_check(absf(store.current_time - target) < 0.001, "静默推进仍然更新当前时间")
	store.changed.disconnect(on_changed)
	store.time_ticked.disconnect(on_tick)

	# 播放 = 只读缓存。帧号必须连续、不能丢帧，且界面线程不做任何求值。
	var seen: Array[int] = []
	var paused_frames: Array[int] = []
	var collect := func(_image: Image, stats: Dictionary) -> void:
		if bool(stats.get("paused", false)):
			paused_frames.append(int(stats.get("frame", -1)))
		elif bool(stats.get("cached", false)):
			seen.append(int(stats.get("frame", -1)))
	render.rendered.connect(collect)
	render.set_playing(true)
	for i in range(240):
		await process_frame
	render.set_playing(false)
	await process_frame
	render.rendered.disconnect(collect)
	var jumps := 0
	for i in range(1, seen.size()):
		var step := seen[i] - seen[i - 1]
		if step != 1 and step != -(total - 1):
			jumps += 1
	_check(seen.size() >= 2, "播放发布了多个缓存帧（%d）" % seen.size())
	_check(jumps == 0, "播放帧号连续，无跳帧")
	_check(render.cache_misses == 0, "整段缓存齐备时播放零未命中")
	_check(render.cache_hits >= 2, "播放全部命中帧缓存（%d 次）" % render.cache_hits)
	# 停止播放必须钉在「当前播放头」那一帧，且不能被在途旧结果覆盖。
	var expected := render.cache.index_for_time(store.current_time)
	_check(paused_frames.size() == 1, "停止时发布恰好一张定格帧（%d）" % paused_frames.size())
	_check(paused_frames.size() == 1 and paused_frames[0] == expected,
		"定格帧号等于当前播放头（%d / 期望 %d）" % [
			paused_frames[0] if not paused_frames.is_empty() else -1, expected])
	for i in range(30):
		await process_frame
	var final_stats: Dictionary = render.last_stats()
	_check(bool(final_stats.get("paused", false)) or bool(final_stats.get("cached", false)) 		or float(final_stats.get("ms", -1.0)) >= 0.0,
		"停止后画面不再被播放期在途结果覆写")
	store.set_time(0.0)

	# ---- 紧密文件：单文件 + 定长偏移，零 PNG 编码 ----
	var packed := FxFrameCache.new()
	packed.root_dir = "user://graph_test/packed_probe"
	packed.configure("user", 64, 32)
	packed.root_dir = "user://graph_test/packed_probe"
	packed.clear_all()
	var probe_doc := {"nodes": [], "edges": []}
	packed.prepare(probe_doc, 30, 0.2)
	var probe_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	probe_img.fill(Color(0.2, 0.4, 0.6, 0.8))
	for fi in range(6):
		packed.put(fi, probe_img, true, true)
	var packed_path := packed.file_path()
	_check(packed_path.ends_with("frames.fxc"), "缓存落在单一紧密文件上")
	_check(FileAccess.file_exists(packed_path), "紧密文件已落盘")
	if FileAccess.file_exists(packed_path):
		var head := FileAccess.open(packed_path, FileAccess.READ)
		_check(head.get_32() == 0x43465846, "紧密文件头 magic 正确")
		var expect := 64 + 6 + 6 * 4 * 4 * 4
		_check(int(head.get_length()) == expect, "紧密文件按定长预分配（%d 字节）" % expect)
		head.close()
	# 重新打开一个实例：从位图恢复状态，并按帧号偏移直读像素。
	var reopened := FxFrameCache.new()
	reopened.root_dir = packed.root_dir
	reopened.prepare(probe_doc, 30, 0.2)
	_check(int(reopened.stats().get("ready", 0)) == 6, "重开后从位图恢复 6 帧状态")
	var back: Image = reopened.fetch(3)
	_check(back != null and back.get_data() == probe_img.get_data(),
		"按帧偏移读回与写入逐字节一致")
	# 纯内存模式：不产生任何文件，仍能命中。
	var mem := FxFrameCache.new()
	mem.configure("memory", 64, 32)
	mem.root_dir = "user://graph_test/memory_probe"
	mem.prepare(probe_doc, 30, 0.2)
	mem.put(0, probe_img, true, true)
	_check(not FileAccess.file_exists(mem.file_path()), "纯内存模式不产生文件")
	_check(mem.fetch(0) != null, "纯内存模式仍能命中")
	_check(not bool(mem.stats().get("disk_enabled", true)), "纯内存模式关闭磁盘层")
	# LRU：预算压到 1 字节时清掉旧桶（当前桶保留）。
	packed.max_disk_bytes = 1
	var lru_freed := packed.prune()
	_check(lru_freed >= 0, "LRU 自动清理可执行（释放 %d 字节）" % lru_freed)
	packed.clear_all()
	mem.clear_all()

	# 清理缓存：状态回到「没算过」，磁盘占用清零。
	var freed := render.clear_cache()
	_check(freed >= 0, "清理缓存返回释放字节数")
	_check(render.cache_state(0) == 0, "清理后第一帧回到未缓存")
	_check(int(render.cache_stats().get("ready", 0)) == 0, "清理后已缓存帧归零")
	_check(render.cache.disk_bytes() == 0, "清理后磁盘占用为 0")


func _test_tabs_and_menus() -> void:
	_check(editor.tab_count() == 1, "默认只有主干标签")
	_check(not editor.tab_closable(0), "主干标签不可关闭")
	_check(editor.active_tab() == 0, "当前停在主干")

	# 造一个子工程，并在主图里放一个指向它的子图节点。
	var child := FxGraphDoc.create("测试子图")
	FxGraphDoc.set_canvas(child, 96, 64)
	FxGraphDoc.add_node(child, "image.solid", "c1", Vector2(0, 0))
	child["output"] = "c1"
	var path := out_dir.path_join("tab_child.fxgraph")
	FxGraphDoc.save(child, path)

	store.begin_batch()
	var made := store.add_node("graph.subgraph", "", Vector2(240, 240), {"path": path})
	store.commit_batch()
	var sub_id := String(made.get("id", ""))
	await process_frame
	_check(editor.open_subgraph(sub_id), "打开子图节点进了子工程")
	_check(editor.tab_count() == 2, "多出一个标签")
	_check(editor.tab_closable(1), "子图标签可关闭")
	_check(editor.active_tab() == 1, "当前在子图标签")
	_check((store.doc.get("nodes", []) as Array).size() == 1, "画布换成了子工程的文档")
	_check(editor.open_tab_paths()[1] == path, "标签记住了文件路径")
	_check(editor.active_document_path() == path, "子图标签对外报出自己的文件路径")
	_check(document.save_state_text().begins_with("tab_child"),
		"状态栏跟着显示子图文件名（%s）" % document.save_state_text())

	# 改了内容 → 标签要显示未保存
	store.add_node("image.solid", "", Vector2(160, 0))
	await process_frame
	_check(editor.tab_dirty(1), "改过内容的子图标签打了未保存点")

	editor.close_tab(1)
	await process_frame
	_check(editor.tab_count() == 1, "关闭后只剩主干")
	_check(editor.active_tab() == 0, "自动切回主干")
	_check((store.doc.get("nodes", []) as Array).size() > 1, "主干文档回来了")
	_check(editor.active_document_path() == "", "回到主干后路径为空（Ctrl+S 归工程包）")
	var reread := FxGraphDoc.load_json(path)
	_check((reread.get("nodes", []) as Array).size() == 2, "关闭时把子图改动写回了文件")

	# 节点右键菜单：一张声明式的表，直接断言它
	var items := editor.node_menu_items([sub_id])
	var actions: Array[String] = []
	var enter_item: Dictionary = {}
	for item in items:
		if bool(item.get("separator", false)):
			continue
		actions.append(String(item.get("id", "")))
		if String(item.get("id", "")) == "enter":
			enter_item = item
	_check(actions.has("enter") and actions.has("pack") and actions.has("delete"),
		"节点菜单有进子图 / 打包 / 删除")
	_check(not bool(enter_item.get("disabled", true)), "子图节点上「打开子图」可用")
	var blur_enter: Dictionary = {}
	for item in editor.node_menu_items(["blur"]):
		if String(item.get("id", "")) == "enter":
			blur_enter = item
	_check(bool(blur_enter.get("disabled", true)), "普通节点上「打开子图」置灰")
	var delete_label := ""
	for item in editor.node_menu_items(["blur", "mix"]):
		if String(item.get("id", "")) == "delete":
			delete_label = String(item.get("label", ""))
	_check(delete_label.contains("2 个节点"), "批量选中时菜单带上数量（%s）" % delete_label)

	# ---- 真实事件路径：双击下钻、右键出菜单、空白右键才开添加面板 ----
	var sub_view: FxGraphNodeView = editor.node_views.get(sub_id)
	_check(sub_view != null, "子图节点还在主图里")
	if sub_view != null:
		var dbl := InputEventMouseButton.new()
		dbl.button_index = MOUSE_BUTTON_LEFT
		dbl.pressed = true
		dbl.double_click = true
		dbl.position = Vector2(12, 12)
		editor._on_node_gui_input(dbl, sub_view)
		await process_frame
		_check(editor.tab_count() == 2, "双击子图节点真的开出了标签")
		editor.close_tab(1)
		await process_frame

	sub_view = editor.node_views.get(sub_id)
	if sub_view != null:
		var right := InputEventMouseButton.new()
		right.button_index = MOUSE_BUTTON_RIGHT
		right.pressed = true
		right.position = Vector2(8, 8)
		editor._on_node_gui_input(right, sub_view)
		await process_frame
		_check(editor._selection.has(sub_id), "右键未选中的节点会先把它选中")
		_check(not editor.create_dialog.visible, "节点上右键不打开添加面板")
		var menu: PopupMenu = editor.get("_node_menu")
		_check(menu != null and menu.item_count > 0, "节点右键弹出的是节点菜单")

	# ---- 添加面板：空白右键才弹，且位置/尺寸都能拖 ----
	var dialog := editor.create_dialog
	dialog.hide_picker()
	editor._on_popup_request(Vector2(80, 60))
	_check(dialog.visible, "空白处右键打开了添加节点面板")
	var before := dialog.panel_size()
	_check(before.x < 900.0, "添加面板默认不再占半个屏幕（宽 %.0f）" % before.x)

	dialog.move_panel_to(Vector2(120, 90))
	dialog._begin_drag("move", Vector2(200, 200))
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(240, 230)
	dialog._input(motion)
	_check(dialog.panel_position() == Vector2(160, 120), "拖动标题条面板跟着走（%s）" % dialog.panel_position())
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = Vector2(240, 230)
	dialog._input(release)
	_check(not dialog.dragging(), "松开鼠标结束拖拽")

	dialog._begin_drag("resize", Vector2(300, 300))
	var grow := InputEventMouseMotion.new()
	grow.position = Vector2(420, 400)
	dialog._input(grow)
	_check(dialog.panel_size().x > 700.0, "拖右下角抓手把面板拉大（宽 %.0f）" % dialog.panel_size().x)

	dialog.resize_panel(Vector2(1, 1))
	await process_frame
	var clamped := dialog.panel_size()
	_check(clamped.x <= 560.0 and clamped.y >= 352.0, "缩到最小时按最小尺寸兜底（%s）" % clamped)
	dialog.hide_picker()

func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)


## 插件中心：列表与详情默认是「列表在左、详情在右」，设置能一键互换。
func _test_plugin_hub_side() -> void:
	var hub := FxPluginHub.new()
	hub.setup(shell)
	shell.add_child(hub)
	await process_frame
	var columns: HSplitContainer = hub.get("_columns")
	var side: Control = hub.get("_side")
	var detail: Control = hub.get("_detail")
	_check(columns != null and side != null and detail != null, "插件中心有列表与详情两栏")
	_check(columns.get_child(0) == side, "默认列表在左（详情在右）")
	_check(hub.get("_flip") != null, "标题栏有左右互换按钮")
	FxSettings.set_value("ui.hub_list_right", true)
	hub.call("_apply_side_order")
	await process_frame
	_check(columns.get_child(0) == detail, "打开设置后列表换到右边")
	FxSettings.set_value("ui.hub_list_right", false)
	hub.call("_apply_side_order")
	await process_frame
	_check(columns.get_child(0) == side, "关掉设置后恢复列表在左")
	hub.queue_free()
