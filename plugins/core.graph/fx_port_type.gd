class_name FxPortType
extends RefCounted
## 端口类型系统：蓝图里**唯一**的类型事实来源。
##
## 为什么单独一层：
##   · GraphNode/GraphEdit 只认 int 类型，JSON 里存的是类型名，两边必须有一张稳定的映射表；
##   · 连接是否合法、绑定时怎么转换，不能散落在 UI 和执行器里各写一遍；
##   · 新增类型只改 ORDER / META / can_connect / cast_value，其余代码自动跟上。
##
## ORDER 的顺序就是 GraphNode 使用的 int 类型号，**不要重排**，否则旧存档的配色会错位。
## JSON 永远存类型名（如 "image"），int 只是渲染层的临时值。

const ANY: StringName = &"any"
const EXEC: StringName = &"exec"
const IMAGE: StringName = &"image"
const NUMBER: StringName = &"number"
const INT: StringName = &"int"
const BOOL: StringName = &"bool"
const STRING: StringName = &"string"
const COLOR: StringName = &"color"
const VEC2: StringName = &"vec2"
const LAYER: StringName = &"layer"
## 图像值对象：带属性/像素数据的 Image 包装，可与裸 image 端口双向互连。
const IMAGE_OBJECT: StringName = &"image_object"

const ORDER := [
	ANY, EXEC, IMAGE, NUMBER, INT, BOOL, STRING, COLOR, VEC2, LAYER,
	# 只能追加，不能插队：int 类型号是旧存档里的稳定配色索引。
	IMAGE_OBJECT,
]

const META := {
	&"any": {"label": "任意", "color": "#9aa4b2"},
	&"exec": {"label": "执行", "color": "#e6edf3"},
	&"image": {"label": "图像", "color": "#4cc2ff"},
	&"number": {"label": "数值", "color": "#ffb454"},
	&"int": {"label": "整数", "color": "#ff9f43"},
	&"bool": {"label": "布尔", "color": "#ff6b6b"},
	&"string": {"label": "文本", "color": "#ffd166"},
	&"color": {"label": "颜色", "color": "#f472b6"},
	&"vec2": {"label": "向量", "color": "#a78bfa"},
	&"layer": {"label": "图层", "color": "#7ee787"},
	&"image_object": {"label": "图像对象", "color": "#2dd4bf"},
}

static var _color_cache: Dictionary = {}


static func normalize(type: Variant) -> StringName:
	var key := StringName(String(type))
	return key if META.has(key) else ANY


static func label_of(type: Variant) -> String:
	return String((META.get(normalize(type), {}) as Dictionary).get("label", "任意"))


static func color_of(type: Variant) -> Color:
	var key := normalize(type)
	if _color_cache.has(key):
		return _color_cache[key]
	var hex := String((META.get(key, {}) as Dictionary).get("color", "#9aa4b2"))
	var color := Color.from_string(hex, Color(0.6, 0.64, 0.7))
	_color_cache[key] = color
	return color


## GraphNode 使用的 int 类型号。稳定、与 ORDER 一一对应。
static func id_of(type: Variant) -> int:
	var index := ORDER.find(normalize(type))
	return index if index >= 0 else 0


static func from_id(id: int) -> StringName:
	return ORDER[clampi(id, 0, ORDER.size() - 1)]


## 连接规则。exec 是独立通道，绝不能与数据端口互连。
static func can_connect(from_type: Variant, to_type: Variant) -> bool:
	var a := normalize(from_type)
	var b := normalize(to_type)
	if a == EXEC or b == EXEC:
		return a == EXEC and b == EXEC
	if a == ANY or b == ANY:
		return true
	if a == b:
		return true
	if (a == NUMBER and b == INT) or (a == INT and b == NUMBER):
		return true
	# 图像对象 ↔ 裸图像：同一个东西的两种表示，双向都允许。
	if (a == IMAGE_OBJECT and b == IMAGE) or (a == IMAGE and b == IMAGE_OBJECT):
		return true
	# 标量 → 向量按两轴广播，这是像素工具里最常用的便利连接（索引直接驱动位移）。
	if (a == NUMBER or a == INT) and b == VEC2:
		return true
	return false


## 端口之间的值转换。只做无损或明确约定的转换，避免隐式魔法。
static func cast_value(value: Variant, from_type: Variant, to_type: Variant) -> Variant:
	var a := normalize(from_type)
	var b := normalize(to_type)
	if value == null:
		return null
	if b == ANY or a == b:
		return value
	# 对象端口接进老的图像节点时自动拆包；裸图像接进对象节点时自动打包。
	if a == IMAGE_OBJECT and b == IMAGE:
		return FxImageObject.unwrap(value)
	if a == IMAGE and b == IMAGE_OBJECT:
		return FxImageObject.wrap(value as Image)
	if b == INT:
		return int(round(as_number(value, 0.0)))
	if b == NUMBER:
		return as_number(value, 0.0)
	if b == STRING:
		if value is Color:
			return value.to_html()
		if value is Vector2:
			return "%s,%s" % [value.x, value.y]
		return str(value)
	if b == COLOR:
		return as_color(value, Color.WHITE)
	if b == VEC2:
		return as_vec2(value, Vector2.ZERO)
	return value


# ================= 参数值归一化 =================

static func as_number(value: Variant, fallback: float = 0.0) -> float:
	if value is float or value is int:
		return float(value)
	if value is bool:
		return 1.0 if bool(value) else 0.0
	if value is String:
		return String(value).to_float() if String(value).is_valid_float() else fallback
	if value is Array and not (value as Array).is_empty():
		return as_number((value as Array)[0], fallback)
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


static func as_vec2(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	return FxTransform.vec2_of(value, fallback)


## 按参数 kind 归一化（绑定端口传进来的值也走这里）。
static func coerce_kind(value: Variant, kind: String, fallback: Variant = null) -> Variant:
	match kind:
		"int", "integer":
			return as_int(value, as_int(fallback, 0))
		"float", "number":
			return as_number(value, as_number(fallback, 0.0))
		"bool":
			return as_bool(value, as_bool(fallback, false))
		"color":
			return as_color(value, as_color(fallback, Color.WHITE))
		"vec2":
			return as_vec2(value, as_vec2(fallback, Vector2.ZERO))
		"string", "enum", "asset", "font", "path":
			return as_string(value, as_string(fallback, ""))
		"image":
			return value if value is Image else null
	return value


## 参数 kind → 端口类型。可绑定参数靠它长出输入端口。
static func kind_to_type(kind: String) -> StringName:
	match kind:
		"int", "integer", "float", "number":
			return NUMBER
		"bool":
			return BOOL
		"color":
			return COLOR
		"vec2":
			return VEC2
		"string", "enum", "asset", "font", "path":
			return STRING
		"image":
			return IMAGE
		"layers":
			return LAYER
	return ANY
