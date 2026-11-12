extends FxPlugin
## 多语言：语言包、设置项、命令全部是声明式贡献。
## 其它插件可以用 locales() 叠加同语言词条，不需要改这里。

func locales() -> Array[Dictionary]:
	return FxI18nPacks.locales()


func settings() -> Array[Dictionary]:
	return FxI18nApi.settings()


func capabilities() -> Array[Dictionary]:
	return FxI18nApi.capabilities()


func commands() -> Array[Dictionary]:
	return [{
		"id": "i18n.cycle", "label": "切换界面语言",
		"shortcut": "Ctrl+Shift+L", "handler": FxI18nApi.cycle,
	}]


## 只有一个入口：菜单里重复指向「设置中心」的项会让人以为有两套设置。
func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "window", "label": "切换界面语言", "command": "i18n.cycle", "order": 3},
	]
