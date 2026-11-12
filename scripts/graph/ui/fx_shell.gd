class_name FxShell
extends Control
## 应用外壳（基座）。
##
## 只做六件事：
##   1. 创建共享服务：文档上下文 FxDocumentStore、呈现器 FxRenderHost（由插件实现）；
##   2. 扫描插件，节点目录与算子经 FxGraphFacade 交给图能力实现；
##   3. 按插件贡献搭菜单栏、工具栏、四区停靠、状态栏；
##   4. 实例化插件注册的面板与窗口；
##   5. 维护命令表与快捷键（空格播放、Ctrl+Z 等由插件声明）；
##   6. 提供导出入口，格式本身仍由插件处理。
##
## 这里没有 GraphEdit、没有时间轴、没有预览、没有具体节点类型。
## 把 plugins/ 全部删掉，外壳仍然能启动，只是没有任何面板与节点。

## 皮肤切换后广播，插件可据此刷新自绘控件的颜色缓存。
signal skin_changed(skin_id: String)

const AREAS := ["left", "center", "right", "bottom"]
const LAYOUT_PATH := "user://layout.cfg"
const AREA_LABELS := {"left": "左侧", "center": "中央", "right": "右侧", "bottom": "底部"}

var store := FxDocumentStore.new()
## 呈现器：基座契约 + 插件实现。停用 core.render 时这里是一个空呈现器，
## 外壳照常启动（没有画面，但菜单、面板、快捷键全都还在）。
var render: FxRenderHost
var services: Dictionary = {}
var dock_areas: Dictionary = {}
var panel_controls: Dictionary = {}
var panel_specs: Dictionary = {}
var window_layer: FxWindowLayer

var _context: Dictionary = {}
var _backdrop: ColorRect
var _root: VBoxContainer
var _menu_bar: HBoxContainer
var _toolbar: HBoxContainer
var _toolbar_wrap: PanelContainer
var _status_label: Label
var _stats_label: Label
## 状态栏右端的常驻提示（保存状态之类），由插件通过 set_status_hint 填。
var _save_label: Label
## 启动进度条：只在启动期可见，结束后收起（控制台/启动日志里有完整时序）。
var _boot_bar: ProgressBar
## 启动页：插件与面板都还没搭好时就盖在最上面显示加载进度。
var _boot_splash: FxSplash
var _view_menu: PopupMenu
var _window_menu: PopupMenu
var _skin_id: String = "default"
var _dock_style_id: String = "default"
var _toolbar_mode: String = "compact"
var _collapsed_areas: Dictionary = {}
## 皮肤自定义选项：skin_id -> {key: value}（协议 v2，由图管线面板持久化）。
var _skin_options: Dictionary = {}
var _decoration: Control
var _overlay: Control
var _title_bar: PanelContainer
var _max_button: Button
var _frame: FxWindowFrame
var _dragging_window: bool = false
var _play_buttons: Array[Button] = []
var _syncing_play: bool = false
var _panel_visible: Dictionary = {}
var _shortcuts: Array[Dictionary] = []
var _service_nodes: Dictionary = {}
var _services_root: Node
var _export_menu: PopupMenu
var _export_file_dialog: FileDialog
var _export_dir_dialog: FileDialog
var _active_export: Dictionary = {}
var _reloading: bool = false
var _reconcile_pending: bool = false
var _settings_unsubscribe: Callable = Callable()
## 已分离成浮动窗口的面板：panel_id -> {window_id, spec}。
var _detached: Dictionary = {}
## window_id -> Rect2，自由布局持久化到 user://layout.cfg。
var _floating_geometry: Dictionary = {}
var _suppress_redock: Dictionary = {}
var _tearing_down: bool = false
var _restore_detached: Array[String] = []
## 布局里记下的「独立系统窗口」面板，重启后按同样形态恢复。
var _restore_native: Array[String] = []
var _message: String = "就绪"
## 通用进度浮层：谁做长活儿（打开/保存工程、导出）谁开它，基座只管画。
var _progress_layer: Control
var _progress_card: PanelContainer
var _progress_title: Label
var _progress_bar: ProgressBar
var _progress_step: Label
var _progress_hide_timer: Timer


func _ready() -> void:
	# 启动时序先开张：后面每一步都往这里报，界面/控制台/日志共享同一份进度。
	FxBoot.begin("启动")
	FxBoot.listen(Callable(self, "_on_boot_event"))
	FxBoot.expect(6)
	_boot_splash = FxSplash.install(self)
	# 让启动页真的画出来：后面几个大阶段之间各让出一帧。
	await get_tree().process_frame
	# 窗口可自由拉伸：给一个下限，避免拖到无法操作的尺寸；界面全部按容器自适应。
	var app_window := get_window()
	if app_window != null:
		app_window.min_size = Vector2i(960, 620)
	# 自绘标题栏：去掉系统边框，窗口拖动/缩放/最大化由外壳自己处理。
	if FxWindowFrame.window_available():
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	# 插件增量启停后由宿主回调这里做局部刷新，而不是拆掉整个工作台。
	FxPluginHost.set_reconcile_hook(Callable(self, "reconcile_plugins"))
	# 先注册插件（节点/算子/面板/皮肤/命令），再搭界面。
	FxPluginHost.ensure()
	FxGraphFacade.access().catalog_ensure()
	FxBoot.step("插件与节点目录")
	await get_tree().process_frame
	# 声明式配置：先加载磁盘取值，再推给能力代理，最后订阅双向绑定。
	FxSettings.ensure()
	FxSettings.apply_all()
	_settings_unsubscribe = FxSettings.subscribe(Callable(self, "_on_setting_changed"))
	FxBoot.step("配置与能力代理")
	_load_layout()
	_apply_skin(_skin_id, false)
	FxBoot.step("布局与皮肤")

	# 微内核不 new 任何领域服务：先搭好容器，再由插件贡献 services["render"]，
	# 外壳只从 services 表里取；插件没提供时才回落到最小内置实现。
	_build_layout()
	services["shell"] = self
	services["store"] = store
	_context = {"shell": self, "store": store, "render": null, "services": services}
	_instantiate_services()
	_install_render()
	FxBoot.step("插件服务与渲染后端")
	_build_dialogs()
	_instantiate_panels()
	_build_chrome()
	_apply_saved_collapse()
	FxBoot.step("面板、窗口与菜单")
	# 布局函数会重排子控件，把启动页重新提到最上层。
	if _boot_splash != null and is_instance_valid(_boot_splash):
		move_child(_boot_splash, get_child_count() - 1)
	await get_tree().process_frame
	_boot_document()
	FxBoot.step("示例文档")
	FxBoot.finish()
	if _boot_splash != null and is_instance_valid(_boot_splash):
		_boot_splash.finish()
	# 欢迎页由文档插件贡献命令，外壳不认识具体窗口实现。
	if OS.get_cmdline_user_args().has("--fx-diagnose"):
		pass
	else:
		run_command.call_deferred("project.welcome")

	if get_window() != null:
		get_window().title = FxI18n.text("幻像工坊 · 插件化工作台")
		get_window().min_size = Vector2i(1100, 680)
	# 打包后自检：幻像工坊.exe --headless -- --fx-diagnose
	if OS.get_cmdline_user_args().has("--fx-diagnose"):
		_diagnose.call_deferred()


## 输出「基座 + 插件」的完整装配清单，用于验证导出成 exe 后插件能力没有丢失。
func _diagnose() -> void:
	print("== 幻像工坊 · 装配诊断 ==")
	print("启动摘要：%s" % FxBoot.summary())
	print("启动日志：%s" % ProjectSettings.globalize_path(FxBoot.log_path()))
	if FxBoot.error_count() > 0:
		print("启动错误（%d）：" % FxBoot.error_count())
		for item in FxBoot.errors():
			print("  ✗ [%s] %s" % [String(item.get("where", "")), String(item.get("message", ""))])
	print("插件（%d）：" % FxRegistry.plugin_infos.size())
	for info in FxRegistry.plugin_infos:
		print("  - %s %s [%s]%s" % [
			String(info.get("id", "")), String(info.get("version", "")),
			String(info.get("root_label", "")),
			"（已停用）" if not bool(info.get("enabled", true)) else "",
		])
	print("节点定义 %d / 算子 %d / 参数控件 %d / 导出器 %d" % [
		FxGraphFacade.access().catalog_all().size(), FxOpRegistry.ids().size(),
		FxWidgetRegistry.kinds().size(), FxRegistry.exporters.size(),
	])
	print("面板 %d / 窗口 %d / 命令 %d / 菜单 %d / 服务 %d" % [
		FxRegistry.panels.size(), FxRegistry.windows.size(),
		FxRegistry.commands.size(), FxRegistry.menus.size(), FxRegistry.services.size(),
	])
	var skin_ids: Array[String] = []
	for skin_entry in FxPluginHost.skin_entries():
		skin_ids.append(String(skin_entry.get("id", "")))
	print("皮肤 %d %s / 停靠容器 %d / 当前皮肤 %s / 当前停靠 %s" % [
		skin_ids.size(), str(skin_ids), FxPluginHost.dock_factory_entries().size(),
		_skin_id, _dock_style_id,
	])
	print("设置项 %d / 能力键 %d / 质量策略 %d / 面板注入 %d / 语言包 %d" % [
		FxRegistry.settings.size(), FxCapabilities.keys().size(),
		FxRegistry.quality_policies.size(), FxRegistry.panel_features.size(),
		FxRegistry.locales.size(),
	])
	print("拖拽导入 %d 个：%s" % [FxDropBroker.entries().size(),
		", ".join(PackedStringArray(Array(FxDropBroker.provider_ids())))])
	print("质量策略：%s" % str(FxQualityPolicy.resolve({"playing": false})))
	# 启动诊断的领域行由插件自己生成：基座不读 render.cache 的任何内部字段。
	var diag_service: Variant = service("render")
	for entry in FxRegistry.status_fragments:
		var diag: Callable = entry.get("diagnostic", Callable())
		if not diag.is_valid():
			continue
		var line := String(diag.call(diag_service))
		if not line.is_empty():
			print(line)
	var skin_texture_count := 0
	for entry in FxPluginHost.skin_entries():
		var tex_root := String((entry as Dictionary).get("texture_root", ""))
		var tex_map: Variant = (entry as Dictionary).get("textures", {})
		if not tex_root.is_empty() and tex_map is Dictionary:
			skin_texture_count += FxSkinTextureLibrary.available(tex_root, tex_map)
	print("皮肤贴图 %d 张（外部资源根，不进 PCK）" % skin_texture_count)
	print("已实例化面板：%s" % ", ".join(PackedStringArray(Array(panel_controls.keys()))))
	var asset_roots := FxResourceRoot.existing_roots(FxAssetLibrary.ROOT_RELATIVE)
	print("素材根 %d：%s" % [asset_roots.size(), ", ".join(PackedStringArray(Array(asset_roots)))])
	FxAssetLibrary.ensure_loaded()
	print("pixelfx 素材 %d 套" % FxAssetLibrary.all().size())
	for root in FxPluginHost.roots():
		var root_path := String(root.get("path", ""))
		print("插件根 %s [%s] %s" % [
			root_path, String(root.get("label", "")),
			"存在" if DirAccess.dir_exists_absolute(root_path) else "不存在",
		])
	if not FxRegistry.errors.is_empty():
		print("插件错误：%s" % str(FxRegistry.errors))
	# 可选：跑一条命令，用于验证外部插件的实例 Callable 在导出后仍可用。
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fx-run="):
			var command_id := arg.trim_prefix("--fx-run=")
			var ok := run_command(command_id)
			print("命令 %s：%s" % [command_id, "执行成功" if ok else "未找到"])
	print("== 诊断结束 ==")
	get_tree().quit(0)


