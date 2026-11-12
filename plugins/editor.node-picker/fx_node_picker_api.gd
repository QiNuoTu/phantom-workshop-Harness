class_name FxNodePickerApi
extends RefCounted
## 节点选择器插件的静态工厂。蓝图只拿 FxNodePicker 契约，不认识这个实现类。

static func create(_host: Node) -> FxNodePicker:
	return FxNodeCreateDialog.new()
