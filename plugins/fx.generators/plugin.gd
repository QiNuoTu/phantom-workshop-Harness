extends FxPlugin
## 程序化图像生成 —— 节点 / 算子 / 时间依赖声明全部由声明生成。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsGenerators.ops()
