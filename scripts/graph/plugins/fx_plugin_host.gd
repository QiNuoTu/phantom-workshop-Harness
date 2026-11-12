class_name FxPluginHost
extends RefCounted
## 插件宿主：扫描插件目录，把每个插件实例化为**范式内核里的一个组件/fiber**。
##
## 论文对齐：
##   · 组件 ℭ = (inject, provide, apply)             —— Definition 43
##   · 每个插件一个 FxFiber，依赖满足才 ACTIVE     —— Definition 44 / Algorithm 5
##   · apply 里所有贡献都登记进 FxEffectScope 的逆操作 —— §3.1 / Algorithm 1
##   · 停用 = fiber.dispose() → LIFO 回放逆操作 → 依赖者自动 deactivate
##   · 清单 + user://plugins.cfg 是声明式配置，启停是增量 reconciliation（§5.2.1）
##
## 扫描根（按优先级，同 id 先到先得）：
##   res://plugins        内置插件（打进 PCK）
##   user://plugins       用户插件（编辑器里可写，导出后仍在）
##   <exe>/plugins        便携插件（和 exe 放一起，拷走即用）
##
## 打包注意：内置插件的 plugin.json / nodes.json 是 .json 资源，Godot 会打进 PCK；
## export_presets.cfg 里另外加了 include_filter。外部插件的脚本不走 ResourceLoader，
## 而是用 GDScript.source_code 现场编译，所以 exe 旁边的插件无需导入缓存。

const BUILTIN_ROOT := "res://plugins"
const USER_ROOT := "user://plugins"
const CONFIG_PATH := "user://plugins.cfg"
const HOST_OWNER := "@host"

static var _ensured: bool = false
static var _loading: bool = false
static var _context: FxContext = null
static var _host_scope: FxEffectScope = null
static var _base_inverses: Array[Callable] = []
static var _manifests: Dictionary = {}       # pid -> {manifest, dir, root, info}
static var _fibers: Dictionary = {}          # pid -> FxFiber
static var _ordered: Array[String] = []
static var _reconcile_hook: Callable = Callable()
static var _extra_roots: Array[Dictionary] = []

# 只兼容旧 API：FxCatalog._ensure_plugins() 会 new 一个宿主再调 load_all()。
var plugins: Array = []
var exporters: Array[Dictionary] = []
var errors: Array[String] = []


# ================= 生命周期 =================

static func ensure() -> bool:
	if _ensured:
		return FxRegistry.ready
	if _loading:
		return false
	loading_guard(true)
	_scan_all()
	loading_guard(false)
	_ensured = true
	return FxRegistry.ready


static func loading_guard(value: bool) -> void:
	_loading = value


## 供 FxCatalog._ensure_plugins() 以实例方式调用，避免静态初始化环。
func load_all() -> void:
	FxPluginHost.ensure()


func unload() -> void:
	plugins.clear()


## 退出/热重载前显式释放：静态引用如果在脚本类释放后才回收，会让引擎在
## shutdown 阶段崩溃（headless 下表现为 segfault）。
static func shutdown() -> void:
	var gate := FxRenderGate.mutex()
	gate.lock()
	# 逆序卸载 fiber：后加载的依赖者先撤，提供者后撤。
	for i in range(_ordered.size() - 1, -1, -1):
		var pid := _ordered[i]
		var fiber: FxFiber = _fibers.get(pid)
		if fiber != null:
			fiber.dispose()
	_fibers.clear()
	for inverse in _base_inverses:
		if inverse.is_valid():
			inverse.call()
	_base_inverses.clear()
	if _host_scope != null:
		_host_scope.dispose()
		_host_scope = null
	for plugin in FxRegistry.runtime_plugins:
		if is_instance_valid(plugin):
			plugin.host = null
	FxRegistry.reset()
	FxOpRegistry.clear()
	FxWidgetRegistry.clear()
	FxResourceRoot.clear_roots()
	# 原生库留在内存里（GDExtension 不能卸载），但引用与线程安全标记必须清掉，
	# 否则重扫之后会拿着已经失效的类名/旧标记。
	FxNative.reset()
	_reconcile_hook = Callable()
	_manifests.clear()
	_ordered.clear()
	_context = null
	_ensured = false
	_loading = false
	gate.unlock()


