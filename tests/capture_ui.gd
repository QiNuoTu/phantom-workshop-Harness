extends SceneTree
## 开发期截图工具：加载插件化外壳，渲染几帧后把视口存成 PNG。
## 运行（不要加 --headless，需要真实渲染）：
##   godot --path . --script res://tests/capture_ui.gd --resolution 1440x900

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		push_error("无法加载主场景")
		_quit(1)
		return
	var shell: Control = packed.instantiate()
	root.add_child(shell)
	_capture.call_deferred(shell)


func _capture(shell: Control) -> void:
	for i in range(8):
		await process_frame
	# 截图固定从「官方默认」开始：皮肤选择是持久化的，别让上次实验影响基线。
	shell.call("apply_skin", "default")
	for i in range(4):
		await process_frame
	var graph: Control = shell.call("panel", "editor.graph")
	if graph == null:
		push_error("缺少 editor.graph 面板")
		_quit(1)
		return
	_save("user://graph_test/ui.png")

	# 预览折叠：只收起预览框，参数行与端口保持原位。
	var out_view = graph.get("node_views").get("out")
	if out_view != null:
		out_view.call("_toggle_collapse")
		for i in range(4):
			await process_frame
		_save("user://graph_test/ui_collapsed_preview.png")
		out_view.call("_toggle_collapse")
		for i in range(3):
			await process_frame

	shell.get("store").set_time(0.5)
	graph.call("_select", "out")
	for i in range(6):
		await process_frame
	_save("user://graph_test/ui_layers.png")

	graph.call("_popup_create_menu")
	for i in range(4):
		await process_frame
	_save("user://graph_test/ui_create.png")
	var dialog = graph.get("create_dialog")
	if dialog != null:
		(dialog as Control).hide()

	shell.call("open_window", "editor.palette")
	for i in range(4):
		await process_frame
	_save("user://graph_test/ui_palette.png")
	shell.call("close_window", "editor.palette")

	shell.call("open_window", "editor.help.window")
	for i in range(4):
		await process_frame
	_save("user://graph_test/ui_help.png")
	shell.call("close_window", "editor.help.window")

	# 皮肤切换：整套视觉由插件贡献，重建 UI 后所有面板取新颜色 token。
	shell.call("_apply_skin", "light", true)
	for i in range(6):
		await process_frame
	_save("user://graph_test/ui_skin_light.png")

	# 停靠区折叠：只留细条，面板实例不销毁。
	shell.call("_handle_layout_action", "layout.collapse_all")
	for i in range(4):
		await process_frame
	_save("user://graph_test/ui_collapsed.png")
	shell.call("_apply_skin", "default", true)
	shell.call("_handle_layout_action", "layout.expand_all")
	for i in range(4):
		await process_frame

	# 移植的皮肤管理器窗口 + 深海女仆工坊皮肤。
	shell.call("open_window", "skin.manager.window")
	for i in range(5):
		await process_frame
	_save("user://graph_test/ui_skin_manager.png")
	shell.call("close_window", "skin.manager.window")

	shell.call("apply_skin", "maid-atelier")
	for i in range(6):
		await process_frame
	_save("user://graph_test/ui_maid_atelier.png")

	# 皮肤管理器里的效果预览图（preview.webp 来自外部贴图包）。
	shell.call("open_window", "skin.manager.window")
	for i in range(5):
		await process_frame
	_save("user://graph_test/ui_skin_preview.png")
	shell.call("close_window", "skin.manager.window")
	shell.call("apply_skin", "default")
	for i in range(4):
		await process_frame

	# 声明式配置：设置中心的表单由插件贡献的条目生成。
	shell.call("open_window", "settings.window")
	for i in range(5):
		await process_frame
	var settings_window = shell.get("window_layer").get("_windows").get("settings.window")
	if settings_window != null:
		settings_window.call("present_at", Rect2(Vector2(300, 140), Vector2(900, 640)))
		for i in range(3):
			await process_frame
		_save("user://graph_test/ui_settings.png")
		# 切到「渲染质量」分组：缓存开关、清理按钮与 GPU 设置都在这里。
		var form: Control = null
		for node in settings_window.find_children("*", "Control", true, false):
			if (node as Control).has_method("select_group"):
				form = node as Control
				break
		if form != null:
			form.call("select_group", "渲染质量")
			for i in range(5):
				await process_frame
			_save("user://graph_test/ui_settings_cache.png")
	shell.call("close_window", "settings.window")

	# 插件中心（左右分栏）：右侧列表、左侧详情 + 功能 + 设置。
	shell.call("open_window", "plugin.hub.window")
	for i in range(5):
		await process_frame
	var hub_windows: Dictionary = shell.get("window_layer").get("_windows")
	var hub = hub_windows.get("plugin.hub.window")
	if hub != null:
		hub.call("present_at", Rect2(Vector2(60, 50), Vector2(1060, 700)))
		var content: Control = hub.get("content")
		if content != null and content.has_method("select"):
			content.call("select", "skin.maid-atelier")
	for i in range(5):
		await process_frame
	_save("user://graph_test/ui_plugin_hub.png")
	shell.call("close_window", "plugin.hub.window")

	# 多语言：切到英文后菜单 / 面板标题统一刷新，插件中心显示图标与依赖。
	FxSettings.set_value("general.locale", "en_US")
	for i in range(6):
		await process_frame
	shell.call("open_window", "plugin.hub.window")
	for i in range(5):
		await process_frame
	_save("user://graph_test/ui_english_hub.png")
	shell.call("close_window", "plugin.hub.window")
	FxSettings.set_value("general.locale", "zh_CN")
	for i in range(6):
		await process_frame

	# 面板分离：同一个 Control 挂进可拖动的浮动窗口。
	var exposed: Array[Dictionary] = shell.call("exposed_panels")
	var pick := ""
	for entry in exposed:
		if String(entry.get("area", "")) == "right":
			pick = String(entry.get("id", ""))
			break
	if not pick.is_empty():
		shell.call("detach_panel", pick)
		for i in range(5):
			await process_frame
		_save("user://graph_test/ui_detached.png")
		shell.call("redock_panel", pick)

	# ---- 文档标签：双击子图节点 → 顶部多一个可关闭的标签 ----
	# 皮肤切换会重建面板，前面拿到的 panel 引用此刻已经释放，重新取一次。
	graph = shell.call("panel", "editor.graph") as Control
	var child := FxGraphDoc.create("探针子图")
	FxGraphDoc.set_canvas(child, 96, 64)
	FxGraphDoc.add_node(child, "image.solid", "c1", Vector2(0, 0))
	child["output"] = "c1"
	FxGraphDoc.save(child, "user://graph_test/probe_child.fxgraph")
	var live_store: FxDocumentStore = shell.get("store")
	var made: Dictionary = live_store.add_node("graph.subgraph", "", Vector2(320, 320),
		{"path": "user://graph_test/probe_child.fxgraph"})
	for i in range(4):
		await process_frame
	graph.call("open_subgraph", String(made.get("id", "")))
	for i in range(6):
		await process_frame
	_save("user://graph_test/ui_tabs.png")
	graph.call("_popup_tab_menu", 1)
	for i in range(4):
		await process_frame
	_save("user://graph_test/ui_tab_menu.png")
	var tab_menu: PopupMenu = graph.get("_tab_menu")
	if tab_menu != null:
		tab_menu.hide()
	graph.call("close_tab", 1)
	for i in range(5):
		await process_frame

	# ---- 节点右键菜单 ----
	graph.call("_select", "blur")
	await process_frame
	graph.call("_popup_node_menu", Vector2(430, 250))
	for i in range(4):
		await process_frame
	_save("user://graph_test/ui_node_menu.png")
	var node_menu: PopupMenu = graph.get("_node_menu")
	if node_menu != null:
		node_menu.hide()

	# ---- 停靠标签右键（面板菜单） ----
	var docks: Dictionary = shell.get("dock_areas")
	var center_dock: FxDockArea = docks.get("center")
	if center_dock != null:
		center_dock.call("show_panel_menu", "editor.graph", Vector2(380, 96))
		for i in range(4):
			await process_frame
		_save("user://graph_test/ui_panel_menu.png")
		var ctx: PopupMenu = center_dock.get("_ctx_menu")
		if ctx != null:
			ctx.hide()

	# ---- 帧缓存：预渲染整段 → 标尺色块变绿、状态栏显示进度 ----
	var render_svc: Object = shell.call("service", "render")
	if render_svc != null and render_svc.has_method("start_prefetch"):
		render_svc.call("start_prefetch")
		for i in range(300):
			await process_frame
			if not bool(render_svc.call("prefetching")):
				break
		for i in range(6):
			await process_frame
		_save("user://graph_test/ui_cache.png")

	# ---- GPU 后端：切过去后真实外壳照常出图 ----
	var prev_backend := String(FxSettings.value("render.backend"))
	FxSettings.set_value("render.backend", "gpu.standard")
	FxRenderBroker.invalidate()
	if render_svc != null and render_svc.has_method("request_render"):
		render_svc.call("request_render")
		for i in range(180):
			await process_frame
			var probe: Dictionary = render_svc.call("last_stats")
			if String(probe.get("backend", "")) == "gpu.standard":
				break
		for i in range(4):
			await process_frame
		_save("user://graph_test/ui_gpu_backend.png")
	FxSettings.set_value("render.backend", prev_backend)
	FxRenderBroker.invalidate()

	# ---- 播放中：画面来自帧缓存，状态栏显示「帧 N 命中」 ----
	if render_svc != null and render_svc.has_method("set_playing"):
		render_svc.call("set_playing", true)
		for i in range(28):
			await process_frame
		_save("user://graph_test/ui_playback.png")
		render_svc.call("set_playing", false)

	# ---- 加载/保存进度浮层 ----
	shell.call("begin_progress", "打开工程 · 示范工程.fxproj")
	shell.call("set_progress", 2, 5, "解包素材 2/3")
	for i in range(5):
		await process_frame
	_save("user://graph_test/ui_progress.png")
	shell.call("end_progress", 0.05)

	# ---- 主窗口标题栏右键（系统菜单） ----
	shell.call("_popup_shell_window_menu")
	for i in range(4):
		await process_frame
	_save("user://graph_test/ui_shell_menu.png")
	_quit(0)


func _save(path: String) -> void:
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://graph_test")
	var err := image.save_png(path)
	print("截图：", ProjectSettings.globalize_path(path), " err=", err)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
