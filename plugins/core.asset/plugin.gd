extends FxPlugin
## pixelfx 序列帧素材节点；同时注册 pixelfx 参数控件（素材库选择）。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsAsset.ops().merged(FxOpsTexture.ops(), true)


func time_dependent_ops() -> Array:
	return [&"image.pixelfx", &"image.sheet"]


func param_kinds() -> Dictionary:
	return {"pixelfx": FxPixelfxWidget.build, "texture": FxTextureWidget.build}
