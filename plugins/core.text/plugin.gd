extends FxPlugin
## 外部字体文本节点；同时注册 font 参数控件。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsText.ops()


func param_kinds() -> Dictionary:
	return {"font": FxFontWidget.build}