func _exit_tree() -> void:
	_save_layout()
	if _settings_unsubscribe.is_valid():
		_settings_unsubscribe.call()
		_settings_unsubscribe = Callable()
	FxPluginHost.shutdown()


## 声明式配置的「按字段协调」（§5.2.1）：
## runtime 只改渲染策略，ui 才重建面板，none 只落盘。
func _on_setting_changed(setting_id: String, _value: Variant, applies: String) -> void:
	if applies == "ui":
		rebuild_ui.call_deferred()
		return
	if applies != "runtime":
		return
	if render != null:
		render.apply_policy()
		render.invalidate()
	status("设置已更新：%s" % setting_id)


# ================= 皮肤 / 布局（可替换贡献） =================

func _load_layout() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(LAYOUT_PATH) != OK:
		return
	_skin_id = String(cfg.get_value("skin", "id", "default"))
	_dock_style_id = String(cfg.get_value("skin", "dock", "default"))
	_toolbar_mode = String(cfg.get_value("chrome", "toolbar", "compact"))
	var options: Variant = cfg.get_value("skin", "options", {})
	_skin_options = (options as Dictionary).duplicate(true) if options is Dictionary else {}
	var hidden: Variant = cfg.get_value("panels", "hidden", [])
	if hidden is Array:
		for panel_id in hidden:
			_panel_visible[String(panel_id)] = false
	var collapsed: Variant = cfg.get_value("panels", "collapsed_areas", [])
	if collapsed is Array:
		for area in collapsed:
			_collapsed_areas[String(area)] = true
	# 自由布局：位置是外部状态，用 coeffect 重化回 layout.cfg（§6.1）。
	var geometry: Variant = cfg.get_value("floating", "geometry", {})
	if geometry is Dictionary:
		for window_id in (geometry as Dictionary).keys():
			var raw: Variant = (geometry as Dictionary)[window_id]
			if raw is Array and (raw as Array).size() >= 4:
				_floating_geometry[String(window_id)] = Rect2(
					float((raw as Array)[0]), float((raw as Array)[1]),
					float((raw as Array)[2]), float((raw as Array)[3]))
	var detached: Variant = cfg.get_value("floating", "detached", [])
	if detached is Array:
		for panel_id in detached:
			_restore_detached.append(String(panel_id))
	var native: Variant = cfg.get_value("floating", "native", [])
	if native is Array:
		for panel_id2 in native:
			_restore_native.append(String(panel_id2))


func _save_layout() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("skin", "id", _skin_id)
	cfg.set_value("skin", "dock", _dock_style_id)
	cfg.set_value("skin", "options", _skin_options)
	cfg.set_value("chrome", "toolbar", _toolbar_mode)
	var hidden: Array[String] = []
	for panel_id in _panel_visible.keys():
		if not bool(_panel_visible[panel_id]):
			hidden.append(String(panel_id))
	cfg.set_value("panels", "hidden", hidden)
	var collapsed: Array[String] = []
	for area in _collapsed_areas.keys():
		if bool(_collapsed_areas[area]):
			collapsed.append(String(area))
	cfg.set_value("panels", "collapsed_areas", collapsed)
	var geometry: Dictionary = {}
	for window_id in _floating_geometry.keys():
		var rect: Rect2 = _floating_geometry[window_id]
		geometry[String(window_id)] = [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
	cfg.set_value("floating", "geometry", geometry)
	cfg.set_value("floating", "detached", detached_panel_ids())
	var native_ids: Array[String] = []
	for panel_id in _detached.keys():
		if bool((_detached[panel_id] as Dictionary).get("native", false)):
			native_ids.append(String(panel_id))
	cfg.set_value("floating", "native", native_ids)
	cfg.save(LAYOUT_PATH)


## 从插件注册表里挑一套皮肤并注入门面。找不到就回落到基座默认皮肤。
func _apply_skin(skin_id: String, rebuild: bool = true) -> void:
	var chosen: FxSkin = null
	for entry in FxPluginHost.skin_entries():
		if String(entry.get("id", "")) != skin_id:
			continue
		var factory: Callable = entry.get("factory", Callable())
		if not factory.is_valid():
			continue
		var made: Variant = factory.call()
		if made is FxSkin:
			chosen = made
		break
	if chosen == null:
		_skin_id = "default"
		chosen = FxSkin.new()
	else:
		_skin_id = skin_id
	FxUiKit.use(chosen)
	# 协议 v2：把该皮肤保存的选项交给皮肤自己解释，再同步回门面 token。
	chosen.apply_options(_skin_options.get(_skin_id, {}))
	FxUiKit.refresh()
	# 贴图从外部资源根加载（不进 PCK）：皮肤声明 texture_root + textures 映射，
	# 基座只负责解析与注入，完全不认识具体图片或它们的许可。
	var skin_entry := _skin_entry(_skin_id)
	var tex_root := String(skin_entry.get("texture_root", ""))
	var tex_manifest: Variant = skin_entry.get("textures", {})
	if not tex_root.is_empty() and tex_manifest is Dictionary:
		chosen.texture_root = tex_root
		chosen.set_textures(FxSkinTextureLibrary.load_set(tex_root, tex_manifest))
	theme = FxUiKit.build_theme()
	if is_instance_valid(_backdrop):
		_backdrop.color = FxUiKit.BG
	_apply_decoration(chosen)
	skin_changed.emit(_skin_id)
	_save_layout()
	if rebuild:
		rebuild_ui()


func _skin_entry(skin_id: String) -> Dictionary:
	for item in FxPluginHost.skin_entries():
		var entry: Dictionary = item
		if String(entry.get("id", "")) == skin_id:
			return entry
	return {}


func _apply_decoration(skin: FxSkin) -> void:
	for old in [_decoration, _overlay]:
		if is_instance_valid(old):
			remove_child(old)
			old.queue_free()
	_decoration = null
	_overlay = null
	# back 层：背景 / 立绘，夹在底板与面板之间，靠半透明面板透出。
	var decoration := skin.build_decoration()
	if decoration != null:
		decoration.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(decoration)
		decoration.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_decoration = decoration
	# front 层：花边 / 纹章 / 角饰，压在面板之上、浮动窗口之下。
	var overlay := skin.build_overlay()
	if overlay != null:
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(overlay)
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_overlay = overlay
	_order_layers()


## 固定层级：底板 → 背景装饰 → 主界面 → 前景装饰 → 服务节点 → 浮动窗口层。
func _order_layers() -> void:
	for node in [_backdrop, _decoration, _root, _overlay]:
		if is_instance_valid(node) and (node as Node).get_parent() == self:
			move_child(node, get_child_count() - 1)
	if is_instance_valid(window_layer):
		window_layer.move_to_front()


## 皮肤管理器入口：切换皮肤、读写选项都走这里，保证与「窗口」菜单同一路径。
func apply_skin(skin_id: String) -> void:
	_apply_skin(skin_id, true)


func skin_options(skin_id: String) -> Dictionary:
	return (_skin_options.get(skin_id, {}) as Dictionary).duplicate(true)


func set_skin_option(skin_id: String, key: String, value: Variant) -> void:
	if not _skin_options.has(skin_id):
		_skin_options[skin_id] = {}
	(_skin_options[skin_id] as Dictionary)[key] = value
	_save_layout()
	if _skin_id == skin_id:
		_apply_skin(_skin_id, true)


func reset_skin_options(skin_id: String) -> void:
	_skin_options.erase(skin_id)
	_save_layout()
	if _skin_id == skin_id:
		_apply_skin(_skin_id, true)


## 换肤只重建 UI，不重扫插件、不碰文档/撤销栈/服务实例。
func rebuild_ui() -> void:
	var visibility := _panel_visible.duplicate()
	# 换肤/改选项只重建面板层，浮动窗口（例如皮肤管理器自己）保持打开，
	# 否则表单控件会在自己的 value_changed 回调里被 queue_free。
	_teardown_ui(false, false)
	_build_layout()
	_instantiate_panels()
	_build_chrome()
	for panel_id in visibility.keys():
		if panel_specs.has(String(panel_id)):
			_panel_visible[String(panel_id)] = bool(visibility[panel_id])
	_apply_saved_visibility()
	_apply_saved_collapse()
	status("皮肤：%s" % FxUiKit.current.display_name)


## 命令入口：按顺序轮换可用皮肤（含基座默认皮肤）。
func cycle_skin() -> void:
	var ids: Array[String] = ["default"]
	for entry in FxPluginHost.skin_entries():
		var skin_id := String(entry.get("id", ""))
		if not skin_id.is_empty() and not ids.has(skin_id):
			ids.append(skin_id)
	var at := ids.find(_skin_id)
	_apply_skin(ids[(at + 1) % ids.size()])


func toggle_area(area: String) -> void:
	var dock: FxDockArea = dock_areas.get(area)
	if dock != null:
		dock.set_collapsed(not dock.is_collapsed())


func current_skin_id() -> String:
	return _skin_id


func current_dock_style() -> String:
	return _dock_style_id


## 选中的停靠容器工厂；插件没提供就用基座默认 FxDockArea。
func _dock_factory() -> Callable:
	for entry in FxPluginHost.dock_factory_entries():
		if String(entry.get("id", "")) == _dock_style_id:
			return entry.get("factory", Callable())
	return Callable()


# ================= 布局 =================

func _build_layout() -> void:
	# 窗口默认 clear color 是深灰；折叠停靠区后会露出来，浅色皮肤下很突兀。
	# 用一块跟随皮肤的底板兜住整个外壳。
	if _backdrop == null:
		_backdrop = ColorRect.new()
		_backdrop.name = "Backdrop"
		_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_backdrop)
		_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = FxUiKit.BG
	move_child(_backdrop, 0)
	if _root == null:
		_root = VBoxContainer.new()
		_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_root.add_theme_constant_override("separation", 0)
		add_child(_root)
	else:
		_clear_children(_root)

	_build_title_bar()

	var toolbar_wrap := PanelContainer.new()
	toolbar_wrap.add_theme_stylebox_override("panel", FxUiKit.chrome_style("toolbar"))
	_toolbar_wrap = toolbar_wrap
	_root.add_child(toolbar_wrap)
	var toolbar_margin := MarginContainer.new()
	toolbar_margin.add_theme_constant_override("margin_left", 8)
	toolbar_margin.add_theme_constant_override("margin_right", 8)
	toolbar_margin.add_theme_constant_override("margin_top", 4)
	toolbar_margin.add_theme_constant_override("margin_bottom", 4)
	toolbar_wrap.add_child(toolbar_margin)
	_toolbar = HBoxContainer.new()
	_toolbar.add_theme_constant_override("separation", 5)
	_toolbar.custom_minimum_size.y = 30
	toolbar_margin.add_child(_toolbar)

	var body := VSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(body)

	var top := HSplitContainer.new()
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(top)

	dock_areas.clear()
	dock_areas["left"] = _make_dock("left", Vector2(220, 0))
	dock_areas["center"] = _make_dock("center", Vector2(0, 0))
	dock_areas["right"] = _make_dock("right", Vector2(290, 0))
	top.add_child(dock_areas["left"])
	top.add_child(dock_areas["center"])
	top.add_child(dock_areas["right"])
	(dock_areas["center"] as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	(dock_areas["center"] as Control).size_flags_stretch_ratio = 2.2

	dock_areas["bottom"] = _make_dock("bottom", Vector2(0, 180))
	body.add_child(dock_areas["bottom"])

	var status_wrap := PanelContainer.new()
	var status_style := FxUiKit.chrome_style("status")
	if status_style is StyleBoxFlat:
		(status_style as StyleBoxFlat).border_width_top = 1
		(status_style as StyleBoxFlat).border_width_bottom = 0
		(status_style as StyleBoxFlat).border_width_left = 0
		(status_style as StyleBoxFlat).border_width_right = 0
	status_wrap.add_theme_stylebox_override("panel", status_style)
	_root.add_child(status_wrap)
	var status_margin := MarginContainer.new()
	status_margin.add_theme_constant_override("margin_left", 10)
	status_margin.add_theme_constant_override("margin_right", 10)
	status_margin.add_theme_constant_override("margin_top", 3)
	status_margin.add_theme_constant_override("margin_bottom", 3)
	status_wrap.add_child(status_margin)
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 12)
	status_margin.add_child(status_row)
	_status_label = FxUiKit.label(_message, 11, FxUiKit.MUTED)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_row.add_child(_status_label)
	_boot_bar = ProgressBar.new()
	_boot_bar.show_percentage = false
	_boot_bar.custom_minimum_size = Vector2(140, 6)
	_boot_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_boot_bar.visible = false
	_boot_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_row.add_child(_boot_bar)
	# 状态栏右端的常驻小字：谁在用谁填（文档插件填「已保存 / 有改动」）。
	# 基座不理解内容，只负责给它一个不抢眼的位置。
	_save_label = FxUiKit.label("", 11, FxUiKit.MUTED)
	_save_label.tooltip_text = ""
	status_row.add_child(_save_label)
	_stats_label = FxUiKit.label("", 11, FxUiKit.MUTED)
	status_row.add_child(_stats_label)

	if _services_root == null:
		_services_root = Node.new()
		_services_root.name = "PluginServices"
		add_child(_services_root)

	if window_layer == null:
		window_layer = FxWindowLayer.new()
		window_layer.name = "WindowLayer"
		add_child(window_layer)
	_connect_window_layer()
	_order_layers()
	if _frame != null and is_instance_valid(_frame):
		_frame.queue_free()
		_frame = null
	if FxWindowFrame.window_available():
		_frame = FxWindowFrame.install(self)