static func reload_all() -> void:
	shutdown()
	ensure()


## 外壳注册一个回调：插件贡献变化后只刷新必要的 UI，不重建整个工作台。
static func set_reconcile_hook(hook: Callable) -> void:
	_reconcile_hook = hook


static func reconcile() -> void:
	# 注意：本函数可能已被 set_enabled 持锁调用，所以这里不再加锁；
	# 直接调 reconcile 的路径（插件贡献增量）由 FxRenderGate 的毫秒级窗口兜住。
	_refresh_catalog()
	if _reconcile_hook.is_valid():
		_reconcile_hook.call()


# ================= 访问器（只读聚合结果） =================

static func export_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.exporters


static func exporter(id: String) -> Dictionary:
	ensure()
	for entry in FxRegistry.exporters:
		if String(entry.get("id", "")) == id:
			return entry
	return {}


static func plugin_infos() -> Array[Dictionary]:
	ensure()
	return FxRegistry.plugin_infos


static func panel_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.panels


static func window_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.windows


static func command_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.commands


static func menu_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.menus


static func menu_item_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.menu_items


static func toolbar_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.toolbar


static func service_factories() -> Dictionary:
	ensure()
	return FxRegistry.services


static func skin_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.skins


static func dock_factory_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.dock_factories


static func setting_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.settings


static func capability_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.capabilities


static func quality_policy_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.quality_policies


static func panel_feature_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.panel_features


static func locale_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.locales


static func graph_access_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.graph_access


static func render_backend_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.render_backends


static func status_fragment_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.status_fragments


static func clock_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.clock_providers


static func node_picker_entries() -> Array[Dictionary]:
	ensure()
	return FxRegistry.node_pickers


static func summary() -> String:
	ensure()
	var names: Array[String] = []
	for info in FxRegistry.plugin_infos:
		if not bool(info.get("enabled", true)):
			continue
		names.append("%s %s" % [String(info.get("name", "")), String(info.get("version", ""))])
	if names.is_empty():
		return "所有插件都已停用"
	return "%d 个启用插件：%s" % [names.size(), " · ".join(names)]


static func fiber(pid: String) -> FxFiber:
	ensure()
	return _fibers.get(pid)


static func is_known(pid: String) -> bool:
	ensure()
	return _manifests.has(pid)


static func is_active(pid: String) -> bool:
	var f: FxFiber = fiber(pid)
	return f != null and f.active


static func diagnostics() -> Dictionary:
	ensure()
	return dependency_report()


# ================= 开关（持久化到 user://plugins.cfg） =================

static func disabled_ids() -> Array[String]:
	var out: Array[String] = []
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return out
	var raw: Variant = cfg.get_value("plugins", "disabled", [])
	if raw is Array:
		for item in raw:
			out.append(String(item))
	return out


static func is_enabled(id: String) -> bool:
	return not disabled_ids().has(id)


## 增量启停：只撤回/重装这一个插件的贡献，不重扫其它插件、不拆工作台。
static func set_enabled(id: String, enabled: bool) -> void:
	ensure()
	if not _manifests.has(id):
		return
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	var list: Array = []
	for item in cfg.get_value("plugins", "disabled", []):
		list.append(String(item))
	if enabled:
		list.erase(id)
	elif not list.has(id):
		list.append(id)
	cfg.set_value("plugins", "disabled", list)
	cfg.save(CONFIG_PATH)

	var gate := FxRenderGate.mutex()
	gate.lock()
	var record: Dictionary = _manifests[id]
	var info: Dictionary = record["info"]
	info["enabled"] = enabled
	if enabled:
		_create_fiber(id)
	else:
		var f: FxFiber = _fibers.get(id)
		if f != null:
			f.dispose()
		_fibers.erase(id)
		# 算子贡献已经随 fiber 撤回，线程安全标记也要跟着收回。
		FxNative.release(id)
	reconcile()
	gate.unlock()


# ================= 扫描根 =================

