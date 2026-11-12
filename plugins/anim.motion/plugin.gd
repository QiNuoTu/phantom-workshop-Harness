extends FxPlugin
## 动画运动 —— 节点 / 算子 / 时间依赖声明全部由声明生成。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsAnimMotion.ops()


func time_dependent_ops() -> Array:
	return ["anim.orbit", "anim.shake", "anim.path", "anim.spring"]
