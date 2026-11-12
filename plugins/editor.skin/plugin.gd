extends FxPlugin
## 外壳视觉插件：皮肤、停靠容器、皮肤切换命令、窗口菜单定义。
##
## 基座只保留「契约 + 最小默认」：FxSkin 基类、FxUiKit 门面、
## FxDockArea 默认实现。真正可选的视觉方案全部在这里，
## 停用本插件后工作台回落到默认深色，不影响任何功能。

func skins() -> Array[Dictionary]:
	return [
		{"id": "dark", "name": "暗色 · 琥珀", "order": 10, "factory": FxEditorSkins.dark},
		{"id": "light", "name": "浅色 · 纸面", "order": 20, "factory": FxEditorSkins.light},
		{"id": "contrast", "name": "高对比 · 无障碍", "order": 30, "factory": FxEditorSkins.contrast},
	]


func dock_factories() -> Array[Dictionary]:
	return [
		{"id": "compact", "name": "紧凑", "order": 10, "factory": FxCompactDock.create},
	]


func menus() -> Array[Dictionary]:
	return [{"id": "window", "title": "窗口", "order": 45}]


func commands() -> Array[Dictionary]:
	return [
		{"id": "skin.cycle", "label": "切换皮肤", "shortcut": "Ctrl+Shift+T",
			"category": "视图", "handler": FxSkinCommands.cycle},
		{"id": "window.toggle_bottom", "label": "折叠 / 展开底部", "shortcut": "Ctrl+Shift+B",
			"category": "窗口", "handler": FxSkinCommands.toggle_bottom},
	]


func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "window", "label": "切换皮肤", "command": "skin.cycle", "order": 10,
			"shortcut": "Ctrl+Shift+T"},
		{"menu": "window", "label": "折叠 / 展开底部", "command": "window.toggle_bottom",
			"order": 11, "shortcut": "Ctrl+Shift+B"},
	]
