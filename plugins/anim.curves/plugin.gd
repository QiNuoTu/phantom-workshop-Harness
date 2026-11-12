extends FxPlugin
## 动画曲线 —— 节点 / 算子 / 时间依赖声明全部由声明生成。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsAnimCurves.ops()


func time_dependent_ops() -> Array:
	return ["anim.ease", "anim.oscillator", "anim.pulse", "anim.steps", "anim.noise1d", "anim.remap"]
