extends FxPlugin
## 插件中心：面板 + 浮动窗口 + 命令 + 注入到所有面板/菜单的新功能。

func panels() -> Array[Dictionary]:
	return [{
		"id": "plugin.hub", "title": "插件中心", "area": "right",
		"order": 900, "factory": FxPluginHubApi.make_panel,
		"min_size": [300, 320],
	}]


func windows() -> Array[Dictionary]:
	return [{
		"id": "plugin.hub.window", "title": "插件中心 · 信息与设置",
		"factory": FxPluginHubApi.make_panel, "size": [720, 620], "singleton": true,
	}]


func commands() -> Array[Dictionary]:
	return [
		{"id": "plugins.hub.open", "label": "插件中心", "shortcut": "Ctrl+Shift+P",
			"handler": FxPluginHubApi.open},
		{"id": "panel.feature.detach", "label": "分离当前面板",
			"handler": FxPluginHubApi.detach_panel},
		{"id": "panel.feature.detach_native", "label": "分离为独立窗口",
			"handler": FxPluginHubApi.detach_panel_native},
		{"id": "quality.preset.cycle", "label": "轮换质量预设",
			"handler": FxPluginHubApi.cycle_preset},
	]


## 「插件」菜单里**只留一条**入口；面板的 ⋯ 菜单由 panel_features 注入，不再重复进菜单。
func menu_items() -> Array[Dictionary]:
	return [{
		"menu": "plugins", "label": "插件中心…",
		"command": "plugins.hub.open", "order": 15,
	}]


## 只有一项：列表放左边还是右边。列表项与详情互换不影响任何逻辑，纯偏好。
func settings() -> Array[Dictionary]:
	return [{
		"id": "ui.hub_list_right", "label": "插件列表放在右侧", "group": "常规",
		"kind": "bool", "default": false, "applies": "none", "order": 60,
		"description": "关闭时列表在左、详情在右；标题栏的 ⇄ 按钮也能一键互换",
	}]


## target="*" 表示注入到**所有**面板（插件面板与随软件发布的面板一视同仁）。
## 带 menu 的项同时出现在顶部菜单里，无需插件认识菜单实现。
##
## 分离 / 独立窗口这两项由基座的停靠区自己提供（右键标签就有），插件不再重复注入，
## 否则面板菜单里会出现两条一模一样的「分离」。
func panel_features() -> Array[Dictionary]:
	return [
		# 不带 menu 的项只进面板标题菜单，因此顶部菜单里不会出现第二条「插件中心」。
		{"target": "*", "label": "插件中心…", "command": "plugins.hub.open", "order": 20},
		{"target": "*", "label": "轮换质量预设", "command": "quality.preset.cycle",
			"menu": "window", "order": 30},
	]
