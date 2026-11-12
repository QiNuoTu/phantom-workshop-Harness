class_name FxClockBroker
extends RefCounted
## 时间维度的服务代理（Spatiotemporal Composability）。
##
## 空间维度由 `core.graph` 描述（节点、连线、子图嵌套），时间维度由插件贡献
## 「时钟」（帧号推进、时间↔帧换算、循环）。渲染服务把两者组合起来求一帧，
## 但**基座不实现任何时钟语义**：这里只做 provider 选择，行为和参数全在插件里。
##
## 这样换时间模型（变速、倒放、逐帧步进、外部时间码同步）只需新增/替换一个
## 插件，不必改 `core.render` 或外壳；停用时钟插件时 `core.render` 用自己的
## 最小降级时钟维持「帧号连续」这条不变量。

static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in FxRegistry.clock_providers:
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("priority", 0)) > int(b.get("priority", 0)))
	return out


static func provider_count() -> int:
	return FxRegistry.clock_providers.size()


static func provider_id() -> String:
	var all := entries()
	return String((all[0] as Dictionary).get("id", "")) if not all.is_empty() else ""


## 返回一个满足时钟契约的对象（reset / advance / time_of / frame_at / frame）。
## 基座用 duck typing 调它，不 import 任何插件类；没有 provider 时返回 null。
static func create() -> RefCounted:
	for entry in entries():
		var factory: Callable = entry.get("factory", Callable())
		if not factory.is_valid():
			continue
		var instance: Variant = factory.call()
		if instance is RefCounted and _conforms(instance as RefCounted):
			return instance as RefCounted
	return null


static func _conforms(value: RefCounted) -> bool:
	return value.has_method("reset") and value.has_method("advance") \
		and value.has_method("time_of") and value.has_method("frame_at") \
		and value.get("frame") != null
