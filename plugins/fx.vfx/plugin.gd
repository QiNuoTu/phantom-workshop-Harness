extends FxPlugin
## 特效生成器 —— 节点 / 算子 / 时间依赖声明全部由声明生成。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsVfx.ops()


func time_dependent_ops() -> Array:
	return ["image.shockwave", "image.flame", "image.lightning", "image.sparks", "image.rays"]