## 自绘标题栏：品牌名 + 菜单 + 窗口按钮，整条可拖动，双击最大化。
func _build_title_bar() -> void:
	_title_bar = PanelContainer.new()
	_title_bar.name = "TitleBar"
	_title_bar.custom_minimum_size.y = 34
	_title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_title_bar.add_theme_stylebox_override("panel", FxUiKit.chrome_style("title"))
	_title_bar.gui_input.connect(_on_title_bar_input)
	_root.add_child(_title_bar)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_bottom", 3)
	_title_bar.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)

	var brand := FxUiKit.label("◈", 14, FxUiKit.ACCENT)
	brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(brand)
	var brand_text := FxUiKit.strong(FxI18n.text("幻像工坊"), 12)
	brand_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(brand_text)
	row.add_child(FxUiKit.spacer(6))

	_menu_bar = HBoxContainer.new()
	_menu_bar.add_theme_constant_override("separation", 1)
	_menu_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_menu_bar)
	row.add_child(FxUiKit.spacer(0, true))

	if FxWindowFrame.window_available():
		var minimize := _window_button("−", FxI18n.text("最小化"))
		minimize.pressed.connect(func() -> void:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
		)
		row.add_child(minimize)
		_max_button = _window_button("□", FxI18n.text("最大化 / 还原"))
		_max_button.pressed.connect(toggle_window_maximize)
		row.add_child(_max_button)
		var close := _window_button("×", FxI18n.text("关闭"))
		close.add_theme_color_override("font_hover_color", FxUiKit.DANGER)
		close.pressed.connect(func() -> void:
			get_tree().quit()
		)
		row.add_child(close)
	_sync_max_button()


func _window_button(glyph: String, tooltip: String) -> Button:
	var button := FxUiKit.flat_button(glyph, tooltip, 13)
	button.custom_minimum_size = Vector2(34, 26)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return button


func _sync_max_button() -> void:
	if _max_button == null:
		return
	var maximized := FxWindowFrame.window_available() \
		and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED
	_max_button.text = "❐" if maximized else "□"


## 拖动标题栏移动窗口；双击最大化/还原。
func _on_title_bar_input(event: InputEvent) -> void:
	if not FxWindowFrame.window_available():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_popup_shell_window_menu()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed and mb.double_click:
			toggle_window_maximize()
			return
		_dragging_window = mb.pressed
		if mb.pressed and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED:
			# 最大化时拖动先还原，窗口跟随鼠标，手感接近系统标题栏。
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			_dragging_window = true
			_sync_max_button()
		return
	if event is InputEventMouseMotion and _dragging_window:
		DisplayServer.window_set_position(
			DisplayServer.window_get_position() + Vector2i((event as InputEventMouseMotion).relative))
		return
	if event is InputEventMouseButton and not (event as InputEventMouseButton).pressed:
		_dragging_window = false


## 主窗口标题栏右键 = 系统菜单。自绘标题栏之后系统菜单没了，这里补回来：
## 最小化 / 最大化 / 总在最前 / 关闭。
func _popup_shell_window_menu() -> void:
	if not FxWindowFrame.window_available() or _title_bar == null:
		return
	var on_top := DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP)
	var menu := PopupMenu.new()
	menu.add_item("🗕 最小化")
	menu.add_item("🗖 最大化 / 还原")
	menu.add_separator()
	menu.add_check_item("📌 总在最前", 0)
	menu.set_item_checked(2, on_top)
	menu.add_separator()
	menu.add_item("× 关闭")
	menu.id_pressed.connect(func(id: int) -> void:
		match id:
			0:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
			1:
				toggle_window_maximize()
			2:
				DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, not on_top)
			3:
				close_window_requested()
		menu.queue_free()
	)
	menu.close_requested.connect(menu.queue_free)
	_title_bar.add_child(menu)
	menu.position = DisplayServer.mouse_get_position()
	menu.reset_size()
	menu.popup()


## 关主窗口：先让插件有机会拦（未保存提示），再退出。
func close_window_requested() -> void:
	get_tree().quit()


func toggle_window_maximize() -> void:
	if not FxWindowFrame.window_available():
		return
	var maximized := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_WINDOWED if maximized else DisplayServer.WINDOW_MODE_MAXIMIZED)
	_sync_max_button()


func _connect_window_layer() -> void:
	if window_layer == null:
		return
	if not window_layer.window_closed.is_connected(_on_window_closed):
		window_layer.window_closed.connect(_on_window_closed)
	if not window_layer.window_geometry_changed.is_connected(_on_window_geometry_changed):
		window_layer.window_geometry_changed.connect(_on_window_geometry_changed)
	if not window_layer.window_redock_requested.is_connected(_on_window_redock_requested):
		window_layer.window_redock_requested.connect(_on_window_redock_requested)


