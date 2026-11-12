extends FxPlugin
## 帮助：快捷键表 + 关于窗口。快捷键表由命令注册表自动生成。

func windows() -> Array[Dictionary]:
	return [{
		"id": "editor.help.window",
		"title": "快捷键与关于",
		"size": Vector2i(640, 560),
		"factory": FxHelpPanel.create,
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "help.open",
		"label": "快捷键与关于",
		"shortcut": "F1",
		"category": "帮助",
		"handler": FxHelpPanel.cmd_open,
	}]


func menus() -> Array[Dictionary]:
	return [{"id": "help", "title": "帮助", "order": 90}]


func menu_items() -> Array[Dictionary]:
	return [{"menu": "help", "label": "快捷键与关于", "command": "help.open", "order": 10, "shortcut": "F1"}]