## 插件只有一种：目录里的 plugin.json + 源码。
## 开发期直接读工程里的 res://plugins；发行版先读用户目录与 <exe>/plugins
## （可编辑、可替换），PCK 里那份只作为「目录被删掉」时的兜底。
static func roots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if OS.has_feature("editor"):
		out.append({"path": BUILTIN_ROOT, "label": "项目", "external": true})
	else:
		out.append({"path": USER_ROOT, "label": "用户", "external": true})
		var exe_dir := OS.get_executable_path().get_base_dir()
		if not exe_dir.is_empty():
			out.append({"path": exe_dir.path_join("plugins"), "label": "程序目录", "external": true})
		out.append({"path": BUILTIN_ROOT, "label": "随包", "external": true})
	for extra in _extra_roots:
		out.append(extra)
	return out


## 临时增加一个扫描根（插件包分发 / 测试注入）。返回值是撤销用的逆操作。
## 需要先调整根再生效，所以调用方通常紧接着 reload_all()。
static func add_scan_root(path: String, label: String = "外部", external: bool = true) -> Callable:
	var entry := {"path": path, "label": label, "external": external}
	_extra_roots.append(entry)
	return func() -> void:
		_extra_roots.erase(entry)


static func clear_scan_roots() -> void:
	_extra_roots.clear()


static func ensure_user_root() -> String:
	if not DirAccess.dir_exists_absolute(USER_ROOT):
		DirAccess.make_dir_recursive_absolute(USER_ROOT)
	return USER_ROOT


# ================= 装配 =================

static func _scan_all() -> void:
	# 后台渲染线程可能正在读 FxRegistry / FxCatalog / FxOpRegistry：
	# 重建这些静态表期间必须与求帧互斥，否则会读到半新半旧的表。
	var gate := FxRenderGate.mutex()
	gate.lock()
	ensure_user_root()
	_context = FxContext.new()
	_host_scope = FxEffectScope.new()
	_manifests.clear()
	_fibers.clear()
	_ordered.clear()

	# 基座提供的 coeffect 键：不是任何插件的私有产物，用 host scope 跟踪。
	for key in ["core.shell", "core.catalog", "core.document", "core.render",
			"core.registry", "core.plugins", "graph.facade", "renderer.broker",
			"node_picker.broker"]:
		_base_inverses.append(_context.set_value(key, {"version": "1.0", "owner": HOST_OWNER}))

	var disabled: Array[String] = disabled_ids()
	var seen: Dictionary = {}
	# 启动进度要有分母：先数一遍带 plugin.json 的目录，再逐个推进。
	FxBoot.expect(_count_plugin_dirs() + 2)
	for root in roots():
		var root_path := String(root.get("path", ""))
		var exists := DirAccess.dir_exists_absolute(root_path)
		var root_info := {
			"path": root_path, "label": String(root.get("label", "")),
			"external": bool(root.get("external", false)), "exists": exists, "count": 0,
		}
		_host_scope.add(FxRegistry.add(HOST_OWNER, "root", root_info))
		if not exists:
			continue
		var dirs: Array = Array(DirAccess.get_directories_at(root_path))
		dirs.sort()
		for dir_name in dirs:
			var plugin_dir := root_path.path_join(String(dir_name))
			var manifest := _read_manifest(plugin_dir, root)
			if manifest.is_empty():
				# 插件素材目录：跟着插件走的外部资源，不参与加载，也不算错误。
				if DirAccess.dir_exists_absolute(plugin_dir.path_join("assets")):
					continue
				_add_host_error("跳过 %s：缺少 plugin.json / plugin.gd" % plugin_dir)
				continue
			var pid := String(manifest.get("id", ""))
			if pid.is_empty():
				_add_host_error("跳过 %s：插件 id 为空" % plugin_dir)
				continue
			if seen.has(pid):
				continue
			seen[pid] = true
			root_info["count"] = int(root_info["count"]) + 1
			var enabled := not disabled.has(pid)
			var info := {
				"id": pid,
				"name": String(manifest.get("name", pid)),
				"version": String(manifest.get("version", "1.0")),
				"description": String(manifest.get("description", "")),
				"root": root_path,
				"root_label": String(root.get("label", "")),
				"external": bool(manifest.get("external", false)),
				"dir": plugin_dir,
				"icon": String(manifest.get("icon", "")),
				"icon_file": String(manifest.get("icon_file", "")),
				"icon_anim": manifest.get("icon_anim", manifest.get("icon_sheet", {})),
				"color": String(manifest.get("color", "#4cc2ff")),
				"author": String(manifest.get("author", "")),
				"category": String(manifest.get("category", "插件")),
				"homepage": String(manifest.get("homepage", "")),
				"enabled": enabled,
				"inject": _inject_keys(manifest),
				"provide": _provide_keys(manifest),
			}
			_host_scope.add(FxRegistry.add(HOST_OWNER, "plugin_info", info))
			_manifests[pid] = {
				"manifest": manifest, "dir": plugin_dir, "root": root, "info": info,
			}
			_ordered.append(pid)
			FxBoot.step("插件 %s" % pid)

	_check_declarations()
	FxBoot.step("依赖与供给键检查")
	# 拓扑顺序：先给不依赖别人的插件建 fiber，减少中途反复激活。
	for pid in _activation_order():
		if bool((_manifests[pid] as Dictionary)["info"]["enabled"]):
			_create_fiber(pid)
	FxRegistry.ready = not _ordered.is_empty()
	if FxRegistry.ready:
		_refresh_catalog()
	FxBoot.step("节点目录与算子表")
	gate.unlock()