func _make_dock(area: String, min_size: Vector2) -> FxDockArea:
	# 停靠容器本身也是插件可替换贡献；注册表里没有就用基座默认实现。
	var dock: FxDockArea = null
	var factory := _dock_factory()
	if factory.is_valid():
		var made: Variant = factory.call(area)
		if made is FxDockArea:
			dock = made
		elif made != null:
			push_warning("停靠容器工厂没有返回 FxDockArea：%s" % _dock_style_id)
	if dock == null:
		dock = FxDockArea.new(area)
	dock.configure(min_size, 2.2 if area == "center" else 1.0)
	# 底部只占最小高度，剩余空间全部给画布；左右栏同理不抢横向空间。
	if area == "bottom":
		dock.size_flags_vertical = Control.SIZE_FILL
	else:
		dock.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock.panel_focused.connect(_on_panel_focused)
	dock.panel_close_requested.connect(_on_panel_close_requested)
	dock.collapse_changed.connect(_on_dock_collapse_changed)
	dock.panel_detach_requested.connect(_on_panel_detach_requested)
	dock.panel_feature_requested.connect(_on_panel_feature_requested)
	# 「开成独立系统窗口」也走分离这条路，只是窗口形态换成 force_native。
	if dock.has_signal("panel_native_requested"):
		dock.connect("panel_native_requested",
			func(panel_id: String) -> void: detach_panel.call_deferred(panel_id, true))
	return dock


func _on_panel_close_requested(panel_id: String) -> void:
	# 延迟：按钮此刻正在派发 pressed，不能同步把它自己所在的面板隐藏。
	toggle_panel.call_deferred(panel_id, false)


# ================= 面板分离 / 自由布局 =================

func _on_panel_detach_requested(panel_id: String) -> void:
	detach_panel.call_deferred(panel_id)


func _on_panel_feature_requested(panel_id: String, command: String) -> void:
	if command.is_empty():
		return
	run_command(command, [panel_id])


func is_panel_detached(panel_id: String) -> bool:
	return _detached.has(panel_id)


func detached_panel_ids() -> Array[String]:
	var out: Array[String] = []
	for key in _detached.keys():
		out.append(String(key))
	out.sort()
	return out


## 面板 = 一个 Control 实例，停靠与浮动只是它的父节点不同；
## 分离不重建、不销毁，画布缩放/滚动/时间轴位置全部保留（避免 coarse-grained 重建）。
func detach_panel(panel_id: String, as_native: bool = false) -> void:
	if _detached.has(panel_id):
		var record: Dictionary = _detached[panel_id]
		var existing: Variant = window_layer.window(String(record.get("window_id", "")))
		if is_instance_valid(existing):
			existing.raise()
		if bool(record.get("native", false)) != as_native:
			status("该面板已分离；先重新停靠再换另一种窗口形态")
		return
	var spec: Dictionary = panel_specs.get(panel_id, {})
	if spec.is_empty() or window_layer == null:
		return
	var dock: FxDockArea = dock_areas.get(String(spec.get("area", "center")))
	var control: Control = dock.detach(panel_id) if dock != null else null
	if control == null:
		control = panel_controls.get(panel_id)
	if not is_instance_valid(control):
		return
	control.visible = true
	var window_id := ("native:panel:" if as_native else "panel:") + panel_id
	var size := Vector2i(520, 380)
	var raw: Variant = spec.get("min_size", null)
	if raw is Vector2:
		size = Vector2i(maxi(360, int((raw as Vector2).x)), maxi(240, int((raw as Vector2).y)))
	elif raw is Array and (raw as Array).size() >= 2:
		size = Vector2i(maxi(360, int((raw as Array)[0])), maxi(240, int((raw as Array)[1])))
	var title := FxI18n.text(String(spec.get("title", panel_id)))
	var window: Variant = window_layer.open_native(window_id, title, control, size) \
		if as_native else window_layer.open(window_id, title, control, size, true)
	if window != null and _floating_geometry.has(window_id):
		window.present_at(_floating_geometry[window_id] as Rect2)
	_detached[panel_id] = {"window_id": window_id, "spec": spec, "native": as_native}
	panel_controls[panel_id] = control
	_save_layout()
	_refresh_window_menu()
	status("面板已分离为%s：%s" % [
		"独立系统窗口" if as_native else "内嵌浮动窗口", title,
	])


func redock_panel(panel_id: String) -> void:
	if not _detached.has(panel_id):
		return
	var record: Dictionary = _detached[panel_id]
	var window_id := String(record.get("window_id", ""))
	var window: Variant = window_layer.window(window_id)
	var control: Control = window.release_content() if is_instance_valid(window) else null
	if control == null:
		control = panel_controls.get(panel_id)
	_suppress_redock[window_id] = true
	window_layer.close(window_id)
	_suppress_redock.erase(window_id)
	_detached.erase(panel_id)
	var spec: Dictionary = panel_specs.get(panel_id, record.get("spec", {}))
	var dock: FxDockArea = dock_areas.get(String(spec.get("area", "center")))
	if is_instance_valid(control) and dock != null:
		dock.add_panel(panel_id, FxI18n.text(String(spec.get("title", panel_id))), control,
			int(spec.get("order", 0)), bool(_panel_visible.get(panel_id, true)))
		panel_controls[panel_id] = control
	_save_layout()
	_refresh_window_menu()


func detach_all_panels() -> void:
	for panel_id in panel_controls.keys():
		detach_panel.call_deferred(String(panel_id))


func redock_all_panels() -> void:
	for panel_id in detached_panel_ids():
		redock_panel(panel_id)


func _on_window_closed(window_id: String) -> void:
	if _tearing_down or _suppress_redock.has(window_id):
		return
	for panel_id in _detached.keys():
		if String((_detached[panel_id] as Dictionary).get("window_id", "")) == window_id:
			redock_panel.call_deferred(String(panel_id))
			return


func _on_window_geometry_changed(window_id: String, rect: Rect2) -> void:
	_floating_geometry[window_id] = rect
	_save_layout()


func _on_window_redock_requested(window_id: String) -> void:
	for panel_id in _detached.keys():
		if String((_detached[panel_id] as Dictionary).get("window_id", "")) == window_id:
			redock_panel.call_deferred(String(panel_id))
			return
	close_window(window_id)


## 供插件查询：所有面板（含随软件发布的）都以同一份规格暴露，附带注入的功能。
func exposed_panels() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for spec in panel_specs.values():
		var entry: Dictionary = spec.duplicate(true)
		entry.erase("factory")
		var panel_id := String(entry.get("id", ""))
		entry["detached"] = _detached.has(panel_id)
		entry["visible"] = bool(_panel_visible.get(panel_id, true))
		entry["features"] = FxPanelBroker.features(panel_id)
		out.append(entry)
	return out


func panel_features(panel_id: String) -> Array[Dictionary]:
	return FxPanelBroker.features(panel_id)


func _on_dock_collapse_changed(area: String, value: bool) -> void:
	_collapsed_areas[area] = value
	_save_layout()
	_refresh_window_menu()


func _apply_saved_collapse() -> void:
	for area in AREAS:
		var dock: FxDockArea = dock_areas.get(area)
		if dock != null and area != "center":
			dock.set_collapsed(bool(_collapsed_areas.get(area, false)))


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


# ================= 菜单 / 工具栏 =================

func _build_chrome() -> void:
	_build_menus()
	_build_toolbar()
	_build_progress_overlay()
	_register_shortcuts()
	_update_play_buttons()


## 右下角的进度卡片：打开/保存工程这类要读好几个文件的活儿用它。
## 它只是一块画布，进度语义由调用方给（基座不认识「工程包」是什么）。
func _build_progress_overlay() -> void:
	if _progress_layer != null and is_instance_valid(_progress_layer):
		_progress_layer.queue_free()
	if _progress_hide_timer != null and is_instance_valid(_progress_hide_timer):
		_progress_hide_timer.queue_free()
	var layer := Control.new()
	layer.name = "ProgressLayer"
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layer)
	_progress_layer = layer

	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel",
		FxUiKit.panel_style(FxUiKit.PANEL, FxUiKit.BORDER, 6))
	card.visible = false
	layer.add_child(card)
	card.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	card.offset_left = -352.0
	card.offset_right = -16.0
	card.offset_top = -86.0
	card.offset_bottom = -34.0
	_progress_card = card

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	margin.add_child(box)
	_progress_title = FxUiKit.label("", 11, FxUiKit.TEXT)
	_progress_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_progress_title)
	_progress_bar = ProgressBar.new()
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(0, 8)
	_progress_bar.max_value = 1.0
	box.add_child(_progress_bar)
	_progress_step = FxUiKit.label("", 10, FxUiKit.MUTED)
	_progress_step.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_progress_step)

	_progress_hide_timer = Timer.new()
	_progress_hide_timer.one_shot = true
	_progress_hide_timer.timeout.connect(func() -> void:
		if _progress_card != null and is_instance_valid(_progress_card):
			_progress_card.visible = false
	)
	add_child(_progress_hide_timer)


## 开始一段长任务：卡片出现，标题写清在做什么。
func begin_progress(title: String) -> void:
	if _progress_card == null or not is_instance_valid(_progress_card):
		return
	if _progress_hide_timer != null:
		_progress_hide_timer.stop()
	_progress_card.visible = true
	_progress_title.text = title
	_progress_bar.max_value = 1.0
	_progress_bar.value = 0.0
	_progress_step.text = ""


## 上报一步。total <= 0 时按「不确定进度」显示（来回扫的那条）。
func set_progress(done: int, total: int, label: String = "") -> void:
	if _progress_card == null or not is_instance_valid(_progress_card):
		return
	_progress_card.visible = true
	if total <= 0:
		_progress_bar.max_value = 1.0
		_progress_bar.value = 0.35
	else:
		_progress_bar.max_value = float(total)
		_progress_bar.value = clampf(float(done), 0.0, float(total))
	if not label.is_empty():
		_progress_step.text = "%d/%d · %s" % [done, total, label] if total > 0 else label


## 结束：填满进度条，稍等一会儿再收起（让人看清「做完了」）。
func end_progress(keep_seconds: float = 0.45) -> void:
	if _progress_card == null or not is_instance_valid(_progress_card):
		return
	_progress_bar.value = _progress_bar.max_value
	if _progress_hide_timer == null:
		_progress_card.visible = false
		return
	_progress_hide_timer.start(maxf(keep_seconds, 0.05))


