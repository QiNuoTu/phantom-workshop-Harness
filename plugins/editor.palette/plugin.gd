extends FxPlugin
## 命令面板：一个窗口 + 一个命令，演示插件注册窗口。

func windows() -> Array[Dictionary]:
	return [{
		"id": "editor.palette",
		"title": "命令面板",
		"size": Vector2i(720, 480),
		"factory": FxCommandPalette.create,
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "palette.open",
		"label": "命令面板…",
		"shortcut": "Ctrl+P",
		"category": "视图",
		"handler": FxCommandPalette.cmd_open,
	}]


func menu_items() -> Array[Dictionary]:
	return [{"menu": "view", "label": "命令面板…", "command": "palette.open", "order": 700, "shortcut": "Ctrl+P"}]


func toolbar() -> Array[Dictionary]:
	return [{"label": "命令", "command": "palette.open", "order": 500, "shortcut": "Ctrl+P"}]
