extends FxPlugin
## 图编译与剪枝：把节点图降级成 DAG 指令序列，做类型检查、常量折叠、
## 按 Live 判活，再以**纯数据计划**交给求值器。
##
## 为什么要做成独立插件：用户第 3 点「运行时没有剪枝」是执行层的事，
## 基座不该认识「拓扑排序」「常量折叠」这些概念。停用本插件后
## FxRenderService 查不到 graph.compile 能力，计划为空，求值器自动走原行为。
##
## 所有贡献都是静态 Callable，停用即消失，不在基座留钩子。


## 查询型能力：渲染服务用 FxCapabilities.providers("graph.compile") 取 handler，
## 调 compile(doc, roots) 得到 Dictionary 计划。这里不用 services()，因为
## services 的工厂会被外壳当成「创建实例」调用一次，签名不匹配。
func capabilities() -> Array[Dictionary]:
	return [{
		"key": "graph.compile", "apply": FxIRCompiler.compile, "order": 10,
		"description": "节点图 → DAG / 类型检查 / 常量折叠 / Live 剪枝计划",
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "diag.compile",
		"label": "IR 编译与剪枝报告",
		"category": "调试",
		"handler": FxIRReport.cmd_report,
	}]


func menu_items() -> Array[Dictionary]:
	return [{
		"menu": "help", "label": "IR 编译与剪枝报告",
		"command": "diag.compile", "order": 42,
	}]


func status_fragments() -> Array[Dictionary]:
	return [{
		"id": "graph.ir", "order": 25,
		"handler": FxIRReport.fragment,
		"diagnostic": FxIRReport.diagnostic,
	}]
