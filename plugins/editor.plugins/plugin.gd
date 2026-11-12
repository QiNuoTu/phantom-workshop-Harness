extends FxPlugin
## 插件维护：重新扫描 / 打开用户插件目录。
##
## 浏览、启停、设置统一由 editor.plugin-hub（插件中心）提供，避免两个重复界面；
## 这里只保留「运维动作」，命令可以被插件中心、菜单和命令面板调用。

func commands() -> Array[Dictionary]:
	return [
		{"id": "plugins.rescan", "label": "重新扫描插件", "category": "插件",
			"handler": FxPluginManager.cmd_rescan},
		{"id": "plugins.open_user_dir", "label": "打开用户插件目录", "category": "插件",
			"handler": FxPluginManager.cmd_open_user_dir},
	]


func menus() -> Array[Dictionary]:
	return [{"id": "plugins", "title": "插件", "order": 50}]


func menu_items() -> Array[Dictionary]:
	# 「插件中心」入口由 editor.plugin-hub 提供，这里只放运维动作，避免同一个菜单里出现两条一样的项。
	return [
		{"menu": "plugins", "label": "", "separator": true, "order": 30},
		{"menu": "plugins", "label": "重新扫描插件", "command": "plugins.rescan", "order": 40},
		{"menu": "plugins", "label": "打开用户插件目录", "command": "plugins.open_user_dir", "order": 50},
	]


func toolbar() -> Array[Dictionary]:
	return [{"label": "插件", "command": "plugins.hub.open", "order": 400, "separator": true}]
