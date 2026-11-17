class_name FxValue
extends RefCounted
## 值归一化：把文档里 JSON 安全的写法（数字 / 布尔 / 字符串 / 数组 / 字典）
## 收敛成界面与执行器要的类型。
##
## 为什么放在基座而不是 core.graph：
## 这不是图领域知识，是「Variant → 标量」的通用转换。它原本长在 `FxPortType` 里，
## 于是基座的控件工厂必须写 `FxPortType.as_number(...)` —— 而 `class_name` 是
## **编译期**全局符号，停用 core.graph 后 `scripts/graph` 连解析都过不了。
## 现在方向反过来：`FxPortType.as_*` 与 `FxTransform.vec2_of` 都委托到这里，
## 语义只有一份，插件侧公开 API 不变。
##
## 约定：任何非法值都退化为 fallback，绝不抛错（界面每帧都可能拿它同步控件）。


## 数值。数组取首元素，布尔按 0/1，字符串只在合法数字时采用。
static func as_number(value: Variant, fallback: float = 0.0) -> float:
	if value is float:
		return value
	if value is int:
		return float(value)
	if value is bool:
		return 1.0 if bool(value) else 0.0
	if value is String:
		var text := String(value).strip_edges()
		return text.to_float() if text.is_valid_float() else fallback
	if value is Array:
		var arr: Array = value
		return fallback if arr.is_empty() else as_number(arr[0], fallback)
	return fallback


static func as_int(value: Variant, fallback: int = 0) -> int:
	return int(roundf(as_number(value, float(fallback))))


static func as_bool(value: Variant, fallback: bool = false) -> bool:
	if value is bool:
		return value
	if value is int or value is float:
		return absf(float(value)) > 0.0001
	if value is String:
		var text := String(value).strip_edges().to_lower()
		if text == "true" or text == "yes" or text == "1":
			return true
		if text == "false" or text == "no" or text == "0" or text.is_empty():
			return false
	return fallback


static func as_string(value: Variant, fallback: String = "") -> String:
	if value == null:
		return fallback
	return str(value)


## 颜色：Color / 十六进制字符串 / 长度 ≥3 的数组（分量按 0..1 解释并夹取）。
static func as_color(value: Variant, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value
	if value is String:
		return Color.from_string(String(value), fallback)
	if value is Array:
		var arr: Array = value
		if arr.size() >= 3:
			return Color(
				clampf(as_number(arr[0], 0.0), 0.0, 1.0),
				clampf(as_number(arr[1], 0.0), 0.0, 1.0),
				clampf(as_number(arr[2], 0.0), 0.0, 1.0),
				clampf(as_number(arr[3], 1.0) if arr.size() > 3 else 1.0, 0.0, 1.0)
			)
	return fallback


## 二维向量。接受 Vector2 / [x]（广播）/ [x, y] / {x, y} / "(x, y)" / 单值广播。
static func as_vec2(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	if value is Array:
		var arr: Array = value
		if arr.is_empty():
			return fallback
		if arr.size() == 1:
			var both := as_number(arr[0], fallback.x)
			return Vector2(both, both)
		return Vector2(as_number(arr[0], fallback.x), as_number(arr[1], fallback.y))
	if value is Dictionary:
		var dict: Dictionary = value
		if dict.has("x") or dict.has("y"):
			return Vector2(as_number(dict.get("x"), fallback.x),
				as_number(dict.get("y"), fallback.y))
		return fallback
	if value is String:
		var text := String(value).strip_edges().trim_prefix("(").trim_suffix(")")
		var parts := text.split(",", false)
		if parts.size() >= 2:
			return Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())
		if parts.size() == 1 and parts[0].strip_edges().is_valid_float():
			var only := parts[0].strip_edges().to_float()
			return Vector2(only, only)
		return fallback
	if value is int or value is float or value is bool:
		var scalar := as_number(value, fallback.x)
		return Vector2(scalar, scalar)
	return fallback