## 目录刷新属于图领域：宿主只通过代理转发，不直接认识 FxCatalog。
## 先 invalidate 一次，避免代理里缓存的还是「没有 provider」时的空实现。
static func _refresh_catalog() -> void:
	FxGraphFacade.invalidate()
	FxGraphFacade.access().catalog_refresh()


static func _add_host_error(text: String) -> void:
	_host_scope.add(FxRegistry.add(HOST_OWNER, "error", text))
	FxBoot.error("插件加载", text)


## 启动预算用：各根下带清单的插件目录数（素材目录不算）。
static func _count_plugin_dirs() -> int:
	var count := 0
	for root in roots():
		var root_path := String(root.get("path", ""))
		if not DirAccess.dir_exists_absolute(root_path):
			continue
		for dir_name in DirAccess.get_directories_at(root_path):
			if FileAccess.file_exists(root_path.path_join(String(dir_name)).path_join("plugin.json")):
				count += 1
	return count


## 论文 §6.5 / §6.6：依赖环、重复供给、命名空间冲突都能从声明里静态看出。
static func _check_declarations() -> void:
	var provider_of: Dictionary = {}
	for pid in _ordered:
		var info: Dictionary = (_manifests[pid] as Dictionary)["info"]
		for key in info["provide"]:
			if provider_of.has(key):
				_add_host_error("供给键冲突：%s 与 %s 都提供 %s" % [provider_of[key], pid, key])
			else:
				provider_of[key] = pid
	for cycle in _find_cycles():
		_add_host_error("依赖环：%s" % " → ".join(PackedStringArray(cycle)))
	for pid in _ordered:
		var info2: Dictionary = (_manifests[pid] as Dictionary)["info"]
		for key in info2["inject"]:
			# 供给者可以是插件，也可以是基座自己（corer shell / 服务代理键）。
			# _context 在 _scan_all 开头已经装好基座键，所以这里直接查它，
			# 而不是只认插件的 provide 表。
			if not provider_of.has(key) and not _context.has_key(String(key)) \
					and not String(key).begins_with("core."):
				_add_host_error("缺少提供者：%s 声明了 %s" % [pid, String(key)])


static func _find_cycles() -> Array:
	var edges: Dictionary = {}
	var provider_of: Dictionary = {}
	for pid in _ordered:
		var info: Dictionary = (_manifests[pid] as Dictionary)["info"]
		for key in info["provide"]:
			provider_of[key] = pid
	for pid2 in _ordered:
		var deps: Array = []
		var info2: Dictionary = (_manifests[pid2] as Dictionary)["info"]
		for key in info2["inject"]:
			if provider_of.has(key):
				deps.append(String(provider_of[key]))
		edges[pid2] = deps
	var done: Dictionary = {}
	var out: Array = []
	for start in _ordered:
		if done.has(start):
			continue
		var stack: Array[String] = []
		var visiting: Dictionary = {}
		var found := _dfs(start, edges, stack, visiting, done)
		if not found.is_empty():
			out.append(found)
	return out