func progress_active() -> bool:
	return _progress_card != null and is_instance_valid(_progress_card) and _progress_card.visible


func progress_title() -> String:
	return _progress_title.text if _progress_title != null else ""


func progress_ratio() -> float:
	if _progress_bar == null or _progress_bar.max_value <= 0.0:
		return 0.0
	return _progress_bar.value / _progress_bar.max_value


func _build_menus() -> void:
	if _menu_bar == null:
		return
	_clear_children(_menu_bar)
	_view_menu = null
	_window_menu = null
	var defs: Array[Dictionary] = []
	var seen: Dictionary = {}
	for item in FxPluginHost.menu_entries():
		var def: Dictionary = item
		var mid := String(def.get("id", ""))
		if mid.is_empty() or seen.has(mid):
			continue
		seen[mid] = true
		defs.append(def)
	if not seen.has("view"):
		defs.append({"id": "view", "title": "视图", "order": 40})
	# 「窗口」是基座保证存在的菜单：面板显隐、停靠区折叠、皮肤都归它管。
	if not seen.has("window"):
		defs.append({"id": "window", "title": "窗口", "order": 45})
	defs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0))
	)
	for def in defs:
		var menu_id := String(def.get("id", ""))
		var button := MenuButton.new()
		button.text = FxI18n.text(String(def.get("title", menu_id)))
		button.flat = false
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(0, 26)
		button.add_theme_font_size_override("font_size", 12)
		button.add_theme_stylebox_override("normal", FxUiKit.tab_style(false))
		button.add_theme_stylebox_override("hover", FxUiKit.tab_style(false, true))
		button.add_theme_stylebox_override("pressed", FxUiKit.tab_style(true))
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.add_theme_color_override("font_color", FxUiKit.TEXT)
		button.add_theme_color_override("font_hover_color", FxUiKit.TEXT_STRONG)
		button.add_theme_color_override("font_pressed_color", FxUiKit.ACCENT)
		var popup := button.get_popup()
		popup.add_theme_font_size_override("font_size", 12)
		var items: Array[Dictionary] = []
		for item in FxPluginHost.menu_item_entries():
			var entry: Dictionary = item
			if String(entry.get("menu", "")) == menu_id:
				items.append(entry)
		# 面板注入功能也能声明 menu：插件不必认识菜单实现就能往任意菜单加项。
		for feature in FxPanelBroker.all_features():
			if String(feature.get("menu", "")) != menu_id:
				continue
			var label := String(feature.get("label", ""))
			if label.is_empty():
				continue
			items.append({
				"label": label, "command": String(feature.get("command", "")),
				"order": int(feature.get("order", 0)),
			})
		if menu_id == "view":
			items.append_array(_view_items())
		if menu_id == "window":
			items.append_array(_window_items())
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("order", 0)) < int(b.get("order", 0))
		)
		var added := 0
		for item in items:
			if bool(item.get("separator", false)) and added > 0:
				popup.add_separator()
			# 空 label 且没有命令 = 纯分隔项；有 label 的 separator 只是“前面加一条线”。
			if String(item.get("label", "")).is_empty() and String(item.get("command", "")).is_empty():
				continue
			var checkable := bool(item.get("checkable", false))
			if checkable:
				popup.add_check_item(FxI18n.text(String(item.get("label", ""))))
			else:
				popup.add_item(FxI18n.text(String(item.get("label", ""))))
			var index := popup.item_count - 1
			if checkable:
				popup.set_item_checked(index, bool(item.get("checked", false)))
			popup.set_item_metadata(index, {
				"panel": String(item.get("panel", "")),
				"command": String(item.get("command", "")),
				"collapse": String(item.get("collapse", "")),
				"action": String(item.get("action", "")),
				"skin": String(item.get("skin", "")),
				"dock": String(item.get("dock", "")),
				"checkable": checkable,
				"toolbar": String(item.get("toolbar", "")),
			})
			var shortcut := _parse_shortcut(String(item.get("shortcut", "")))
			if not shortcut.is_empty():
				popup.set_item_accelerator(index, int(shortcut["keycode"]) | int(shortcut["mask"]))
			added += 1
		popup.id_pressed.connect(_on_menu_pressed.bind(popup))
		_menu_bar.add_child(button)
		if menu_id == "view":
			_view_menu = popup
		if menu_id == "window":
			_window_menu = popup


func _view_items() -> Array[Dictionary]:
	return [{"label": "重置布局", "command": "view.reset", "order": 900}]


## 「窗口」菜单：面板显隐、停靠区折叠、皮肤与停靠样式都是可勾选/可切换的。
func _window_items() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var order := 100
	var specs: Array[Dictionary] = []
	for spec in panel_specs.values():
		specs.append(spec)
	specs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0))
	)
	for spec in specs:
		var panel_id := String(spec.get("id", ""))
		items.append({
			"label": String(spec.get("title", panel_id)), "panel": panel_id,
			"checkable": true, "checked": bool(_panel_visible.get(panel_id, true)),
			"order": order,
		})
		order += 1
	items.append({"label": "", "separator": true, "order": 200})
	for spec2 in specs:
		var pid := String(spec2.get("id", ""))
		var floating := _detached.has(pid)
		items.append({
			"label": (FxI18n.text("⤓ 停靠") if floating else FxI18n.text("⧉ 分离")) + " · " + FxI18n.text(String(spec2.get("title", pid))),
			"action": "panel.redock:" + pid if floating else "panel.detach:" + pid,
			"order": 210,
		})
		if not floating:
			items.append({
				"label": FxI18n.text("▣ 分离为独立窗口") + " · " + FxI18n.text(String(spec2.get("title", pid))),
				"action": "panel.detach_native:" + pid, "order": 211,
			})
	for window_spec in FxPluginHost.window_entries():
		var wid := String((window_spec as Dictionary).get("id", ""))
		if wid.is_empty():
			continue
		items.append({
			"label": FxI18n.text("▣ 独立窗口") + " · " + FxI18n.text(String((window_spec as Dictionary).get("title", wid))),
			"action": "window.native:" + wid, "order": 212,
		})
	items.append({"label": "全部重新停靠", "action": "panel.redock_all", "order": 260})
	items.append({"label": "", "separator": true, "order": 280})
	for area in AREAS:
		if area == "center":
			continue
		items.append({
			"label": FxI18n.text("折叠") + FxI18n.text(String(AREA_LABELS.get(area, area))), "collapse": area,
			"checkable": true, "checked": bool(_collapsed_areas.get(area, false)),
			"order": 300,
		})
	items.append({"label": "全部展开", "action": "layout.expand_all", "order": 380})
	items.append({"label": "全部折叠", "action": "layout.collapse_all", "order": 381})
	items.append({"label": "", "separator": true, "order": 385})
	items.append({
		"label": FxI18n.text("工具栏") + " · " + FxI18n.text("精简"), "toolbar": "compact",
		"checkable": true, "checked": _toolbar_mode == "compact", "order": 386,
	})
	items.append({
		"label": FxI18n.text("工具栏") + " · " + FxI18n.text("完整"), "toolbar": "full",
		"checkable": true, "checked": _toolbar_mode == "full", "order": 387,
	})
	items.append({
		"label": FxI18n.text("工具栏") + " · " + FxI18n.text("隐藏"), "toolbar": "hidden",
		"checkable": true, "checked": _toolbar_mode == "hidden", "order": 388,
	})
	items.append({"label": "", "separator": true, "order": 390})

	items.append({
		"label": FxI18n.text("皮肤") + " · " + FxI18n.text("默认深色"), "skin": "default",
		"checkable": true, "checked": _skin_id == "default", "order": 400,
	})
	for entry in FxPluginHost.skin_entries():
		var skin_id := String(entry.get("id", ""))
		if skin_id.is_empty():
			continue
		items.append({
			"label": FxI18n.text("皮肤") + " · " + String(entry.get("name", skin_id)), "skin": skin_id,
			"checkable": true, "checked": _skin_id == skin_id, "order": 401,
		})
	items.append({"label": "", "separator": true, "order": 490})
	items.append({
		"label": FxI18n.text("停靠样式") + " · " + FxI18n.text("默认"), "dock": "default",
		"checkable": true, "checked": _dock_style_id == "default", "order": 500,
	})
	for entry2 in FxPluginHost.dock_factory_entries():
		var dock_id := String(entry2.get("id", ""))
		if dock_id.is_empty():
			continue
		items.append({
			"label": FxI18n.text("停靠样式") + " · " + String(entry2.get("name", dock_id)), "dock": dock_id,
			"checkable": true, "checked": _dock_style_id == dock_id, "order": 501,
		})
	items.append({"label": "", "separator": true, "order": 890})
	items.append({"label": "重置布局", "command": "view.reset", "order": 900})
	return items


func _refresh_window_menu() -> void:
	if _window_menu == null:
		return
	for index in range(_window_menu.item_count):
		var meta: Variant = _window_menu.get_item_metadata(index)
		if not meta is Dictionary:
			continue
		var data: Dictionary = meta
		var checked := false
		if not String(data.get("panel", "")).is_empty():
			checked = bool(_panel_visible.get(String(data["panel"]), true))
		elif not String(data.get("collapse", "")).is_empty():
			checked = bool(_collapsed_areas.get(String(data["collapse"]), false))
		elif not String(data.get("skin", "")).is_empty():
			checked = String(data["skin"]) == _skin_id
		elif not String(data.get("dock", "")).is_empty():
			checked = String(data["dock"]) == _dock_style_id
		elif not String(data.get("toolbar", "")).is_empty():
			checked = String(data["toolbar"]) == _toolbar_mode
		else:
			continue
		_window_menu.set_item_checked(index, checked)


func _handle_layout_action(action: String) -> void:
	if action.begins_with("panel.detach_native:"):
		detach_panel.call_deferred(action.trim_prefix("panel.detach_native:"), true)
		return
	if action.begins_with("window.native:"):
		open_window_native.call_deferred(action.trim_prefix("window.native:"))
		return
	if action.begins_with("panel.detach:"):
		detach_panel.call_deferred(action.trim_prefix("panel.detach:"))
		return
	if action.begins_with("panel.redock:"):
		redock_panel(action.trim_prefix("panel.redock:"))
		return
	if action == "panel.redock_all":
		redock_all_panels()
		return
	match action:
		"layout.expand_all":
			for panel_id in panel_specs.keys():
				_panel_visible[String(panel_id)] = true
			_collapsed_areas.clear()
		"layout.collapse_all":
			for area in AREAS:
				if area != "center":
					_collapsed_areas[area] = true
		_:
			return
	_apply_saved_visibility()
	_apply_saved_collapse()
	_save_layout()
	_refresh_window_menu()


