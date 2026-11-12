extends FxPlugin
## 图像处理与最终输出。
## output.final 的合成算法与图层算子同源，所以与图像处理放在同一个插件里。

func node_files() -> Array[String]:
	return [local("nodes_image.json"), local("nodes_output.json"), local("nodes_object.json")]


func ops() -> Dictionary:
	var image_ops: Dictionary = FxOpsImage.ops()
	image_ops.merge(FxOpsImageObject.ops(), true)
	return image_ops
