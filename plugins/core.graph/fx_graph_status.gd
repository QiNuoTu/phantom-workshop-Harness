class_name FxGraphStatus
extends RefCounted
## 图领域的诊断片段（由 `core.graph` 贡献）。
##
## 为什么需要它：装配诊断里那行「节点定义 / 算子」原本由外壳直接读
## `FxOpRegistry.ids()` —— 而 `FxOpRegistry` 是本插件的类。`class_name` 是
## 编译期符号，等于让基座离不开本插件。改成插件自报后，基座只负责拼接文本。

## 状态栏片段：节点数与步数由基座的通用部分打印，这里不重复，返回空文本。
static func fragment(_stats: Dictionary) -> Dictionary:
	return {"text": "", "tone": ""}


## 启动诊断：节点类型与算子数量。算子表只有本插件认识，所以由本插件报。
static func diagnostic(_service: Variant) -> String:
	if not FxRegistry.ready:
		return ""
	return "节点类型 %d / 算子 %d（core.graph）" % [
		FxCatalog.all().size(), FxOpRegistry.ids().size(),
	]
