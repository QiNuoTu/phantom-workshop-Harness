extends FxPlugin
## 拖拽导入：文件落到蓝图画布上 → 变成纹理 / 序列帧节点。
##
## 本插件只贡献一个「拖拽处理器」，蓝图那边通过 FxDropBroker 找它，
## 因此停用本插件后拖拽自然失效，蓝图不需要任何改动。

func drop_handlers() -> Array[Dictionary]:
	return [{
		"id": "editor.dropimport.image",
		"order": 10,
		"extensions": FxDropImport.EXTENSIONS,
		"handler": FxDropImport.handle,
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "import.texture",
		"label": "导入纹理…",
		"category": "导入",
		"handler": FxDropImport.cmd_import,
	}]


## 挂在「文件」菜单里：不拖拽也能导入（菜单由 editor.document 定义，这里只加条目）。
func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "file", "label": "", "separator": true, "order": 60},
		{"menu": "file", "label": "导入纹理…", "command": "import.texture", "order": 62},
	]
