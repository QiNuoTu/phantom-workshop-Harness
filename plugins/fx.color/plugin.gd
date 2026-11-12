extends FxPlugin
## 调色与色彩映射 —— 节点 / 算子 / 时间依赖声明全部由声明生成。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsColor.ops()
