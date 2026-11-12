extends FxPlugin
## 几何扭曲 —— 节点 / 算子 / 时间依赖声明全部由声明生成。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsDistort.ops()


func time_dependent_ops() -> Array:
	return ["image.wave", "image.swirl", "image.pixelate", "image.mirror", "image.ripple"]
