extends FxPlugin
## 图领域组件：把目录 / 执行器 / 端口表 / 文档格式作为可替换的能力实现贡献出去。
## 蓝图层不 inject 本插件的键，只依赖基座提供的 graph.facade 代理键。

static func make_access() -> FxGraphAccess:
	return FxGraphAccessCore.new()


func graph_access() -> Array[Dictionary]:
	return [{
		"id": "core.graph",
		"label": "内置图求值器（FxGraphRunner）",
		"order": 10,
		"factory": make_access,
	}]


## 图属性节点（画布 / 时间轴）与子图节点（工程嵌套、预合成）。
func node_files() -> Array[String]:
	return [local("nodes.json"), local("nodes_subgraph.json")]


func ops() -> Dictionary:
	return {
		&"graph.canvas": FxOpsCanvas.canvas_info,
		&"graph.timeline": FxOpsCanvas.timeline_info,
		&"graph.subgraph": FxOpsSubgraph.render,
		&"graph.input": FxOpsSubgraph.read_input,
		&"graph.output": FxOpsSubgraph.write_output,
	}


## 子图读外层播放头，时间轴节点直接输出当前时间，边界节点的值来自外层连线：
## 这几个都不能吃跨帧缓存，否则会拿到上一帧/上一次的边界值。
func time_dependent_ops() -> Array:
	return [&"graph.subgraph", &"graph.timeline", &"graph.input", &"graph.output"]


## 子图路径控件：一行内完成路径、浏览与健康检查。
func param_kinds() -> Dictionary:
	return {"graph": FxGraphPathWidget.build}
