extends FxPlugin
## 图像来源节点包：纯色 / 棋盘 / 噪声 / 图片文件。
## 同时注册 asset 参数控件（图片路径 + 文件选择）。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsSource.ops()


func param_kinds() -> Dictionary:
	return {"asset": FxAssetWidget.build}
