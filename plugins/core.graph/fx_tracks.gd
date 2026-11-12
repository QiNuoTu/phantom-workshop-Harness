class_name FxTracks
extends RefCounted
## 关键帧轨道：把"某个属性随时间变化"变成纯函数，任何数值参数都能打关键帧。
##
## 配方里的一个参数可以是：
##   10.0                      固定值
##   [3.0, 18.0]               区间（每个粒子随机取）
##   {"track": [[0, 3], [.5, 18], [1, 3]]}              数值轨道
##   {"track": [[0, [3, 18]], [1, [6, 30]]]}            区间轨道（可同时动画 min/max）
##
## 采样是线性的：轨道之外取端点值，保证"任意 t 都可求值"，因此仍然可逐帧 scrub / 烘焙。

const EPSILON: float = 0.000001

## 值里是否含轨道（用于 configure 时决定要不要每帧解析）。
static func has_track(value: Variant) -> bool:
	if value is Dictionary:
		var dict: Dictionary = value
		if dict.has("track"):
			return true
		for key in dict.keys():
			if has_track(dict[key]):
				return true
	elif value is Array:
		for item in value:
			if has_track(item):
				return true
	return false


## 按时间采样。非轨道值原样返回（包括 Array / Dictionary）。
##
## 嵌套字典也要递归采样：图层的 transform 是一个子字典（position/rotation/…），
## 其中任意字段都可以是轨道。以前这里只认"自己带 track 的字典"，
## 于是 transform.position 打了帧也永远返回整条轨道，引擎拿到 Dictionary 就废了。
static func sample(value: Variant, t: float) -> Variant:
	if value is Dictionary:
		var dict: Dictionary = value
		if dict.has("track"):
			return _sample_track(dict, t)
		if not has_track(dict):
			return dict
		var out: Dictionary = {}
		for key in dict.keys():
			out[key] = sample(dict[key], t)
		return out
	return value


## 逐帧把一层里所有轨道替换成采样值，返回新的层（不改写原配方）。
##
## 注意必须返回**完整层**：引擎拿它直接当"这一层的参数表"用。
## 以前这里只返回带轨道的键，结果只要配方里有任何一条轨道，
## 所有图层都会退化成"只剩那几个键"的残缺层（type/count/size 全丢，
## 画面变成一个 31 像素的点）—— 全功能案例第一次跑就把它揪出来了。
static func resolve_layer(layer: Dictionary, t: float) -> Dictionary:
	var out: Dictionary = layer.duplicate(false)
	for key in layer.keys():
		var value: Variant = layer[key]
		if key == "child" and value is Dictionary:
			out[key] = resolve_layer(value as Dictionary, t)
		elif has_track(value):
			out[key] = sample(value, t)
	return out


static func _sample_track(track: Dictionary, t: float) -> Variant:
	var keys: Array = track["track"]
	if keys.is_empty():
		return 0.0
	if keys.size() == 1:
		return _key_value(keys[0])
	var mode: String = String(track.get("interp", "linear"))
	var first: Array = keys[0]
	if t <= float(first[0]):
		return _key_value(first)
	var last: Array = keys[keys.size() - 1]
	if t >= float(last[0]):
		return _key_value(last)
	for i in range(1, keys.size()):
		var b: Array = keys[i]
		var a: Array = keys[i - 1]
		var t0: float = float(a[0])
		var t1: float = float(b[0])
		if t <= t1 + EPSILON:
			var span: float = maxf(t1 - t0, EPSILON)
			var u: float = clampf((t - t0) / span, 0.0, 1.0)
			if mode == "step":
				u = 0.0
			elif mode == "ease":
				u = u * u * (3.0 - 2.0 * u)
			return _mix(_key_value(a), _key_value(b), u)
	return _key_value(last)


static func _key_value(key: Variant) -> Variant:
	if key is Array and (key as Array).size() >= 2:
		return (key as Array)[1]
	return 0.0


static func _mix(a: Variant, b: Variant, u: float) -> Variant:
	# 颜色在文档里是十六进制字符串（JSON 安全），以前被当成普通文本按「到下一帧才切换」
	# 处理，于是颜色轨道永远没有过渡。这里先把两端解析成 Color 再插值。
	var ca: Variant = _as_color(a)
	var cb: Variant = _as_color(b)
	if ca is Color and cb is Color:
		var mixed: Color = (ca as Color).lerp(cb as Color, u)
		return mixed.to_html() if (a is String or b is String) else mixed
	# 等长且全是数字的数组（vec2 / rgb / 区间）逐元素插值。
	if a is Array and b is Array and (a as Array).size() == (b as Array).size():
		var aa: Array = a
		var bb: Array = b
		var out: Array = []
		var numeric: bool = true
		for i in range(aa.size()):
			if (aa[i] is float or aa[i] is int) and (bb[i] is float or bb[i] is int):
				out.append(lerpf(float(aa[i]), float(bb[i]), u))
			else:
				numeric = false
				break
		if numeric:
			return out
	# 文本 / 布尔不是连续量：按“到下一帧才切换”处理，避免 float("abc") 崩溃。
	if a is String or b is String:
		return a if u < 1.0 else b
	if a is bool or b is bool:
		return a if u < 0.5 else b
	if a is Array:
		return a
	if b is Array:
		return b
	return lerpf(float(a), float(b), u)


