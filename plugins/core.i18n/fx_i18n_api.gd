class_name FxI18nApi
extends RefCounted
## 多语言插件的静态入口：设置项、能力 provider、命令。

static func settings() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	for pack in FxI18nPacks.locales():
		options.append({
			"value": String(pack.get("locale", "")),
			"label": String(pack.get("name", "")),
		})
	return [{
		"id": "general.locale", "label": "界面语言", "group": "常规",
		"kind": "enum", "default": "zh_CN", "options": options,
		"capability": "i18n.locale", "applies": "ui", "order": 1,
		"description": "语言包由插件贡献；切换时只重建界面文字，不动文档与撤销栈。",
	}]


static func capabilities() -> Array[Dictionary]:
	return [{
		"key": "i18n.locale", "apply": set_locale, "order": 10,
		"description": "把语言选择交给 FxI18n，后者重新合并语言包并广播。",
	}]


static func set_locale(value: Variant) -> void:
	FxI18n.set_locale(value)


static func cycle(_ctx: Dictionary) -> void:
	FxI18n.cycle()


static func open_settings(ctx: Dictionary) -> void:
	FxSettingsApi.open(ctx)