func _on_menu_pressed(id: int, popup: PopupMenu) -> void:
	var meta: Variant = popup.get_item_metadata(id)
	if not meta is Dictionary:
		return
	var data: Dictionary = meta
	var panel_id := String(data.get("panel", ""))
	if not panel_id.is_empty():
		toggle_panel(panel_id)
		return
	var collapse := String(data.get("collapse", ""))
	if not collapse.is_empty():
		var dock: FxDockArea = dock_areas.get(collapse)
		if dock != null:
			dock.set_collapsed(not dock.is_collapsed())
		return
	var skin_id := String(data.get("skin", ""))
	if not skin_id.is_empty():
		_apply_skin(skin_id)
		return
	var dock_id := String(data.get("dock", ""))
	if not dock_id.is_empty():
		_dock_style_id = dock_id
		_save_layout()
		rebuild_ui()
		return
	var toolbar_mode := String(data.get("toolbar", ""))
	if not toolbar_mode.is_empty():
		set_toolbar_mode(toolbar_mode)
		return
	var action := String(data.get("action", ""))
	if not action.is_empty():
		_handle_layout_action(action)
		return
	var command := String(data.get("command", ""))
	if not command.is_empty():
		run_command(command)


func _build_toolbar() -> void:
	if _toolbar == null:
		return
	_clear_children(_toolbar)
	_play_buttons.clear()
	if is_instance_valid(_toolbar_wrap):
		_toolbar_wrap.visible = _toolbar_mode != "hidden"
	if _toolbar_mode == "hidden":
		return
	var entries: Array[Dictionary] = []
	for item in FxPluginHost.toolbar_entries():
		# 精简模式只留插件显式标记 quick 的项；菜单仍是完整功能入口，
		# 避免「文件/编辑/节点/播放」在菜单和工具栏里各点一遍。
		if _toolbar_mode == "compact" and not bool(item.get("quick", false)):
			continue
		entries.append(item)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0))
	)
	var last_was_separator := true
	for entry in entries:
		if bool(entry.get("separator", false)):
			if not last_was_separator:
				_toolbar.add_child(VSeparator.new())
				last_was_separator = true
		var label := String(entry.get("label", ""))
		var command := String(entry.get("command", ""))
		if label.is_empty() and command.is_empty() and String(entry.get("menu", "")).is_empty():
			continue
		var button := FxUiKit.button(label, 12, 26)
		button.tooltip_text = String(entry.get("tooltip", ""))
		var shortcut := _parse_shortcut(String(entry.get("shortcut", "")))
		if not shortcut.is_empty() and button.tooltip_text.is_empty():
			button.tooltip_text = _shortcut_text(shortcut)
		if String(entry.get("menu", "")) == "exporters":
			button.pressed.connect(func() -> void: _popup_exporters(button))
		elif bool(entry.get("toggle", false)):
			button.toggle_mode = true
			button.toggled.connect(func(pressed: bool) -> void:
				if _syncing_play:
					return
				if pressed != render.playing:
					run_command(command)
			)
			_play_buttons.append(button)
		else:
			button.pressed.connect(func() -> void: run_command(command))
		_toolbar.add_child(button)
		last_was_separator = false
	_toolbar.add_child(FxUiKit.spacer(0, true))
	_update_play_buttons()


func set_toolbar_mode(mode: String) -> void:
	if mode != "compact" and mode != "full" and mode != "hidden":
		return
	_toolbar_mode = mode
	_build_toolbar()
	_save_layout()
	_refresh_window_menu()


func toolbar_mode() -> String:
	return _toolbar_mode


func _update_play_buttons() -> void:
	_syncing_play = true
	for button in _play_buttons:
		if not is_instance_valid(button):
			continue
		button.set_pressed_no_signal(render.playing)
		button.text = FxI18n.text("暂停") if render.playing else FxI18n.text("播放")
	_syncing_play = false


func _on_playback_changed(_playing: bool) -> void:
	_update_play_buttons()


# ================= 命令 / 快捷键 =================

func _register_shortcuts() -> void:
	_shortcuts.clear()
	for item in FxPluginHost.command_entries():
		var entry: Dictionary = item
		var parsed := _parse_shortcut(String(entry.get("shortcut", "")))
		if parsed.is_empty():
			continue
		parsed["command"] = String(entry.get("id", ""))
		_shortcuts.append(parsed)


func command_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item in FxPluginHost.command_entries():
		out.append(item)
	return out


func run_command(id: String, args: Array = []) -> bool:
	var entry := _command_entry(id)
	if entry.is_empty():
		status("未知命令：%s" % id)
		return false
	var handler: Callable = entry.get("handler", Callable())
	if not handler.is_valid():
		status("命令没有处理函数：%s" % id)
		return false
	var ctx := _context.duplicate()
	ctx["args"] = args
	handler.call(ctx)
	return true


func _command_entry(id: String) -> Dictionary:
	if id == "view.reset":
		return {
			"id": "view.reset",
			"label": "重置布局",
			"handler": Callable(self, "reset_layout"),
		}
	for item in FxPluginHost.command_entries():
		var entry: Dictionary = item
		if String(entry.get("id", "")) == id:
			return entry
	return {}


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	var editing := focus is LineEdit or focus is TextEdit
	for shortcut in _shortcuts:
		if key.keycode != int(shortcut.get("keycode", 0)):
			continue
		var mask := int(shortcut.get("mask", 0))
		var need_ctrl := (mask & KEY_MASK_CTRL) != 0 or (mask & KEY_MASK_META) != 0
		if key.ctrl_pressed != need_ctrl:
			continue
		if key.shift_pressed != ((mask & KEY_MASK_SHIFT) != 0):
			continue
		if key.alt_pressed != ((mask & KEY_MASK_ALT) != 0):
			continue
		if editing:
			continue
		if key.keycode == KEY_SPACE and focus is BaseButton:
			continue
		run_command(String(shortcut.get("command", "")))
		get_viewport().set_input_as_handled()
		return


func _parse_shortcut(spec: String) -> Dictionary:
	var text := spec.strip_edges()
	if text.is_empty():
		return {}
	var parts := text.split("+", false)
	if parts.is_empty():
		return {}
	var key_name := String(parts[parts.size() - 1]).strip_edges()
	var keycode := OS.find_keycode_from_string(key_name)
	if keycode == KEY_NONE:
		match key_name.to_upper():
			"SPACE":
				keycode = KEY_SPACE
			"DELETE":
				keycode = KEY_DELETE
			"ESCAPE", "ESC":
				keycode = KEY_ESCAPE
			"ENTER", "RETURN":
				keycode = KEY_ENTER
			"TAB":
				keycode = KEY_TAB
			"F1":
				keycode = KEY_F1
			"F2":
				keycode = KEY_F2
			"F5":
				keycode = KEY_F5
	if keycode == KEY_NONE:
		return {}
	var mask := 0
	for i in range(parts.size() - 1):
		match String(parts[i]).strip_edges().to_lower():
			"ctrl", "control":
				mask |= KEY_MASK_CTRL
			"shift":
				mask |= KEY_MASK_SHIFT
			"alt":
				mask |= KEY_MASK_ALT
			"meta", "cmd", "command":
				mask |= KEY_MASK_META
	return {"keycode": keycode, "mask": mask}


func _shortcut_text(parsed: Dictionary) -> String:
	var keycode := int(parsed.get("keycode", 0))
	var mask := int(parsed.get("mask", 0))
	var name := OS.get_keycode_string(keycode)
	if name.is_empty():
		name = "?"
	var prefix := ""
	if (mask & KEY_MASK_CTRL) != 0 or (mask & KEY_MASK_META) != 0:
		prefix += "Ctrl+"
	if (mask & KEY_MASK_SHIFT) != 0:
		prefix += "Shift+"
	if (mask & KEY_MASK_ALT) != 0:
		prefix += "Alt+"
	return prefix + name


# ================= 服务 =================

func _instantiate_services() -> void:
	if _services_root == null:
		return
	for child in _services_root.get_children():
		_services_root.remove_child(child)
		child.queue_free()
	_service_nodes.clear()
	var factories := FxPluginHost.service_factories()
	_create_services(factories)


func _create_services(factories: Dictionary) -> void:
	var ids: Array = factories.keys()
	ids.sort()
	for raw_id in ids:
		var id := String(raw_id)
		if services.has(id) and id != "shell" and id != "store" and id != "render":
			continue
		var factory: Callable = factories[raw_id]
		var value: Variant = factory.call(_context)
		if value == null:
			continue
		if value is Node:
			_services_root.add_child(value)
			if (value as Node).name.is_empty():
				(value as Node).name = "svc_" + id.replace(".", "_")
			_service_nodes[id] = value
		services[id] = value


## 增量对齐服务表：只撤走消失的、只新建新增的，其余服务保持原状。
func _reconcile_services() -> void:
	var factories := FxPluginHost.service_factories()
	for id in _service_nodes.keys():
		if not factories.has(id):
			var node: Node = _service_nodes[id]
			if is_instance_valid(node):
				_services_root.remove_child(node)
				node.queue_free()
			_service_nodes.erase(id)
			services.erase(id)
	_create_services(factories)
	_install_render()


## 从 services 表取呈现器；插件停用/切换时重新对齐，缺失则用基座空实现兜底。
## 注意兜底的是**基座契约**（FxRenderHost），不是某个插件的类 ——
## 插件目录删掉之后基座仍要能编译、能启动，这是微内核的底线。
func _install_render() -> void:
	var made: Variant = services.get("render")
	if made is FxRenderHost and is_instance_valid(made):
		render = made
	else:
		render = FxRenderHost.new()
		render.name = "RenderPlaceholder"
		_services_root.add_child(render)
		services["render"] = render
		_service_nodes["render"] = render
	if _context.has("render"):
		_context["render"] = render
	if render.store == null:
		render.setup(store)
	if not render.playback_changed.is_connected(_on_playback_changed):
		render.playback_changed.connect(_on_playback_changed)
	if not render.stats_changed.is_connected(_on_stats_changed):
		render.stats_changed.connect(_on_stats_changed)