## 把 "#ff0000" / "#ff0000ff" / "(r, g, b, a)" 这类文档里的颜色文本转成 Color。
## 解析不了返回 null，让 _mix 继续按普通文本处理。
static func _as_color(value: Variant) -> Variant:
	if value is Color:
		return value
	if value is String:
		var text: String = String(value).strip_edges()
		# 兼容三种历史写法："#rrggbb"、"rrggbb"(Color.to_html 的裸写法)、"(r, g, b, a)"。
		if text.begins_with("#") or text.begins_with("(") or _looks_like_hex(text):
			var parsed: Color = Color.from_string(text, Color(-1, -1, -1, -1))
			if parsed.r >= 0.0:
				return parsed
	return null


## 6 / 8 位十六进制（不带 '#'）：Color.to_html() 的输出形态。
## 只认纯十六进制字符，避免把 "abcdef" 这种普通文本误判成颜色。
static func _looks_like_hex(text: String) -> bool:
	if text.length() != 6 and text.length() != 8:
		return false
	for i in range(text.length()):
		var code := text.unicode_at(i)
		var is_digit := code >= 48 and code <= 57
		var is_lower := code >= 97 and code <= 102
		var is_upper := code >= 65 and code <= 70
		if not (is_digit or is_lower or is_upper):
			return false
	return true


## 取轨道的第一帧数值（"清除关键帧"时还原成静态值）。
static func first(value: Variant) -> Variant:
	if value is Dictionary and (value as Dictionary).has("track"):
		var keys: Array = (value as Dictionary)["track"]
		if keys.size() > 0:
			return _key_value(keys[0])
		return 0.0
	return value


## 把一个"可能被打了帧"的值折叠成编译期常量。
##
## 画布尺寸、帧率、时长、种子这类字段是**结构性的**：它们决定缓冲区大小和总帧数，
## 不可能逐帧变化。但如果用户误给它们打了帧（UI 允许任何数值打帧），值会变成
## {"track": […]}, 而引擎会 float(Dictionary) 直接崩。所有读这类字段的地方都必须
## 先经过这里 —— 三层防线：schema 隐藏 ◆、compile 折叠、引擎兜底。
static func static_of(value: Variant, fallback: Variant = 0.0) -> Variant:
	if value is Dictionary and (value as Dictionary).has("track"):
		var folded: Variant = first(value)
		if folded is Dictionary:
			return fallback
		if folded is Array and (folded as Array).size() >= 1:
			return folded[0]
		return folded
	if value == null:
		return fallback
	return value


## static_of 的数值版：任何非法值都退化为 fallback，绝不抛错。
static func number(value: Variant, fallback: float = 0.0) -> float:
	var raw: Variant = static_of(value, fallback)
	if raw is Array:
		if (raw as Array).size() == 0:
			return fallback
		return float((raw as Array)[0])
	if raw is bool:
		return 1.0 if bool(raw) else 0.0
	if raw is String:
		return float(String(raw).to_float()) if String(raw).is_valid_float() else fallback
	return float(raw)


## static_of 的整数版（缓冲区尺寸 / 帧率 / 计数这类）。
static func integer(value: Variant, fallback: int = 0) -> int:
	return int(roundf(number(value, float(fallback))))


## 归一化轨道：排序、去重、夹在 [0, duration] 内。编辑器写回时调用。
static func normalize(track: Variant, duration: float) -> Array:
	if not track is Array:
		return []
	var keys: Array = []
	for entry in track:
		if not entry is Array or (entry as Array).size() < 2:
			continue
		keys.append([clampf(float(entry[0]), 0.0, maxf(duration, 0.0)), entry[1]])
	keys.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
	return keys


## 递归收集一棵配方/节点参数树里的所有轨道：{路径: {"track": […], "interp": …}}。
## 路径形如 "layers.2.amp"、"layers.2.child.cutoff"，与 FxCatalog.value_at 完全对齐；
## 面板列轨道、时间轴画轨道都走这一个函数，两边不会各算一套。
static func collect(node: Variant, prefix: String = "", depth: int = 0) -> Dictionary:
	var out: Dictionary = {}
	if depth > 4:
		return out
	if node is Dictionary:
		var dict: Dictionary = node
		for key in dict.keys():
			var value: Variant = dict[key]
			var path: String = String(key) if prefix == "" else "%s.%s" % [prefix, String(key)]
			if value is Dictionary and (value as Dictionary).has("track"):
				var def: Dictionary = (value as Dictionary).duplicate(false)
				# track 键存在但值不是数组（历史文档/手写 JSON）：就地归一，别把 Nil 往下传
				if not (def["track"] is Array):
					def["track"] = []
				out[path] = def
			elif value is Dictionary or value is Array:
				out.merge(collect(value, path, depth + 1))
	elif node is Array:
		var arr: Array = node
		for i in range(arr.size()):
			if arr[i] is Dictionary or arr[i] is Array:
				out.merge(collect(arr[i], "%s.%d" % [prefix, i], depth + 1))
	return out


## 便捷构造：轨道 + 在当前时刻插入/替换关键帧。
static func upsert(track: Array, t: float, value: Variant, duration: float) -> Array:
	var keys: Array = []
	for entry in track:
		if entry is Array and (entry as Array).size() >= 2:
			if absf(float(entry[0]) - t) < 0.02:
				continue
			keys.append([float(entry[0]), entry[1]])
	keys.append([t, value])
	return normalize(keys, duration)
