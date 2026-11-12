class_name FxRegistry
extends RefCounted
## 插件聚合结果的**中立声明式账本**。
##
## 为什么需要它：FxCatalog 需要插件提供的节点文件与算子，插件宿主又需要读目录/算子表；
## 两边直接静态互调会形成 GDScript 的脚本初始化环（运行时报 “!gdscript”）。
## 这里只存数据，谁都可以读，谁都不反向依赖对方。
##
## 论文 §3.1 / §5.2.1 的落地：
##   · ledger 是唯一的声明式配置（desired composition），派生表全是它的纯函数；
##   · 每次 add() 返回一个逆操作（特定 token 的移除 + 重算），交给插件的
##     FxEffectScope 登记；停用插件时 LIFO 回放，只撤回它自己的贡献；
##   · 因此「启用/停用插件」是一次增量 reconciliation，而不是拆掉整个工作台重来。
##
## 写入方：FxPluginHost；读取方：FxCatalog / FxShell / 插件管理器。

const KINDS := [
	"node_file", "op", "time_op", "param_kind", "exporter",
	"panel", "window", "command", "menu", "menu_item", "toolbar",
	"service", "runtime_plugin", "plugin_info", "error", "root",
	"skin", "dock_factory", "setting", "capability", "quality_policy",
	"panel_feature", "locale", "graph_access", "render_backend", "node_picker",
	"drop_handler", "status_fragment", "clock",
]

static var ready: bool = false
static var revision: int = 0
static var ledger: Array[Dictionary] = []
static var _next_token: int = 1

# ---- 派生表（只读；由 rebuild() 从 ledger 重算） ----
static var node_files: Array[String] = []
static var ops: Dictionary = {}
static var time_ops: Array = []
static var param_kinds: Dictionary = {}
static var exporters: Array[Dictionary] = []

static var panels: Array[Dictionary] = []
static var windows: Array[Dictionary] = []
static var commands: Array[Dictionary] = []
static var menus: Array[Dictionary] = []
static var menu_items: Array[Dictionary] = []
static var toolbar: Array[Dictionary] = []
static var services: Dictionary = {}
## 视觉与停靠容器也是一等贡献：换皮肤 / 换 dock 不需要改基座。
static var skins: Array[Dictionary] = []
static var dock_factories: Array[Dictionary] = []
## 声明式配置条目（论文 Definition 74 的 config / disabled 字段）。
## 插件贡献「设置项」，基座只负责持久化、校验与按字段协调，不认识任何具体设置。
static var settings: Array[Dictionary] = []
## 服务代理（§6.2）：一个能力键可以有多个 provider，共存且按优先级合并。
static var capabilities: Array[Dictionary] = []
static var quality_policies: Array[Dictionary] = []
## 面板功能注入：target 可以是面板 id 或 "*"（所有面板），含菜单项。
static var panel_features: Array[Dictionary] = []
## 语言包：{locale, name, entries, owner}，多个插件可叠加同一语言。
static var locales: Array[Dictionary] = []
## 三个「服务代理」贡献：消费者只注入基座键，provider 可增删而不扰动消费者。
static var graph_access: Array[Dictionary] = []
static var render_backends: Array[Dictionary] = []
static var node_pickers: Array[Dictionary] = []
## 拖拽导入：蓝图把落下的文件交给 FxDropBroker，实现全在插件里。
static var drop_handlers: Array[Dictionary] = []
## 状态栏片段：插件贡献「从 stats 生成一段文字」的静态 Callable（§12.3）。
## 基座只拼通用部分，不认识缓存/预渲染/帧号这类插件领域字段。
static var status_fragments: Array[Dictionary] = []
## 时钟提供者：时间维度的组合规则由插件贡献，基座不实现播放时钟（§12.4）。
static var clock_providers: Array[Dictionary] = []

static var plugin_infos: Array[Dictionary] = []
static var errors: Array[String] = []
## 外部插件的实例：注册表里的 Callable 可能绑定它们，必须活到 shutdown。
static var runtime_plugins: Array = []
static var roots: Array[Dictionary] = []


static func reset() -> void:
	ready = false
	revision = 0
	ledger.clear()
	_next_token = 1
	rebuild()


## 登记一条贡献，返回它的逆操作。调用方**必须**把逆操作交给 FxEffectScope，
## 否则该贡献会活过插件本身（论文里就是「效果没有被追踪」）。
static func add(owner: String, kind: String, value: Variant, key: String = "") -> Callable:
	var token := _next_token
	_next_token += 1
	ledger.append({
		"token": token, "owner": owner, "kind": kind, "key": key, "value": value,
	})
	rebuild()
	return func() -> void:
		FxRegistry.remove_token(token)


static func remove_token(token: int) -> void:
	for i in range(ledger.size() - 1, -1, -1):
		if int(ledger[i].get("token", -1)) == token:
			ledger.remove_at(i)
			rebuild()
			return


## 撤回某个插件的全部贡献（逆序），返回撤回条数。
static func remove_owner(owner: String) -> int:
	var count := 0
	for i in range(ledger.size() - 1, -1, -1):
		if String(ledger[i].get("owner", "")) == owner:
			ledger.remove_at(i)
			count += 1
	if count > 0:
		rebuild()
	return count


static func has_owner(owner: String) -> bool:
	for entry in ledger:
		if String(entry.get("owner", "")) == owner:
			return true
	return false


static func owners() -> Array[String]:
	var out: Array[String] = []
	for entry in ledger:
		var owner := String(entry.get("owner", ""))
		if not owner.is_empty() and not out.has(owner):
			out.append(owner)
	return out