static func _dfs(node: String, edges: Dictionary, stack: Array[String],
		visiting: Dictionary, done: Dictionary) -> Array[String]:
	if done.has(node):
		return []
	if visiting.has(node):
		var at := stack.find(node)
		if at >= 0:
			var cyc: Array[String] = []
			for i in range(at, stack.size()):
				cyc.append(stack[i])
			cyc.append(node)
			return cyc
		return []
	visiting[node] = true
	stack.append(node)
	for nxt in edges.get(node, []):
		var cyc := _dfs(String(nxt), edges, stack, visiting, done)
		if not cyc.is_empty():
			return cyc
	stack.pop_back()
	visiting.erase(node)
	done[node] = true
	return []


## 稳定拓扑序（有环时退化为扫描序）。
static func _activation_order() -> Array[String]:
	var provider_of: Dictionary = {}
	for pid in _ordered:
		var info: Dictionary = (_manifests[pid] as Dictionary)["info"]
		for key in info["provide"]:
			provider_of[key] = pid
	var out: Array[String] = []
	var placed: Dictionary = {}
	var remaining: Array = _ordered.duplicate()
	for guard_i in range(_ordered.size() + 1):
		if remaining.is_empty():
			break
		var progressed := false
		for pid in remaining.duplicate():
			var info2: Dictionary = (_manifests[pid] as Dictionary)["info"]
			var ready := true
			for key in info2["inject"]:
				var p: Variant = provider_of.get(key, null)
				if p != null and not placed.has(String(p)):
					ready = false
			if ready:
				out.append(pid)
				placed[pid] = true
				remaining.erase(pid)
				progressed = true
		if not progressed:
			out.append_array(remaining)
			break
	return out


## 运行时的依赖报告（供诊断与插件管理器展示）。
static func dependency_report() -> Dictionary:
	var missing: Array[Dictionary] = []
	var inactive: Array[String] = []
	for pid in _ordered:
		var info: Dictionary = (_manifests[pid] as Dictionary)["info"]
		var f: FxFiber = _fibers.get(pid)
		if f == null or not f.active:
			inactive.append(pid)
			for key in info["inject"]:
				if not _context.has_key(String(key)):
					missing.append({"plugin": pid, "key": String(key)})
	return {
		"missing": missing,
		"inactive": inactive,
		"cycles": _find_cycles(),
		"active": _active_ids(),
	}


static func _active_ids() -> Array[String]:
	var out: Array[String] = []
	for pid in _ordered:
		if is_active(pid):
			out.append(pid)
	return out


# ================= fiber =================

static func _create_fiber(pid: String) -> void:
	if _fibers.has(pid) or not _manifests.has(pid):
		return
	var record: Dictionary = _manifests[pid]
	var info: Dictionary = record["info"]
	var component := FxComponent.new()
	component.label = String(info.get("name", pid))
	component.inject = (info["inject"] as Array[String]).duplicate()
	component.provide = (info["provide"] as Array[String]).duplicate()
	component.apply = func(_ctx: FxContext, config: Dictionary, scope: FxEffectScope) -> void:
		FxPluginHost._activate_plugin(String(config.get("pid", "")), scope)
	var fiber := _context.use(component, {"pid": pid})
	_fibers[pid] = fiber


