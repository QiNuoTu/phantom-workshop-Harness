class_name FxRenderBroker
extends RefCounted
## 渲染后端的多路代理（论文 §6.2 Service Multiplexing）。
##
## 消费者（FxRenderService）只注入基座键 renderer.broker，永远不认识具体后端；
## 多个插件可同时贡献后端，按 render.backend 设置项选一个。
## 切换后端只清代理缓存，不重建面板、不重启服务、不扰动消费者的依赖 ——
## 这正是 broker 相对「独占绑定」的价值。
##
## 后端实例按 (id, FxRegistry.revision) 缓存，停用插件后下一次求帧自动回落。

const SETTING_ID := "render.backend"
## 默认后端 = **贡献里 order 最小的那个**，基座不点名任何插件。
## 旧实现把 "gpu.standard" 写死在基座：插件目录一改名，默认值就指向一个不存在的
## 后端（虽然会回落，但「默认用谁」这件事本身就不该由基座决定）。
## 现在 render.gpu 自己声明 order=5，它的顺序就是它的优先级。
const DEFAULT_ID := ""

static var _fallback: FxRenderBackend = null
static var _instances: Dictionary = {}


static func _ensure_fallback() -> void:
	if _fallback == null:
		_fallback = FxRenderBackend.new()


static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in FxRegistry.render_backends:
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


static func backend_ids() -> Array[String]:
	var out: Array[String] = []
	for entry in entries():
		out.append(String(entry.get("id", "")))
	return out


static func has_backend() -> bool:
	return not entries().is_empty()


## 当前选中的后端 id。没设置过（或设置成空）时取贡献顺序里的第一个：
## 「优先用谁」是插件自己的 order 声明，基座只负责按 order 取第一个可用的。
static func current_id() -> String:
	var value: Variant = FxSettings.value(SETTING_ID)
	var wanted := "" if value == null else str(value)
	if not wanted.is_empty():
		return wanted
	var list := entries()
	return "" if list.is_empty() else String(list[0].get("id", ""))


static func entry_for(backend_id: String) -> Dictionary:
	for entry in entries():
		if String(entry.get("id", "")) == backend_id:
			return entry
	return {}


static func current_label() -> String:
	var entry := entry_for(current_id())
	return String(entry.get("label", current_id()))


static func instance() -> FxRenderBackend:
	_ensure_fallback()
	var wanted := current_id()
	var key := "%s@%d" % [wanted, FxRegistry.revision]
	if _instances.has(key):
		return _instances[key]
	var entry := entry_for(wanted)
	if entry.is_empty() and not entries().is_empty():
		entry = entries()[0]
	if entry.is_empty():
		return _fallback
	var factory: Callable = entry.get("factory", Callable())
	if not factory.is_valid():
		return _fallback
	var made: Variant = factory.call()
	if not made is FxRenderBackend:
		return _fallback
	_instances[key] = made
	return made


static func invalidate() -> void:
	for backend in _instances.values():
		if backend is FxRenderBackend:
			(backend as FxRenderBackend).invalidate()
	_instances.clear()


## 求一帧；后端返回空时回落到执行器本身，保证任何配置下都能出图。
static func frame(doc: Dictionary, t: float, policy: Dictionary,
		runner: RefCounted, ctx: Dictionary) -> Dictionary:
	var backend := instance()
	var result: Dictionary = backend.frame(doc, t, policy, runner, ctx)
	if result.is_empty() and runner != null:
		var direct: Variant = runner.call("run", doc, t)
		if direct is Dictionary:
			result = direct
	if result.is_empty():
		return {"image": null, "stats": {}, "previews": {}}
	var stats: Dictionary = result.get("stats", {})
	stats["backend"] = backend.id
	stats["backend_label"] = backend.label
	result["stats"] = stats
	return result
