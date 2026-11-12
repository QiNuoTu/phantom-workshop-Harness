class_name FxI18n
extends RefCounted
## 多语言内核（论文 §6.2 的服务代理 + §3.2 的反应式 coeffect）。
##
## 基座只提供「键 → 译文」的解析与订阅，不内置任何语言包；语言包由插件贡献，
## 多个插件可以叠加同一语言（按 order 合并），卸载插件时贡献自动撤回。
## 键本身是可读的源语言字符串，所以未翻译的文案天然回落成原文，不会漏字。
##
## ctx 里所有可见文案都在消费点（菜单/面板/窗口/命令/状态）统一经过 text()，
## 因此插件不需要改自己的代码就能被翻译；插件也可以自己调 text() 翻译节点标签。

static var locale: String = "zh_CN"
static var _packs: Dictionary = {}
static var _subs: Array[Callable] = []
static var _loaded_revision: int = -1


static func reload() -> void:
	_packs.clear()
	var entries: Array[Dictionary] = []
	for entry in FxRegistry.locales:
		entries.append(entry)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	for entry in entries:
		var code := String(entry.get("locale", ""))
		if code.is_empty():
			continue
		if not _packs.has(code):
			_packs[code] = {}
		var table: Dictionary = _packs[code]
		var words: Variant = entry.get("entries", {})
		if words is Dictionary:
			for key in (words as Dictionary).keys():
				table[String(key)] = String((words as Dictionary)[key])
	_loaded_revision = FxRegistry.revision


static func _ensure() -> void:
	if _loaded_revision != FxRegistry.revision:
		reload()


static func definitions() -> Array[Dictionary]:
	_ensure()
	var seen: Dictionary = {}
	var out: Array[Dictionary] = []
	for entry in FxRegistry.locales:
		var code := String(entry.get("locale", ""))
		if code.is_empty() or seen.has(code):
			continue
		seen[code] = true
		out.append({"locale": code, "name": String(entry.get("name", code))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("locale", "")) < String(b.get("locale", "")))
	return out


static func locale_ids() -> Array[String]:
	var out: Array[String] = []
	for def in definitions():
		out.append(String(def.get("locale", "")))
	return out


## 回退链：en_US → en → zh_CN（源语言）。同语系的其它包也能命中。
static func chain(code: String) -> Array[String]:
	var out: Array[String] = []
	if not code.is_empty():
		out.append(code)
	var short := code.split("_")[0]
	if not short.is_empty() and short != code and not out.has(short):
		out.append(short)
	for fallback in ["zh_CN", "zh"]:
		if not out.has(fallback):
			out.append(fallback)
	return out


static func text(key: String, vars: Dictionary = {}) -> String:
	_ensure()
	if key.is_empty():
		return key
	var out := key
	for code in chain(locale):
		if not _packs.has(code):
			continue
		var table: Dictionary = _packs[code]
		if table.has(key):
			out = String(table[key])
			break
	if vars.is_empty():
		return out
	for name in vars.keys():
		out = out.replace("{%s}" % String(name), str(vars[name]))
	return out


static func has_translation(key: String) -> bool:
	_ensure()
	for code in chain(locale):
		if _packs.has(code) and (_packs[code] as Dictionary).has(key):
			return true
	return false


static func coverage() -> int:
	_ensure()
	if not _packs.has(locale):
		return 0
	return (_packs[locale] as Dictionary).size()


static func set_locale(value: Variant) -> void:
	var code := str(value)
	if code.is_empty() or code == locale:
		return
	locale = code
	reload()
	for callback in _subs.duplicate():
		if callback.is_valid():
			callback.call(code)


static func cycle() -> void:
	var ids := locale_ids()
	if ids.is_empty():
		return
	var index := ids.find(locale)
	var next := ids[(index + 1) % ids.size()]
	FxSettings.set_value("general.locale", next)


static func subscribe(callback: Callable) -> Callable:
	if callback.is_valid() and not _subs.has(callback):
		_subs.append(callback)
	return func() -> void:
		_subs.erase(callback)
