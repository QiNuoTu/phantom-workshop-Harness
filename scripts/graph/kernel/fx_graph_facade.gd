class_name FxGraphFacade
extends RefCounted
## 图能力的服务代理（论文 §6.2）。
##
## 蓝图层只调 FxGraphFacade.access()，永远不认识具体实现；多个 provider 可以共存，
## 按 order 选优先级最高的那个。provider 的贡献在 FxRegistry 的可逆账本里，
## 停用 core.graph 时自动撤回，代理随即回落到 FxGraphAccess 的安全空实现 ——
## 消费者不会被重新加载，也不会崩，这正是 broker 相对「独占绑定」的优势。
##
## 缓存按 FxRegistry.revision 失效，因此插件启停后下一次访问就会重新解析。

static var _fallback: FxGraphAccess = null
static var _cached: FxGraphAccess = null
static var _cached_revision: int = -1


static func _ensure_fallback() -> void:
	if _fallback == null:
		_fallback = FxGraphAccess.new()


static func providers() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in FxRegistry.graph_access:
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


static func provider_ids() -> Array[String]:
	var out: Array[String] = []
	for entry in providers():
		out.append(String(entry.get("id", "")))
	return out


static func has_provider() -> bool:
	return not providers().is_empty()


static func access() -> FxGraphAccess:
	_ensure_fallback()
	if _cached != null and _cached_revision == FxRegistry.revision:
		return _cached
	_cached = _fallback
	for entry in providers():
		var factory: Callable = entry.get("factory", Callable())
		if not factory.is_valid():
			continue
		var made: Variant = factory.call()
		if made is FxGraphAccess:
			_cached = made
			break
	_cached_revision = FxRegistry.revision
	return _cached


static func invalidate() -> void:
	_cached = null
	_cached_revision = -1