## 组件的 apply：这里做的每一件事都必须登记逆操作。
static func _activate_plugin(pid: String, scope: FxEffectScope) -> void:
	if not _manifests.has(pid):
		return
	var record: Dictionary = _manifests[pid]
	var manifest: Dictionary = record["manifest"]
	var plugin_dir: String = record["dir"]
	var plugin: Variant = _instantiate(manifest, plugin_dir)
	if plugin == null:
		scope.add(FxRegistry.add(pid, "error", "插件脚本无法加载：%s" % plugin_dir))
		return
	plugin.setup(null, manifest, plugin_dir)
	# 原生库必须赶在 native_ops() 之前加载：类没注册就绑不了。
	if manifest.get("native", null) is Dictionary:
		var native_meta: Dictionary = manifest["native"]
		var library := String(native_meta.get("library", ""))
		if not library.is_empty():
			var report := FxNative.load_library(plugin_dir.path_join(library))
			if not bool(report.get("ok", false)):
				_contribute(scope, pid, "error",
					"原生库加载失败：%s" % String(report.get("message", library)))
	plugin.activate()

	# 1) 贡献（时间上先登记，LIFO 时会最后撤销 → 依赖者先撤完）。
	for path in plugin.node_files():
		_contribute(scope, pid, "node_file", String(path))
	var ops: Dictionary = plugin.ops()
	for key in ops.keys():
		var op: Callable = ops[key]
		if _accept_callable(op, plugin, "算子 %s" % key, scope, pid):
			_contribute(scope, pid, "op", op, String(key))
	# 原生算子与脚本算子进的是同一张 op 表：节点定义只认 op id，
	# 所以「把某个算子换成 C++ 实现」不需要改任何 JSON 或蓝图代码。
	for entry in plugin.native_ops():
		var op_id := String(entry.get("op", ""))
		var native_op := FxNative.bind(StringName(String(entry.get("class", ""))),
			op_id, bool(entry.get("thread_safe", true)), pid)
		if native_op.is_valid() and _accept_callable(native_op, plugin,
				"原生算子 %s" % op_id, scope, pid):
			_contribute(scope, pid, "op", native_op, op_id)
	for op_id in plugin.time_dependent_ops():
		_contribute(scope, pid, "time_op", op_id)
	for entry in plugin.exporters():
		var handler: Callable = entry.get("handler", Callable())
		if handler.is_valid() and not _accept_callable(handler, plugin,
				"导出器 %s" % entry.get("id", ""), scope, pid):
			continue
		_contribute(scope, pid, "exporter", entry)
	var kinds: Dictionary = plugin.param_kinds()
	for kind in kinds.keys():
		var builder: Callable = kinds[kind]
		if _accept_callable(builder, plugin, "参数控件 %s" % kind, scope, pid):
			_contribute(scope, pid, "param_kind", builder, String(kind))
	for entry2 in plugin.panels():
		if _accept_callable(entry2.get("factory", Callable()), plugin,
				"面板 %s" % entry2.get("id", ""), scope, pid):
			_contribute(scope, pid, "panel", entry2)
	for entry3 in plugin.windows():
		if _accept_callable(entry3.get("factory", Callable()), plugin,
				"窗口 %s" % entry3.get("id", ""), scope, pid):
			_contribute(scope, pid, "window", entry3)
	for entry4 in plugin.commands():
		if _accept_callable(entry4.get("handler", Callable()), plugin,
				"命令 %s" % entry4.get("id", ""), scope, pid):
			_contribute(scope, pid, "command", entry4)
	for entry5 in plugin.menus():
		_contribute(scope, pid, "menu", entry5)
	for entry6 in plugin.menu_items():
		_contribute(scope, pid, "menu_item", entry6)
	for entry7 in plugin.toolbar():
		_contribute(scope, pid, "toolbar", entry7)
	var svc: Dictionary = plugin.services()
	for svc_id in svc.keys():
		var factory: Callable = svc[svc_id]
		if _accept_callable(factory, plugin, "服务 %s" % svc_id, scope, pid):
			_contribute(scope, pid, "service", factory, String(svc_id))
	for entry8 in plugin.skins():
		var skin_factory: Callable = entry8.get("factory", Callable())
		if _accept_callable(skin_factory, plugin, "皮肤 %s" % entry8.get("id", ""), scope, pid):
			_contribute(scope, pid, "skin", entry8)
	for entry9 in plugin.dock_factories():
		var dock_factory: Callable = entry9.get("factory", Callable())
		if _accept_callable(dock_factory, plugin, "停靠容器 %s" % entry9.get("id", ""), scope, pid):
			_contribute(scope, pid, "dock_factory", entry9)
	for entry10 in plugin.settings():
		var setting: Dictionary = entry10.duplicate(true)
		setting["owner"] = pid
		_contribute(scope, pid, "setting", setting, String(setting.get("id", "")))
	for entry11 in plugin.capabilities():
		if _accept_callable(entry11.get("apply", Callable()), plugin,
				"能力 %s" % entry11.get("key", ""), scope, pid):
			var capability: Dictionary = entry11.duplicate(true)
			capability["owner"] = pid
			_contribute(scope, pid, "capability", capability, String(capability.get("key", "")))
	for entry12 in plugin.quality_policies():
		if _accept_callable(entry12.get("apply", Callable()), plugin,
				"质量策略 %s" % pid, scope, pid):
			var policy: Dictionary = entry12.duplicate(true)
			policy["owner"] = pid
			_contribute(scope, pid, "quality_policy", policy)
	for entry13 in plugin.panel_features():
		var feature: Dictionary = entry13.duplicate(true)
		feature["owner"] = pid
		_contribute(scope, pid, "panel_feature", feature)
	for entry14 in plugin.locales():
		var locale: Dictionary = entry14.duplicate(true)
		locale["owner"] = pid
		_contribute(scope, pid, "locale", locale, String(locale.get("locale", "")))
	# 插件自己的译文放在自己的目录里（locales/<locale>.json），
	# 不经过 core.i18n，也不与基座文件夹产生任何交互。
	_contribute_locale_files(scope, pid, plugin_dir)
	for entry15 in plugin.graph_access():
		if _accept_callable(entry15.get("factory", Callable()), plugin,
				"图能力 %s" % entry15.get("id", ""), scope, pid):
			var access: Dictionary = entry15.duplicate(true)
			access["owner"] = pid
			_contribute(scope, pid, "graph_access", access, String(access.get("id", "")))
	for entry16 in plugin.render_backends():
		if _accept_callable(entry16.get("factory", Callable()), plugin,
				"渲染后端 %s" % entry16.get("id", ""), scope, pid):
			var backend: Dictionary = entry16.duplicate(true)
			backend["owner"] = pid
			_contribute(scope, pid, "render_backend", backend, String(backend.get("id", "")))
	for entry_sf in plugin.status_fragments():
		if _accept_callable(entry_sf.get("handler", Callable()), plugin,
				"状态栏片段 %s" % entry_sf.get("id", ""), scope, pid):
			var fragment: Dictionary = entry_sf.duplicate(true)
			fragment["owner"] = pid
			_contribute(scope, pid, "status_fragment", fragment, String(fragment.get("id", "")))
	for entry_clock in plugin.clocks():
		if _accept_callable(entry_clock.get("factory", Callable()), plugin,
				"时钟 %s" % entry_clock.get("id", ""), scope, pid):
			var clock: Dictionary = entry_clock.duplicate(true)
			clock["owner"] = pid
			_contribute(scope, pid, "clock", clock, String(clock.get("id", "")))
	for entry17 in plugin.node_pickers():
		if _accept_callable(entry17.get("factory", Callable()), plugin,
				"节点选择器 %s" % entry17.get("id", ""), scope, pid):
			var picker: Dictionary = entry17.duplicate(true)
			picker["owner"] = pid
			_contribute(scope, pid, "node_picker", picker, String(picker.get("id", "")))
	for entry18 in plugin.drop_handlers():
		if _accept_callable(entry18.get("handler", Callable()), plugin,
				"拖拽导入 %s" % entry18.get("id", ""), scope, pid):
			var drop: Dictionary = entry18.duplicate(true)
			drop["owner"] = pid
			_contribute(scope, pid, "drop_handler", drop, String(drop.get("id", "")))

	# 2) 插件实例要活到 shutdown：实例方法的 Callable 依赖它。
	#    所有插件一视同仁，没有「内置只能静态」的特殊规则。
	_contribute(scope, pid, "runtime_plugin", plugin)

	# 3) 供给键最后登记 → LIFO 时最先撤回，先通知依赖者再撤自己的贡献。
	var provide_versions: Dictionary = record["manifest"].get("provide_versions", {})
	for key in (record["info"] as Dictionary)["provide"]:
		var version := String(provide_versions.get(key, record["info"]["version"]))
		scope.add(_context.set_value(String(key), {"plugin": pid, "version": version}))


