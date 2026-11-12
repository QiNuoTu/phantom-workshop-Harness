extends SceneTree
## 外壳视觉 / 窗口菜单 / 停靠容器 / 迁移自测。
## 运行：godot --headless --path . --script res://tests/test_shell_ui.gd

var failures: Array[String] = []
var shell: FxShell
const LAYOUT := "user://layout.cfg"


func _initialize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LAYOUT))
	print("== 外壳皮肤 / 窗口自测 ==")
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
	_test_skins()
	await _test_window_menu()
	await _test_dock_replacement()
	_test_migration()
	await _test_native_window()
	print("----")
	if failures.is_empty():
		print("外壳皮肤 / 窗口自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _test_skins() -> void:
	_check(FxPluginHost.skin_entries().size() >= 3, "皮肤作为插件贡献注册（%d 套）" % FxPluginHost.skin_entries().size())
	_check(FxPluginHost.dock_factory_entries().size() >= 1, "停靠容器工厂由插件贡献")
	var before := FxUiKit.ACCENT
	shell.call("_apply_skin", "light", false)
	_check(FxUiKit.current.id == "light", "选中浅色皮肤")
	_check(not FxUiKit.ACCENT.is_equal_approx(before), "换肤改变颜色 token")
	_check(FxUiKit.current.build_theme() is Theme, "皮肤能产出完整 Theme")
	_check(shell.theme != null, "外壳应用了新主题")
	shell.call("_apply_skin", "contrast", false)
	_check(FxUiKit.current.id == "contrast", "可切换到高对比皮肤")
	shell.call("_apply_skin", "default", false)
	_check(FxUiKit.current.id == "default", "停用皮肤插件时回落到默认皮肤")
	var ids: Array[String] = []
	for entry in FxPluginHost.skin_entries():
		ids.append(String(entry.get("id", "")))
	_check(ids.has("dark") and ids.has("light") and ids.has("contrast"), "三套皮肤 id 齐全")


func _test_window_menu() -> void:
	var has_window_menu := false
	for entry in FxRegistry.menus:
		if String(entry.get("id", "")) == "window":
			has_window_menu = true
	_check(has_window_menu, "顶部菜单包含独立的「窗口」菜单")
	var items: Array = shell.call("_window_items")
	var panels := 0
	var collapses := 0
	var skins := 0
	for raw in items:
		var item: Dictionary = raw
		if not String(item.get("panel", "")).is_empty():
			panels += 1
		if not String(item.get("collapse", "")).is_empty():
			collapses += 1
		if not String(item.get("skin", "")).is_empty():
			skins += 1
	_check(panels >= 5, "窗口菜单列出全部可关闭面板（%d 个）" % panels)
	_check(collapses == 3, "窗口菜单可折叠左/右/底三个区域（%d 个）" % collapses)
	_check(skins >= 4, "窗口菜单可切换皮肤（%d 项）" % skins)
	var all_checkable := true
	for raw2 in items:
		var item2: Dictionary = raw2
		if String(item2.get("panel", "")).is_empty() and String(item2.get("collapse", "")).is_empty():
			continue
		if not bool(item2.get("checkable", false)):
			all_checkable = false
	_check(all_checkable, "面板与折叠项都是可勾选状态")

	var bottom: FxDockArea = shell.dock_areas.get("bottom")
	_check(bottom != null, "底部停靠区存在")
	if bottom != null:
		bottom.set_collapsed(true)
		_check(bottom.is_collapsed(), "停靠区可折叠")
		var content: Control = bottom.get("_content") as Control
		_check(content != null and not content.visible, "折叠时内容区隐藏（面板实例保留）")
		_check(bottom.custom_minimum_size.y <= 30.0, "折叠时只占 30px 细条")
		_check(bottom.has_panel("editor.timeline"), "折叠不销毁面板")
		bottom.set_collapsed(false)
		_check(not bottom.is_collapsed(), "停靠区可展开")

		bottom.panel_close_requested.emit("editor.timeline")
		await process_frame
		await process_frame
		_check(not bottom.is_panel_visible("editor.timeline"), "标签上的 × 可关闭面板")
		shell.call("open_panel", "editor.timeline")
		_check(bottom.is_panel_visible("editor.timeline"), "窗口菜单能重新打开被关闭的面板")

	shell.call("_handle_layout_action", "layout.collapse_all")
	var left: FxDockArea = shell.dock_areas.get("left")
	var right: FxDockArea = shell.dock_areas.get("right")
	_check(left != null and left.is_collapsed() and right != null and right.is_collapsed(),
		"「全部折叠」作用于所有侧栏")
	shell.call("_handle_layout_action", "layout.expand_all")
	_check(left != null and not left.is_collapsed(), "「全部展开」恢复所有侧栏")
	_check(FileAccess.file_exists(LAYOUT), "布局（皮肤/折叠/显隐）持久化到 user://layout.cfg")
	var cfg := ConfigFile.new()
	cfg.load(LAYOUT)
	_check(cfg.has_section_key("skin", "id"), "布局文件记录当前皮肤")


func _test_dock_replacement() -> void:
	shell.set("_dock_style_id", "compact")
	shell.call("rebuild_ui")
	for i in range(4):
		await process_frame
	var left: FxDockArea = shell.dock_areas.get("left")
	_check(left is FxCompactDock, "停靠容器被插件工厂替换成自定义实现")
	_check(left != null and left.has_panel("editor.document"), "自定义停靠容器仍承载插件面板")
	shell.set("_dock_style_id", "default")
	shell.call("rebuild_ui")
	for i in range(4):
		await process_frame
	var left2: FxDockArea = shell.dock_areas.get("left")
	_check(left2 != null and not (left2 is FxCompactDock), "切回默认停靠容器")


func _test_migration() -> void:
	_check(not DirAccess.dir_exists_absolute("res://scripts/fx_core"), "scripts/fx_core 已清空并删除")
	_check(FileAccess.file_exists("res://plugins/core.recipe/vfx_engine.gd"), "VfxEngine 已搬进 core.recipe 插件")
	_check(not DirAccess.dir_exists_absolute("res://scripts/graph/core"),
		"graph/core 整个目录已下沉为插件，微内核不再持有图领域代码")
	_check(FileAccess.file_exists("res://plugins/core.graph/fx_tracks.gd"),
		"关键帧格式归入 core.graph 组件")
	_check(FileAccess.file_exists("res://plugins/core.render/fx_render_service.gd"),
		"渲染编排也下沉为 service 组件")
	_check(FxPluginHost.is_active("core.graph") and FxPluginHost.is_active("core.render"),
		"两个核心组件按依赖顺序激活")
	_check(FileAccess.file_exists("res://plugins/core.pixels/fx_image_util.gd"), "像素工具已插件化")
	_check(FxPluginHost.is_active("core.pixels"), "core.pixels 作为组件激活并提供显式依赖")
	var report := FxPluginHost.diagnostics()
	_check((report.get("missing", []) as Array).is_empty(), "迁移后没有缺失的供给键")
	_check(FxCatalog.has_def("image.recipe"), "配方节点仍可用（VfxEngine 全局类解析正常）")
	_check(FxPluginHost.is_active("core.image"), "图像插件对像素工具的依赖已满足")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


## 面板既能内嵌浮动，也能分离为真正的系统窗口（无头下 force_native 自动关闭）。
func _test_native_window() -> void:
	shell.call("detach_panel", "editor.timeline", true)
	for i in range(3):
		await process_frame
	_check(shell.is_panel_detached("editor.timeline"), "面板已分离为独立窗口")
	var win: Variant = shell.window_layer.window("native:panel:editor.timeline")
	_check(win is FxNativeWindow, "宿主是 FxNativeWindow（force_native 的系统窗口）")
	if win is FxNativeWindow:
		_check((win as FxNativeWindow).current_rect().size.x >= 360, "独立窗口有合理初始尺寸")
		_check(not (win as FxNativeWindow).unresizable, "独立窗口可自由拉伸")
	var cfg := ConfigFile.new()
	if cfg.load(LAYOUT) == OK:
		var native: Variant = cfg.get_value("floating", "native", [])
		_check(native is Array and (native as Array).has("editor.timeline"), "独立窗口形态写进布局")
	else:
		_check(false, "布局文件可读")
	shell.call("redock_panel", "editor.timeline")
	for i in range(3):
		await process_frame
	_check(not shell.is_panel_detached("editor.timeline"), "独立窗口能重新停靠")
	_check(shell.window_layer.window("native:panel:editor.timeline") == null, "关闭后窗口被释放")


func _quit(code: int = 0) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LAYOUT))
	FxPluginHost.shutdown()
	quit(code)
