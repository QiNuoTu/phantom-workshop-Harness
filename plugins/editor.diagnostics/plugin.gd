extends FxPlugin
## 归因诊断插件：一行命令把问题判给内核 / 具体插件 / 装配。
##
## 它不修任何东西，只回答一个问题：**这锅该谁背**。
## 判断依据全部来自公开契约（账本、注册表、启动报告、目录、工程文档），
## 因此插件停用后它自己也干净消失，不会在基座留下半截钩子。
##
## 两个层次的归因：
##   diag.blame   —— 看**装配**：谁引用谁、谁的贡献缺了、版本区间是否成立；
##   diag.project —— 看**工程**：某个 .fxproj 里的节点/连线/参数有没有着落。
##
## `fx_project_report.gd` 用 preload 而不是 `class_name`：新加的 `class_name`
## 要等编辑器把文件扫进全局类名缓存才可用，无头首次运行会解析不到
## （见 docs/插件开发.md §7「插件脚本无法加载」）。
## 路径写 res:// 全量而不是相对名：GDScript 的相对 preload 解析成 `gdscript://`，
## 找不到文件；插件目录名必须等于 plugin.json 的 id（宿主按此扫描），所以这条路径稳定。
const PROJECT_REPORT := preload("res://plugins/editor.diagnostics/fx_project_report.gd")
const ABI_REPORT := preload("res://plugins/editor.diagnostics/fx_abi_report.gd")
const DEPS_REPORT := preload("res://plugins/editor.diagnostics/fx_deps_report.gd")


## 只读解析工程的**唯一实现**（`fx_project_report.gd`）。
## 以能力键暴露而不是让调用方引用本插件的类：
##   · 消费方（如 core.compile 的 `diag.compile --fx-arg`）查不到能力时优雅退化；
##   · 停用本插件不会让别人的脚本解析失败 —— 这是 capabilities 相对 class_name 的价值。
func capabilities() -> Array[Dictionary]:
	return [{
		"key": "project.read",
		"apply": PROJECT_REPORT.read_project,
		"order": 20,
		"description": "只读解析 .fxproj / .fxgraph（不打开、不解素材、不动工作台）",
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "diag.blame",
		"label": "归因诊断（内核 / 插件）",
		"category": "调试",
		"handler": FxBlame.cmd_report,
	}, {
		"id": "diag.project",
		"label": "工程诊断（打开 .fxproj 查归因）",
		"category": "调试",
		"handler": PROJECT_REPORT.cmd_report,
	}, {
		"id": "diag.abi",
		"label": "原生实况（库 / 族 / 线程）",
		"category": "调试",
		"handler": ABI_REPORT.cmd_report,
	}, {
		"id": "diag.deps",
		"label": "依赖索引（停用它掉什么）",
		"category": "调试",
		"handler": DEPS_REPORT.cmd_report,
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
	}, {
		"menu": "help", "label": "工程诊断（当前工程）",
		"command": "diag.project", "order": 42,
	}, {
		"menu": "help", "label": "原生实况（库 / 族 / 线程）",
		"command": "diag.abi", "order": 43,
	}, {
		"menu": "help", "label": "依赖索引（停用它掉什么）",
		"command": "diag.deps", "order": 44,
	}]
