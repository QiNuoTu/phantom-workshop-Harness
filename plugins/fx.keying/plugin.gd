extends FxPlugin
## 抠像 —— 节点定义 + 两个"给美工"的 UI 贡献；算子实现全部在原生包 `fx.native-kit`。
##
## 这里保留的三样东西都不是像素运算：
##   · nodes.json   节点定义（端口、参数、范围、文案）；
##   · keycolor     参数控件（一排常用键色，点一下就换）；
##   · 抠像台面板   在画面上点一下取 3×3 平均色写进选中节点。
##
## 算子（含抓色、去溢色、蒙版清理）在 C++ 里，所以本插件没有 `ops()`。
## 一份实现、一份测试、一份性能读数 —— 不存在"原生没加载时走慢路径"的第二条路。
##
## 脚本一律用 preload 而不是 `class_name`：新加的类名要等编辑器扫进全局类名缓存
## 才可用，无头首次运行会解析不到（docs/插件开发.md §5.1）。

const KEY_COLOR := preload("res://plugins/fx.keying/fx_keycolor_widget.gd")
const KEYER_PANEL := preload("res://plugins/fx.keying/fx_keyer_panel.gd")


func node_files() -> Array[String]:
	return [local("nodes.json")]


func param_kinds() -> Dictionary:
	return {"keycolor": KEY_COLOR.build}


func panels() -> Array[Dictionary]:
	return [{
		"id": "fx.keying.stage",
		"title": "抠像台",
		"area": "right",
		"order": 60,
		"factory": KEYER_PANEL.build,
		"min_size": Vector2(240, 300),
	}]
