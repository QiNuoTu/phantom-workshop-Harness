extends FxPlugin
## 数值 / 逻辑节点：比较与布尔是分支节点的条件来源。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsMath.ops()