func provide(id: String, value: Variant) -> void:
	services[id] = value


func service(id: String) -> Variant:
	return services.get(id)


# ================= 面板 / 窗口 =================

func _instantiate_panels() -> void:
	for area in AREAS:
		var dock: FxDockArea = dock_areas.get(area)
		if dock != null:
			dock.clear_all()
	panel_controls.clear()
	panel_specs.clear()

	var specs: Array[Dictionary] = []
	for item in FxPluginHost.panel_entries():
		specs.append(item)
	specs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0))
	)
	for spec in specs:
		var panel_id := String(spec.get("id", ""))
		# 已分离的面板不该被重新实例化：它此刻正挂在浮动窗口里。
		if _detached.has(panel_id):
			panel_specs[panel_id] = spec
			_panel_visible[panel_id] = not bool(spec.get("hidden", false))
			continue
		var area := String(spec.get("area", "center"))
		if not dock_areas.has(area):
			area = "center"
		var factory: Callable = spec.get("factory", Callable())
		if panel_id.is_empty() or not factory.is_valid():
			continue
		var control: Variant = factory.call(_context)
		if not control is Control:
			push_warning("面板工厂没有返回 Control：%s" % panel_id)
			continue
		var dock: FxDockArea = dock_areas[area]
		var hidden := bool(spec.get("hidden", false))
		dock.add_panel(panel_id, FxI18n.text(String(spec.get("title", panel_id))), control,
			int(spec.get("order", 0)), not hidden)
		panel_controls[panel_id] = control
		panel_specs[panel_id] = spec
		_panel_visible[panel_id] = not hidden

	_apply_saved_visibility()
	_refresh_view_menu()
	_restore_floating()


func _restore_floating() -> void:
	if _restore_detached.is_empty():
		return
	var ids := _restore_detached.duplicate()
	_restore_detached.clear()
	for panel_id in ids:
		if panel_specs.has(panel_id):
			detach_panel.call_deferred(panel_id, _restore_native.has(panel_id))
	_restore_native.clear()
## 只增删变化的面板/服务/窗口，其余面板连同它们的滚动位置、选中状态一律保留。
## 这与 reload_plugins() 的「全量拆掉重搭」是两条不同的路径。
func reconcile_plugins() -> void:
	if _reloading or _reconcile_pending:
		return
	# 延迟到下一帧：停用 editor.plugins 时，删除面板的动作不能发生在它自己的
	# CheckBox.toggled 回调里（会在信号派发中释放发射者）。
	_reconcile_pending = true
	_do_reconcile.call_deferred()


func _do_reconcile() -> void:
	_reconcile_pending = false
	if _reloading or not is_inside_tree():
		return
	var specs: Array[Dictionary] = []
	var desired: Dictionary = {}
	for item in FxPluginHost.panel_entries():
		var panel_id := String(item.get("id", ""))
		if panel_id.is_empty() or desired.has(panel_id):
			continue
		desired[panel_id] = item
		specs.append(item)

	for existing_id in panel_controls.keys():
		if desired.has(existing_id):
			continue
		if _detached.has(existing_id):
			var window_id := String((_detached[existing_id] as Dictionary).get("window_id", ""))
			_suppress_redock[window_id] = true
			window_layer.close(window_id)
			_suppress_redock.erase(window_id)
			_detached.erase(existing_id)
		var old_spec: Dictionary = panel_specs.get(existing_id, {})
		var old_dock: FxDockArea = dock_areas.get(String(old_spec.get("area", "center")))
		if old_dock != null and old_dock.has_panel(String(existing_id)):
			old_dock.remove_panel(String(existing_id))
		panel_controls.erase(existing_id)
		panel_specs.erase(existing_id)
		_panel_visible.erase(existing_id)

	specs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0))
	)
	for spec in specs:
		var panel_id := String(spec.get("id", ""))
		if panel_controls.has(panel_id):
			continue
		var area := String(spec.get("area", "center"))
		if not dock_areas.has(area):
			area = "center"
		var factory: Callable = spec.get("factory", Callable())
		if not factory.is_valid():
			continue
		var control: Variant = factory.call(_context)
		if not control is Control:
			continue
		var dock: FxDockArea = dock_areas[area]
		var hidden := bool(spec.get("hidden", false))
		dock.add_panel(panel_id, FxI18n.text(String(spec.get("title", panel_id))), control,
			int(spec.get("order", 0)), not hidden)
		panel_controls[panel_id] = control
		panel_specs[panel_id] = spec
		_panel_visible[panel_id] = not hidden

	var live_windows: Dictionary = {}
	for entry in FxRegistry.windows:
		live_windows[String(entry.get("id", ""))] = true
	if window_layer != null:
		for window_id in window_layer.open_ids():
			if not live_windows.has(window_id):
				window_layer.close(window_id)

	_reconcile_services()
	_build_chrome()
	_apply_saved_visibility()
	status(FxPluginHost.summary())


func _apply_saved_visibility() -> void:
	for panel_id in panel_specs.keys():
		var dock: FxDockArea = dock_areas.get(String((panel_specs[panel_id] as Dictionary).get("area", "center")))
		if dock == null:
			continue
		var want := bool(_panel_visible.get(panel_id, true))
		dock.set_panel_visible(String(panel_id), want)
	_refresh_view_menu()


func panel(panel_id: String) -> Control:
	return panel_controls.get(panel_id)


func open_panel(panel_id: String) -> void:
	var spec: Dictionary = panel_specs.get(panel_id, {})
	if spec.is_empty():
		status("没有这个面板：%s" % panel_id)
		return
	if _detached.has(panel_id):
		var floating: Variant = window_layer.window(String((_detached[panel_id] as Dictionary).get("window_id", "")))
		if is_instance_valid(floating):
			floating.raise()
		return
	var dock: FxDockArea = dock_areas.get(String(spec.get("area", "center")))
	if dock == null:
		return
	dock.set_panel_visible(panel_id, true)
	_panel_visible[panel_id] = true
	_refresh_view_menu()
	window_layer.move_to_front()


func toggle_panel(panel_id: String, visible: Variant = null) -> void:
	if not panel_specs.has(panel_id):
		return
	var want := not bool(_panel_visible.get(panel_id, true)) if visible == null else bool(visible)
	if _detached.has(panel_id):
		if want:
			open_panel(panel_id)
		else:
			redock_panel(panel_id)
	var spec: Dictionary = panel_specs[panel_id]
	var dock: FxDockArea = dock_areas.get(String(spec.get("area", "center")))
	if dock == null:
		return
	dock.set_panel_visible(panel_id, want)
	_panel_visible[panel_id] = want
	_refresh_view_menu()
	_save_layout()


func _on_panel_focused(panel_id: String) -> void:
	_panel_visible[panel_id] = true
	_refresh_view_menu()
	_save_layout()


func _refresh_view_menu() -> void:
	_refresh_window_menu()
	if _view_menu == null:
		return
	for index in range(_view_menu.item_count):
		var meta: Variant = _view_menu.get_item_metadata(index)
		if not meta is Dictionary:
			continue
		var panel_id := String((meta as Dictionary).get("panel", ""))
		if panel_id.is_empty():
			continue
		_view_menu.set_item_checked(index, bool(_panel_visible.get(panel_id, true)))


func reset_layout(_ctx: Variant = null) -> void:
	redock_all_panels()
	_floating_geometry.clear()
	for panel_id in panel_specs.keys():
		var spec: Dictionary = panel_specs[panel_id]
		_panel_visible[String(panel_id)] = not bool(spec.get("hidden", false))
	_collapsed_areas.clear()
	_apply_saved_visibility()
	_apply_saved_collapse()
	_save_layout()
	_refresh_window_menu()
	if window_layer != null:
		_tearing_down = true
		window_layer.close_all()
		_tearing_down = false
	status("布局已重置")


func open_window(window_id: String, as_native: bool = false) -> Variant:
	var spec: Dictionary = {}
	for item in FxPluginHost.window_entries():
		var entry: Dictionary = item
		if String(entry.get("id", "")) == window_id:
			spec = entry
			break
	if spec.is_empty():
		status("没有这个窗口：%s" % window_id)
		return null
	var native_id := "native:" + window_id
	var host_id := native_id if as_native else window_id
	if window_layer.has(host_id):
		var existing: Variant = window_layer.window(host_id)
		existing.raise()
		return existing
	var factory: Callable = spec.get("factory", Callable())
	if not factory.is_valid():
		return null
	var content: Variant = factory.call(_context)
	if not content is Control:
		return null
	var size := Vector2i(0, 0)
	var raw_size: Variant = spec.get("size", null)
	if raw_size is Vector2i:
		size = raw_size
	elif raw_size is Vector2:
		size = Vector2i(raw_size)
	elif raw_size is Array and (raw_size as Array).size() >= 2:
		size = Vector2i(int((raw_size as Array)[0]), int((raw_size as Array)[1]))
	var title := FxI18n.text(String(spec.get("title", window_id)))
	var window: Variant = window_layer.open_native(host_id, title, content, size) \
		if as_native else window_layer.open(host_id, title, content, size,
			bool(spec.get("singleton", true)))
	window_layer.move_to_front()
	return window


## 插件窗口也支持独立系统窗口（命令面板 / 菜单里的「▣ 独立窗口」入口）。
func open_window_native(window_id: String) -> Variant:
	return open_window(window_id, true)


func close_window(window_id: String) -> void:
	if window_layer != null:
		window_layer.close(window_id)


# ================= 状态 / 渲染统计 =================

func status(text: String) -> void:
	_message = text
	if _status_label != null:
		_status_label.text = text
		# 以 ✓ 开头的消息（保存成功这类）用成功色，其余保持次要色。
		_status_label.add_theme_color_override("font_color",
			FxUiKit.OK if text.begins_with("✓") else FxUiKit.MUTED)