static func _contribute(scope: FxEffectScope, owner: String, kind: String,
		value: Variant, key: String = "") -> void:
	scope.add(FxRegistry.add(owner, kind, value, key))


## 扫描 `<plugin_dir>/locales/*.json`：文件名即语言代码，内容 {name, entries}。
## 于是「谁注册的东西谁来翻译」：插件带着自己的译文走，停用/删除插件时译文
## 随贡献一起撤回，基座（包括 core.i18n）完全不需要知道这些目录存在。
## 也接受扁平写法 { "源文": "译文" }，方便手写小包。
static func _contribute_locale_files(scope: FxEffectScope, owner: String,
		plugin_dir: String) -> void:
	var folder := plugin_dir.path_join("locales")
	var dir := DirAccess.open(folder)
	if dir == null:
		return
	var files := Array(dir.get_files())
	files.sort()
	var order := 100
	for file_name in files:
		var name := String(file_name)
		if not name.ends_with(".json"):
			continue
		var locale_id := name.get_basename()
		var text := FileAccess.get_file_as_string(folder.path_join(name))
		if text.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(text)
		if not parsed is Dictionary:
			_contribute(scope, owner, "error",
				"语言包格式错误：%s" % folder.path_join(name))
			continue
		var data: Dictionary = parsed
		var words: Dictionary = {}
		var raw: Variant = data.get("entries", null)
		if raw is Dictionary:
			words = (raw as Dictionary).duplicate(true)
		else:
			for key in data.keys():
				if String(key) in ["name", "locale", "order"]:
					continue
				words[String(key)] = data[key]
		if words.is_empty():
			continue
		_contribute(scope, owner, "locale", {
			"locale": locale_id,
			"name": String(data.get("name", locale_id)),
			"entries": words,
			"order": int(data.get("order", order)),
			"owner": owner,
		}, locale_id)
		order += 1


