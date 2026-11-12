class_name FxCapabilities
extends RefCounted
## 服务代理（论文 §6.2 Service Multiplexing）。
##
## 一个「能力键」可以有多个 provider 同时存在；代理按 order 依次调用，
## 后加载/高优先级的 provider 覆盖前面的结果。消费者只注入能力键，
## 不直接绑定某个插件：新增或卸载 provider 不会扰动消费者的依赖，
## 也就不会触发整棵 fiber 树的重新激活（§6.2 broker 的意义）。
##
## 每个 provider 的贡献都在 FxRegistry 的 ledger 里，停用插件时 LIFO 撤回。

static func keys() -> Array[String]:
	var out: Array[String] = []
	for entry in FxRegistry.capabilities:
		var key := String(entry.get("key", ""))
		if not key.is_empty() and not out.has(key):
			out.append(key)
	out.sort()
	return out


static func has(key: String) -> bool:
	return keys().has(key)


static func providers(key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in FxRegistry.capabilities:
		if String(entry.get("key", "")) == key:
			out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


## 把值交给该键下的所有 provider；返回真正被调用的数量。
static func dispatch(key: String, value: Variant) -> int:
	var count := 0
	for entry in providers(key):
		var handler: Callable = entry.get("apply", Callable())
		if handler.is_valid():
			handler.call(value)
			count += 1
	return count