## 状态栏右端的常驻提示（例如「工程.fxproj · 已保存」）。
## 基座不解释内容，谁有关系谁填；`ok` 只决定颜色。
func set_status_hint(text: String, ok: bool = false) -> void:
	if _save_label == null or not is_instance_valid(_save_label):
		return
	_save_label.text = text
	_save_label.tooltip_text = text
	_save_label.add_theme_color_override("font_color",
		FxUiKit.OK if ok else FxUiKit.MUTED)


## 启动事件：控制台逐条打印「第几步 / 在加载什么」，界面在状态栏同步一条细进度条。
## 启动期界面还没搭好时只是打印，等状态栏存在了才更新控件。
func _on_boot_event(event: Dictionary) -> void:
	var kind := String(event.get("kind", ""))
	var quiet := OS.get_cmdline_user_args().has("--fx-quiet-boot")
	match kind:
		"step":
			var current := String(event.get("current", ""))
			var done := int(event.get("done", 0))
			var total := int(event.get("total", 0))
			var ratio := float(event.get("ratio", -1.0))
			if not quiet:
				print("[启动] %d/%d %s" % [done, total, current])
			if _status_label != null and is_instance_valid(_status_label):
				_status_label.text = "启动中 %d/%d · %s" % [done, total, current]
			if _boot_bar != null and is_instance_valid(_boot_bar) and ratio >= 0.0:
				_boot_bar.visible = true
				_boot_bar.max_value = 1.0
				_boot_bar.value = clampf(ratio, 0.0, 1.0)
		"finish":
			if _boot_bar != null and is_instance_valid(_boot_bar):
				_boot_bar.visible = false
			var plugins := FxRegistry.plugin_infos.size()
			var nodes := FxGraphFacade.access().catalog_all().size()
			var message := "%s · %d 插件 / %d 节点" % [FxBoot.summary(), plugins, nodes]
			if FxBoot.error_count() > 0:
				message += " · 有错误，见启动日志"
			status(message)
		"error":
			if not quiet:
				print("[启动] ✗ %s：%s" % [String(event.get("where", "")),
					String(event.get("message", ""))])


func _on_stats_changed(stats: Dictionary) -> void:
	if _stats_label == null:
		return
	var text := "节点 %d · 步数 %d · %.1f ms" % [
		int(stats.get("nodes", 0)),
		int(stats.get("steps", 0)),
		float(stats.get("ms", 0.0)),
	]
	var color := FxUiKit.MUTED
	# 状态栏的**领域片段**由插件贡献（帧缓存 / 预渲染 / 播放帧号等）。
	# 基座只认识三种通用语气色，不认识任何插件专有字段。
	var fragments: Array[Dictionary] = FxRegistry.status_fragments
	for entry in fragments:
		var handler: Callable = entry.get("handler", Callable())
		if not handler.is_valid():
			continue
		var piece: Variant = handler.call(stats)
		if not piece is Dictionary:
			continue
		var data: Dictionary = piece
		text += String(data.get("text", ""))
		match String(data.get("tone", "")):
			"ok": color = FxUiKit.OK
			"accent": color = FxUiKit.ACCENT_COOL
			"danger": color = FxUiKit.DANGER
	var warnings := int(stats.get("warnings", 0))
	if warnings > 0:
		color = FxUiKit.DANGER
		text += " · ⚠ %d" % warnings
	_stats_label.text = text
	_stats_label.tooltip_text = text
	_stats_label.add_theme_color_override("font_color", color)


# ================= 导出（格式由插件提供） =================

func _build_dialogs() -> void:
	_export_menu = PopupMenu.new()
	_export_menu.id_pressed.connect(_on_export_menu_id)
	add_child(_export_menu)

	_export_file_dialog = FileDialog.new()
	_export_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_export_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_export_file_dialog.use_native_dialog = true
	_export_file_dialog.add_filter("*.png", "PNG 图片")
	_export_file_dialog.file_selected.connect(_on_export_file)
	add_child(_export_file_dialog)

	_export_dir_dialog = FileDialog.new()
	_export_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_export_dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_export_dir_dialog.use_native_dialog = true
	_export_dir_dialog.dir_selected.connect(_on_export_dir)
	add_child(_export_dir_dialog)


func _popup_exporters(anchor: Control) -> void:
	_export_menu.clear()
	var entries := FxPluginHost.export_entries()
	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		_export_menu.add_item(String(entry.get("label", entry.get("id", "导出"))), i)
		_export_menu.set_item_metadata(i, String(entry.get("id", "")))
	if entries.is_empty():
		_export_menu.add_item("（没有导出插件）", 0)
		_export_menu.set_item_disabled(0, true)
	var at := DisplayServer.mouse_get_position()
	if anchor != null:
		at = Vector2i(anchor.get_screen_position() + Vector2(0, anchor.size.y))
	FxUiKit.popup_later(_export_menu, "popup", [Rect2i(at, Vector2i(1, 1))])


func _on_export_menu_id(id: int) -> void:
	var exporter_id := String(_export_menu.get_item_metadata(id))
	if not exporter_id.is_empty():
		export_dialog(exporter_id)


## 打开某个导出格式的文件/目录选择框。
func export_dialog(exporter_id: String) -> void:
	var entry := FxPluginHost.exporter(exporter_id)
	if entry.is_empty():
		status("未知导出格式：%s" % exporter_id)
		return
	_active_export = entry
	if String(entry.get("mode", "file")) == "dir":
		FxUiKit.popup_later(_export_dir_dialog, "popup_centered_ratio", [0.6])
		return
	_export_file_dialog.clear_filters()
	_export_file_dialog.add_filter(String(entry.get("suffix", "*.*")),
		String(entry.get("label", "文件")))
	_export_file_dialog.current_file = _safe_stem() + String(entry.get("default_suffix", ".png"))
	FxUiKit.popup_later(_export_file_dialog, "popup_centered_ratio", [0.6])


func _on_export_file(path: String) -> void:
	_run_exporter(_active_export, path, {})


func _on_export_dir(dir_path: String) -> void:
	_run_exporter(_active_export, dir_path, {})


## 程序化导出（测试/批处理/自动化都用这个入口，不经过文件对话框）。
func export_now(exporter_id: String, path: String, options: Dictionary = {}) -> Dictionary:
	var entry := FxPluginHost.exporter(exporter_id)
	if entry.is_empty():
		status("未知导出格式：%s" % exporter_id)
		return {"ok": false, "message": "未知导出格式：%s" % exporter_id}
	return _run_exporter(entry, path, options)


func _run_exporter(entry: Dictionary, path: String, options: Dictionary) -> Dictionary:
	var handler: Callable = entry.get("handler", Callable())
	if not handler.is_valid():
		return {"ok": false, "message": "导出器没有 handler"}
	var ctx := {
		"doc": store.doc,
		"path": path,
		"stem": _safe_stem(),
		"editor": self,
		"shell": self,
		"status": Callable(self, "status"),
		"time": store.current_time,
		"options": options,
	}
	var result: Variant = handler.call(ctx)
	var out: Dictionary = result if result is Dictionary else {}
	if out.has("message"):
		status(String(out["message"]))
	return out


func _safe_stem() -> String:
	var stem := String(FxGraphFacade.access().doc_meta(store.doc, "name", "image"))
	for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", " "]:
		stem = stem.replace(ch, "_")
	return stem if not stem.is_empty() else "image"


# ================= 文档启动 =================

func _boot_document() -> void:
	var actions: Variant = services.get("document")
	if actions != null and actions.has_method("boot"):
		actions.call("boot")
	elif store.doc.is_empty():
		store.attach(FxGraphFacade.access().doc_new("未命名"))


# ================= 插件热重载 =================

func reload_plugins() -> void:
	if _reloading:
		return
	_reloading = true
	_do_reload.call_deferred()


func _do_reload() -> void:
	var snapshot := store.doc.duplicate(true)
	var selected := store.selected_id
	var time := store.current_time
	var visibility := _panel_visible.duplicate()

	FxPluginHost.reload_all()
	FxPluginHost.set_reconcile_hook(Callable(self, "reconcile_plugins"))
	FxGraphFacade.access().catalog_refresh()

	_teardown_ui()
	_build_layout()
	_instantiate_services()
	_instantiate_panels()
	_build_chrome()
	for panel_id in visibility.keys():
		if panel_specs.has(panel_id):
			toggle_panel(String(panel_id), bool(visibility[panel_id]))

	store.attach(snapshot)
	if not selected.is_empty():
		store.set_selection(selected)
	store.set_time(time)
	_reloading = false
	status(FxPluginHost.summary())


func _teardown_ui(close_windows: bool = true, teardown_services: bool = true) -> void:
	# 分离出去的面板实例活在浮动窗口里；只重建面板层时必须保留引用。
	var kept_controls: Dictionary = {}
	if not close_windows:
		for panel_id in _detached.keys():
			var control: Variant = panel_controls.get(panel_id)
			if control is Control and is_instance_valid(control):
				kept_controls[panel_id] = control
	if close_windows and window_layer != null:
		_tearing_down = true
		window_layer.close_all()
		_tearing_down = false
		_detached.clear()
	for area in dock_areas.keys():
		var dock: FxDockArea = dock_areas[area]
		if is_instance_valid(dock):
			dock.clear_all()
	dock_areas.clear()
	panel_controls.clear()
	panel_specs.clear()
	for panel_id in kept_controls.keys():
		panel_controls[String(panel_id)] = kept_controls[panel_id]
	if teardown_services and _services_root != null:
		for child in _services_root.get_children():
			_services_root.remove_child(child)
			child.queue_free()
	if _root != null:
		remove_child(_root)
		_root.queue_free()
		_root = null
	if _progress_layer != null and is_instance_valid(_progress_layer):
		remove_child(_progress_layer)
		_progress_layer.queue_free()
	_progress_layer = null
	_progress_card = null
	_progress_title = null
	_progress_bar = null
	_progress_step = null
	_menu_bar = null
	_toolbar = null
	_status_label = null
	_stats_label = null
	_view_menu = null
	_play_buttons.clear()
