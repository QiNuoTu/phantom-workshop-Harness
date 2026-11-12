extends FxPlugin
## 常驻皮肤管理器插件：注册「窗口 → 皮肤管理…」入口与浮动窗口。
## 皮肤本身由别的插件提供，管理器只负责发现、互斥切换、选项表单与持久化。

func windows() -> Array[Dictionary]:
	return [{
		"id": "skin.manager.window", "title": "皮肤管理", "order": 10,
		"factory": FxSkinManagerWindow.create,
		"size": Vector2i(840, 600), "singleton": true,
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "skin.manager.open", "label": "皮肤管理…", "shortcut": "Ctrl+Shift+K",
		"category": "窗口", "handler": FxSkinManagerWindow.cmd_open,
	}]


func menu_items() -> Array[Dictionary]:
	return [{
		"menu": "window", "label": "皮肤管理…", "command": "skin.manager.open",
		"order": 1, "shortcut": "Ctrl+Shift+K",
	}]
