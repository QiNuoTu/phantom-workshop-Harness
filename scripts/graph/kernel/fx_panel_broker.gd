class_name FxPanelBroker
extends RefCounted
## 面板功能注入的代理（论文 §6.2）。
##
## 所有面板都通过注册表暴露，因此「插件面板」和「随软件发布的面板」在
## 注入端没有任何区别：任何插件都能用 target=panel_id 精确注入，或
## target="*" 通配注入菜单项 / 命令 / 工具栏按钮，面板自己只消费代理结果。
## 新增 provider 不会让已有面板重新实例化，符合增量 reconciliation。

static func panel_ids() -> Array[String]:
	var out: Array[String] = []
	for entry in FxRegistry.panels:
		var id := String(entry.get("id", ""))
		if not id.is_empty() and not out.has(id):
			out.append(id)
	out.sort()
	return out


static func features(panel_id: String) -> Array[Dictionary]:
	return FxRegistry.features_for(panel_id)


static func menu_features(panel_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in features(panel_id):
		if bool(entry.get("separator", false)):
			continue
		var label := String(entry.get("label", ""))
		if label.is_empty():
			continue
		out.append(entry)
	return out


static func all_features() -> Array[Dictionary]:
	return FxRegistry.panel_features.duplicate(true)
