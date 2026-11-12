extends FxPlugin
## 设置中心：只贡献「一个窗口 + 一个命令 + 菜单项」，表单由账本生成。

func windows() -> Array[Dictionary]:
	return [{
		"id": "settings.window", "title": "设置", "factory": FxSettingsApi.make_panel,
		"size": [820, 600], "singleton": true,
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "settings.open", "label": "打开设置", "shortcut": "Ctrl+,",
		"handler": FxSettingsApi.open,
	}]


func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "edit", "label": "设置…", "command": "settings.open", "order": 900},
		{"menu": "window", "label": "设置中心…", "command": "settings.open", "order": 2},
	]
