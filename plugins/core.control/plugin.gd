extends FxPlugin
## 控制流：分支 / 循环 / 序列 / 索引 / 累积。执行流由 exec 端口驱动。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsControl.ops()
