extends FxPlugin
## 归因诊断插件：一行命令把问题判给内核 / 具体插件 / 装配。
##
## 它不修任何东西，只回答一个问题：**这锅该谁背**。
## 判断依据全部来自公开契约（账本、注册表、启动报告、目录），因此插件停用后
## 它自己也干净消失，不会在基座留下半截钩子。

func commands() -> Array[Dictionary]:
	return [{
		"id": "diag.blame",
		"label": "归因诊断（内核 / 插件）",
		"category": "调试",
		"handler": FxBlame.cmd_report,
	}, {
		"id": "diag.cache",
		"label": "帧缓存归因（谁在重建）",
		"category": "调试",
		"handler": FxCacheReport.cmd_report,
	}]


func menu_items() -> Array[Dictionary]:
	return [{
		"menu": "help", "label": "归因诊断（内核 / 插件）",
		"command": "diag.blame", "order": 40,
	}, {
		"menu": "help", "label": "帧缓存归因（谁在重建）",
		"command": "diag.cache", "order": 41,
	}]