## 静态 Callable 校验；错误也归到插件名下，停用插件时会自动消失。
static func _accept_callable(callable: Callable, plugin, what: String,
		scope: FxEffectScope, owner: String) -> bool:
	if not callable.is_valid():
		_contribute(scope, owner, "error", "%s 的%s无效" % [plugin.id, what])
		return false
	# 绑定插件实例的 Callable 也允许：实例由 runtime_plugin 贡献保活到 shutdown，
	# 因此「内置 / 外部」不再有行为差异。
	return true


# ================= 清单 =================

static func _inject_keys(manifest: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var raw: Variant = manifest.get("inject", [])
	if raw is Array:
		for item in raw:
			var key := String(item["key"]) if item is Dictionary else String(item)
			if not key.is_empty() and not out.has(key):
				out.append(key)
	return out


static func _provide_keys(manifest: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var versions: Dictionary = {}
	var raw: Variant = manifest.get("provide", [])
	if raw is Dictionary:
		for key in (raw as Dictionary).keys():
			var k := String(key)
			versions[k] = String((raw as Dictionary)[key])
			if not out.has(k):
				out.append(k)
	elif raw is Array:
		for item in raw:
			var k2 := String(item["key"]) if item is Dictionary else String(item)
			if item is Dictionary:
				versions[k2] = String(item.get("version", manifest.get("version", "1.0")))
			if not k2.is_empty() and not out.has(k2):
				out.append(k2)
	manifest["provide_versions"] = versions
	return out


static func _read_manifest(plugin_dir: String, root: Dictionary) -> Dictionary:
	var manifest: Dictionary = {}
	var json_path := plugin_dir.path_join("plugin.json")
	if FileAccess.file_exists(json_path):
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
		if raw is Dictionary:
			manifest = (raw as Dictionary).duplicate(true)
		else:
			_add_host_error("plugin.json 不是对象：%s" % json_path)
			return {}
	elif FileAccess.file_exists(plugin_dir.path_join("plugin.gd")) or ResourceLoader.exists(plugin_dir.path_join("plugin.gd")):
		manifest = {
			"id": plugin_dir.get_file(), "name": plugin_dir.get_file(),
			"script": "plugin.gd", "description": "（无清单，按目录名注册）",
		}
	else:
		return {}
	manifest["root"] = String(root.get("path", ""))
	manifest["external"] = bool(root.get("external", false))
	if String(manifest.get("id", "")).is_empty():
		manifest["id"] = plugin_dir.get_file()
	return manifest


static func _instantiate(manifest: Dictionary, plugin_dir: String):
	var script_name := String(manifest.get("script", ""))
	if script_name.is_empty():
		return FxPlugin.new()
	var script_path := plugin_dir.path_join(script_name)
	var script := _load_script(script_path, bool(manifest.get("external", false)))
	if script == null:
		return null
	var instance: Variant = script.new()
	if not instance is FxPlugin:
		return null
	return instance


## 所有插件走同一条路：磁盘上有源码就现场编译（改完重启即生效），
## 只有源码不可读时才回落到 ResourceLoader（PCK 里的 .gdc 兜底）。
static func _load_script(path: String, _external: bool = true) -> Script:
	if not FileAccess.file_exists(path):
		if ResourceLoader.exists(path):
			return load(path)
		return null
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		return null
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		return null
	return script
