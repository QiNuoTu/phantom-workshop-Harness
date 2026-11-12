extends FxPlugin
## 合成与边缘 —— 节点 / 算子 / 时间依赖声明全部由声明生成。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsComposite.ops()
