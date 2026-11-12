class_name FxSettings
extends RefCounted
## 声明式配置（论文 §5.2.1 / Definition 74）。
##
## 插件只贡献「设置条目」；基座不认识任何具体设置，只负责：
##   · 持久化到 user://settings.cfg ——§6.1 把外部位置重化进系统边界；
##   · 按条目的 kind / min / max / options 校验与夹取；
##   · 变化时做**按字段的最小协调**：applies="runtime" 只改运行时，
##     "ui" 才重建界面，"none" 只存值（§5.2.1 的 per-field dispatch）；
##   · 双向绑定：组件也能反过来写自己的 config，写回即广播给其它订阅者。
##
## 值不属于 FxRegistry 的 ledger：ledger 是「谁贡献了什么」的声明式配置，
## 运行时的取值是它的 realized state，停用插件时定义消失、取值保留到下次启用。
## 所有订阅也带逆操作，交给 FxEffectScope 后随插件一起撤回。

const CONFIG_PATH := "user://settings.cfg"

static var _values: Dictionary = {}
static var _subs: Array[Callable] = []
static var _loaded: bool = false


static func ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_values.clear()
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK and cfg.has_section("values"):
		for key in cfg.get_section_keys("values"):
			_values[String(key)] = cfg.get_value("values", String(key))


static func definitions() -> Array[Dictionary]:
	return FxRegistry.settings.duplicate(true)


static func definition(id: String) -> Dictionary:
	return FxRegistry.setting(id)


static func value(id: String) -> Variant:
	ensure()
	if _values.has(id):
		return _values[id]
	return FxRegistry.setting(id).get("default")


static func has_value(id: String) -> bool:
	ensure()
	return _values.has(id)


static func typed_value(id: String, fallback: Variant) -> Variant:
	var v: Variant = value(id)
	return fallback if v == null else v


static func groups() -> Array[String]:
	var out: Array[String] = []
	for entry in FxRegistry.settings:
		var group := String(entry.get("group", "通用"))
		if not out.has(group):
			out.append(group)
	out.sort()
	return out


static func group_entries(group: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in FxRegistry.settings:
		if String(entry.get("group", "通用")) == group:
			out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


## 变化时通知所有订阅者：(id: String, value: Variant, applies: String)。
static func subscribe(callback: Callable) -> Callable:
	if callback.is_valid() and not _subs.has(callback):
		_subs.append(callback)
	return func() -> void:
		_subs.erase(callback)


static func set_value(id: String, raw: Variant) -> bool:
	ensure()
	var def := FxRegistry.setting(id)
	var clean: Variant = raw if def.is_empty() else coerce(def, raw)
	if _values.has(id) and _values[id] == clean:
		return false
	_values[id] = clean
	save()
	var applies := String(def.get("applies", "runtime"))
	var capability := String(def.get("capability", ""))
	if not capability.is_empty():
		FxCapabilities.dispatch(capability, clean)
	for callback in _subs.duplicate():
		if callback.is_valid():
			callback.call(id, clean, applies)
	return true


static func reset(id: String) -> void:
	ensure()
	_values.erase(id)
	save()
	var def := FxRegistry.setting(id)
	_notify(id, def.get("default"), String(def.get("applies", "runtime")),
		String(def.get("capability", "")))


static func reset_all() -> void:
	for entry in definitions():
		reset(String(entry.get("id", "")))


## 启动时把所有当前值推给能力代理，保证「插件后加载」也能拿到配置。
static func apply_all() -> void:
	ensure()
	for entry in FxRegistry.settings:
		var id := String(entry.get("id", ""))
		var capability := String(entry.get("capability", ""))
		if not capability.is_empty():
			FxCapabilities.dispatch(capability, value(id))


static func _notify(id: String, value: Variant, applies: String, capability: String) -> void:
	if not capability.is_empty():
		FxCapabilities.dispatch(capability, value)
	for callback in _subs.duplicate():
		if callback.is_valid():
			callback.call(id, value, applies)


static func save() -> void:
	var cfg := ConfigFile.new()
	for key in _values.keys():
		cfg.set_value("values", String(key), _values[key])
	cfg.save(CONFIG_PATH)


## 按条目声明把任意输入夹成合法值；未知 kind 原样保留。
static func coerce(def: Dictionary, raw: Variant) -> Variant:
	var kind := String(def.get("kind", "string"))
	match kind:
		"bool":
			if raw is bool:
				return raw
			if raw is int or raw is float:
				return float(raw) != 0.0
			return str(raw).to_lower() == "true" or str(raw) == "1"
		"int", "float":
			var number := float(raw)
			if def.has("min"):
				number = maxf(number, float(def["min"]))
			if def.has("max"):
				number = minf(number, float(def["max"]))
			return int(round(number)) if kind == "int" else number
		"enum":
			var options: Array = def.get("options", [])
			for option in options:
				var candidate: Variant = option.get("value", "") if option is Dictionary else option
				if candidate == raw or str(candidate) == str(raw):
					return candidate
			return def.get("default")
		"action":
			# 按钮型条目没有「值」可存；即便被误写也回落到默认值（通常是 null）。
			return def.get("default")
		"color", "string":
			return str(raw)
	return raw


static func option_label(def: Dictionary, raw: Variant) -> String:
	for option in def.get("options", []):
		var candidate: Variant = option.get("value", "") if option is Dictionary else option
		if candidate == raw or str(candidate) == str(raw):
			return str(option.get("label", candidate)) if option is Dictionary else str(candidate)
	return str(raw)


## 测试与「恢复出厂」用：清空内存与磁盘，但保留插件贡献的定义。
static func purge() -> void:
	_values.clear()
	_subs.clear()
	_loaded = false
	var cfg := ConfigFile.new()
	cfg.save(CONFIG_PATH)
