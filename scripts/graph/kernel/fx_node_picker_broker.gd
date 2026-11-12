class_name FxNodePickerBroker
extends RefCounted
## 节点选择器的服务代理（论文 §6.2）。
##
## 蓝图层注入基座键 node_picker.broker，永远不认识具体弹窗实现；
## provider 由插件贡献，按 order 选第一个可用的。停用插件时贡献自动撤回，
## 代理返回契约的空实现，蓝图仍可实例化（只是「添加节点」没有界面）。

static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in FxRegistry.node_pickers:
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


static func provider_ids() -> Array[String]:
	var out: Array[String] = []
	for entry in entries():
		out.append(String(entry.get("id", "")))
	return out


static func has_provider() -> bool:
	return not entries().is_empty()


static func create(host: Node) -> FxNodePicker:
	for entry in entries():
		var factory: Callable = entry.get("factory", Callable())
		if not factory.is_valid():
			continue
		var made: Variant = factory.call(host)
		if made is FxNodePicker:
			return made
	return FxNodePicker.new()