static func contributions_of(owner: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in ledger:
		if String(entry.get("owner", "")) == owner:
			out.append(entry)
	return out


## ledger → 派生表。纯函数：同样的 ledger 永远得到同样的表（论文 Theorem 73）。
static func rebuild() -> void:
	node_files.clear()
	ops.clear()
	time_ops.clear()
	param_kinds.clear()
	exporters.clear()
	panels.clear()
	windows.clear()
	commands.clear()
	menus.clear()
	menu_items.clear()
	toolbar.clear()
	services.clear()
	skins.clear()
	dock_factories.clear()
	settings.clear()
	capabilities.clear()
	quality_policies.clear()
	panel_features.clear()
	locales.clear()
	graph_access.clear()
	render_backends.clear()
	node_pickers.clear()
	drop_handlers.clear()
	status_fragments.clear()
	clock_providers.clear()
	plugin_infos.clear()
	errors.clear()
	runtime_plugins.clear()
	roots.clear()

	for entry in ledger:
		var kind := String(entry.get("kind", ""))
		var key := String(entry.get("key", ""))
		var value: Variant = entry.get("value")
		match kind:
			"node_file":
				var path := String(value)
				if not path.is_empty() and not node_files.has(path):
					node_files.append(path)
			"op":
				if not key.is_empty():
					ops[key] = value
			"time_op":
				if not time_ops.has(value):
					time_ops.append(value)
			"param_kind":
				if not key.is_empty():
					param_kinds[key] = value
			"exporter":
				if value is Dictionary:
					exporters.append(value)
			"panel":
				if value is Dictionary:
					panels.append(value)
			"window":
				if value is Dictionary:
					windows.append(value)
			"command":
				if value is Dictionary:
					commands.append(value)
			"menu":
				if value is Dictionary:
					menus.append(value)
			"menu_item":
				if value is Dictionary:
					menu_items.append(value)
			"toolbar":
				if value is Dictionary:
					toolbar.append(value)
			"service":
				if not key.is_empty():
					services[key] = value
			"skin":
				if value is Dictionary:
					skins.append(value)
			"dock_factory":
				if value is Dictionary:
					dock_factories.append(value)
			"setting", "capability", "quality_policy", "panel_feature", "locale", "graph_access", "render_backend", "node_picker", "drop_handler", "status_fragment", "clock":
				if value is Dictionary:
					match kind:
						"setting": settings.append(value)
						"capability": capabilities.append(value)
						"quality_policy": quality_policies.append(value)
						"panel_feature": panel_features.append(value)
						"locale": locales.append(value)
						"graph_access": graph_access.append(value)
						"render_backend": render_backends.append(value)
						"node_picker": node_pickers.append(value)
						"drop_handler": drop_handlers.append(value)
						"status_fragment": status_fragments.append(value)
						"clock": clock_providers.append(value)
			"runtime_plugin":
				runtime_plugins.append(value)
			"plugin_info":
				if value is Dictionary:
					plugin_infos.append(value)
			"error":
				errors.append(String(value))
			"root":
				if value is Dictionary:
					roots.append(value)
	revision += 1


static func panel(id: String) -> Dictionary:
	for entry in panels:
		if String(entry.get("id", "")) == id:
			return entry
	return {}


static func window(id: String) -> Dictionary:
	for entry in windows:
		if String(entry.get("id", "")) == id:
			return entry
	return {}


static func command(id: String) -> Dictionary:
	for entry in commands:
		if String(entry.get("id", "")) == id:
			return entry
	return {}


static func plugin_info(id: String) -> Dictionary:
	for entry in plugin_infos:
		if String(entry.get("id", "")) == id:
			return entry
	return {}


static func setting(id: String) -> Dictionary:
	for entry in settings:
		if String(entry.get("id", "")) == id:
			return entry
	return {}


static func settings_of(owner: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in settings:
		if String(entry.get("owner", "")) == owner:
			out.append(entry)
	return out


## 某个插件注册的东西（按贡献种类分组）。插件中心用来展示「这个插件提供了什么」，
## 不需要为每种贡献写一份硬编码列表。
static func contributions_by_kind(owner: String) -> Dictionary:
	var out: Dictionary = {}
	for entry in ledger:
		if String(entry.get("owner", "")) != owner:
			continue
		var kind := String(entry.get("kind", ""))
		if kind == "plugin_info" or kind == "runtime_plugin":
			continue
		out[kind] = int(out.get(kind, 0)) + 1
	return out


## 某个插件注册的命令（按 order）。这些命令就是它的「插件功能」：
## 例如皮肤插件会注册「应用此皮肤」，插件中心直接把它们渲染成按钮。
static func commands_of(owner: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in ledger:
		if String(entry.get("owner", "")) != owner:
			continue
		if String(entry.get("kind", "")) != "command":
			continue
		var value: Variant = entry.get("value")
		if value is Dictionary:
			var item: Dictionary = (value as Dictionary).duplicate()
			item["owner"] = owner
			out.append(item)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


## 某个插件贡献的皮肤（插件中心里可直接应用）。
static func skins_of(owner: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in ledger:
		if String(entry.get("owner", "")) != owner:
			continue
		if String(entry.get("kind", "")) != "skin":
			continue
		var value: Variant = entry.get("value")
		if value is Dictionary:
			out.append(value)
	return out


## 面板能消费哪些注入功能：target 精确匹配 + "*" 通配，按 order 排序。
static func features_for(panel_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in panel_features:
		var target := String(entry.get("target", "*"))
		if target == "*" or target == panel_id:
			out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out
