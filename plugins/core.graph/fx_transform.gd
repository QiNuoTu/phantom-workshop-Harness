class_name FxTransform
extends RefCounted
## 特效图层的标准空间变换组件（size / position / rotation / scale /
## pivot_offset / pivot_offset_ratio）。
##
## 这是**唯一事实来源**：字段定义、默认值、校验、采样、矩阵合成全在这里。
## 上层三方各自只读它的一面，谁都不认识谁：
##   · 引擎（VfxEngine）    —— 只要 matrix()，把绘制坐标套进去；
##   · 参数面板（ParamSchema）—— 只要 FIELDS 元数据，自动长出六行控件；
##   · 图文档（FxGraphDoc）  —— 只要 identity()/normalize()，做默认值与容错。
## 因此"再加一个变换字段"只需要改这个文件，其余三处自动跟上。
##
## 语义（与 Godot 的 Node2D + Control 对齐，但全部用**设计像素**表达）：
##   size                 图层占据的盒子尺寸，默认 96×96 = 设计画布。
##                        内容按 size/DESIGN_SIZE 缩放，所以默认值即恒等。
##   position             相对画布原点的位移（px）。
##   rotation             绕轴心的旋转（度，顺时针为正，与 Godot 一致）。
##   scale                额外缩放倍数（可为负 = 镜像），叠加在 size 之上。
##   pivot_offset         轴心相对图层原点的像素偏移。
##   pivot_offset_ratio   轴心在 size 盒子里的归一化位置（0.5,0.5 = 中心 = 原点）。
##
## 矩阵 = T(position + pivot) · R(rotation) · S(size/DESIGN_SIZE · scale) · T(-pivot)
## 任何字段都可以是关键帧轨道（{track: […]})，采样后与常量走同一条路径。

## 设计空间基准：所有几何参数都是按 96×96 写的（与 VfxEngine.DESIGN_SIZE 一致）。
const DESIGN_SIZE: float = 96.0

## 字段表。UI 直接遍历它生成控件；核心直接读 kind/default 做校验。
## 键序 = 面板显示顺序 = 端口顺序，别随意调整。
const FIELDS: Array = [
	{
		"id": "position", "label": "位置", "kind": "vec2",
		"default": Vector2(0.0, 0.0),
		"min": -256.0, "max": 256.0, "step": 1.0, "unit": "px",
		"hint": "相对画布原点的位移。默认 (0,0) = 画布中心；y 向下为正。",
		"dtype": "向量 (x, y) · 设计像素",
		"accepts": "number → 两轴同值；range → 逐轴随机；xform 节点整体覆盖",
	},
	{
		"id": "size", "label": "尺寸", "kind": "vec2",
		"default": Vector2(DESIGN_SIZE, DESIGN_SIZE),
		"min": 1.0, "max": 512.0, "step": 1.0, "unit": "px",
		"hint": "图层盒子的尺寸。内容按 尺寸/96 缩放，所以 96×96 等于不缩放。",
		"dtype": "向量 (宽, 高) · 设计像素",
		"accepts": "number → 宽高同值；range → 逐轴随机",
	},
	{
		"id": "rotation", "label": "旋转", "kind": "float",
		"default": 0.0,
		"min": -360.0, "max": 360.0, "step": 0.5, "unit": "°",
		"hint": "绕轴心旋转，顺时针为正。打帧就是自转/摆动。",
		"dtype": "数值（度）",
		"accepts": "number → 角度；wave/expr 可以驱动",
	},
	{
		"id": "scale", "label": "缩放", "kind": "vec2",
		"default": Vector2(1.0, 1.0),
		"min": -4.0, "max": 4.0, "step": 0.01, "unit": "×",
		"hint": "额外缩放倍数，叠加在尺寸之上。负值 = 镜像翻转。",
		"dtype": "向量 (x, y) · 倍数",
		"accepts": "number → 等比；range → 逐轴随机",
	},
	{
		"id": "pivot_offset", "label": "轴心偏移", "kind": "vec2",
		"default": Vector2(0.0, 0.0),
		"min": -256.0, "max": 256.0, "step": 1.0, "unit": "px",
		"hint": "轴心相对图层原点的像素偏移。想让特效绕左下角转，就把它设成 (-48, 48)。",
		"dtype": "向量 (x, y) · 设计像素",
		"accepts": "number → 两轴同值",
	},
	{
		"id": "pivot_offset_ratio", "label": "轴心比例", "kind": "vec2",
		"default": Vector2(0.5, 0.5),
		"min": 0.0, "max": 1.0, "step": 0.01, "unit": "",
		"hint": "轴心在尺寸盒子里的归一化位置：0 = 左上，0.5 = 中心，1 = 右下。",
		"dtype": "向量 (x, y) · 0..1",
		"accepts": "number → 两轴同值",
	},
]

## 字段 id 列表（顺序稳定，端口与面板都按它铺）。
const FIELD_IDS: Array = ["position", "size", "rotation", "scale",
	"pivot_offset", "pivot_offset_ratio"]

## 阈值：小于它的数值视为"没动过"，工具提示与恒等判断共用。
const EPSILON: float = 0.0001

# ================= 定义查询 =================

static func field(id: String) -> Dictionary:
	for entry in FIELDS:
		if String((entry as Dictionary).get("id", "")) == id:
			return entry
	return {}


static func field_label(id: String) -> String:
	var spec: Dictionary = field(id)
	return String(spec.get("label", id)) if not spec.is_empty() else id


static func field_default(id: String) -> Variant:
	var spec: Dictionary = field(id)
	if spec.is_empty():
		return null
	var value: Variant = spec.get("default", 0.0)
	return value + Vector2.ZERO if value is Vector2 else value


## 恒等变换（默认姿态）。返回新字典，调用方可以随意改。
static func identity() -> Dictionary:
	var out: Dictionary = {}
	for spec in FIELDS:
		var value: Variant = (spec as Dictionary).get("default", 0.0)
		out[String((spec as Dictionary)["id"])] = _pair_of(value, Vector2.ZERO) \
			if String((spec as Dictionary)["kind"]) == "vec2" else float(value)
	return out


# ================= 校验 / 归一化 =================

## 任意输入 → 规范化的变换字典。
##
## 容错优先（蓝图 JSON 是给人手改的）：缺字段补默认、标量广播成向量、
## 字符串 "(12, -4)"、Vector2、{"x":…} 都认；带 track 的值原样保留（逐帧采样）。
static func normalize(raw: Variant) -> Dictionary:
	var out: Dictionary = identity()
	if raw is Vector2:
		# 光给一个向量时按"位置"理解 —— 这是最常见的简写
		out["position"] = _pair_of(raw, Vector2.ZERO)
		return out
	if not raw is Dictionary:
		return out
	var source: Dictionary = raw
	for spec in FIELDS:
		var id: String = String((spec as Dictionary)["id"])
		if not source.has(id):
			continue
		var value: Variant = source[id]
		# 轨道原样保留：采样在 sample_field 里做，归一化不该吃掉时间轴
		if value is Dictionary and (value as Dictionary).has("track"):
			out[id] = (value as Dictionary).duplicate(true)
			continue
		if String((spec as Dictionary)["kind"]) == "vec2":
			var fallback: Vector2 = (spec as Dictionary)["default"]
			var pair: Array = _pair_of(value, fallback)
			var lo: float = float((spec as Dictionary).get("min", -65535.0))
			var hi: float = float((spec as Dictionary).get("max", 65535.0))
			out[id] = [clampf(float(pair[0]), lo, hi), clampf(float(pair[1]), lo, hi)]
		else:
			var lo_n: float = float((spec as Dictionary).get("min", -65535.0))
			var hi_n: float = float((spec as Dictionary).get("max", 65535.0))
			out[id] = clampf(FxTracks.number(value, float((spec as Dictionary)["default"])),
				lo_n, hi_n)
	return out


## 是否等于恒等（含轨道就算"不恒等"，因为逐帧看一定在动）。
static func is_identity(raw: Variant) -> bool:
	if raw == null:
		return true
	if not raw is Dictionary:
		return false
	var tf: Dictionary = normalize(raw)
	for spec in FIELDS:
		var id: String = String((spec as Dictionary)["id"])
		var raw_value: Variant = tf[id]
		if raw_value is Dictionary:
			return false
		if String((spec as Dictionary)["kind"]) == "vec2":
			var fallback: Vector2 = (spec as Dictionary)["default"]
			var pair: Array = raw_value
			if absf(float(pair[0]) - fallback.x) > EPSILON \
					or absf(float(pair[1]) - fallback.y) > EPSILON:
				return false
		else:
			if absf(float(raw_value) - float((spec as Dictionary)["default"])) > EPSILON:
				return false
	return true


## 逐帧采样单个字段。返回 Vector2（vec2 字段）或 float（标量字段）。
static func sample_field(raw: Variant, id: String, t: float) -> Variant:
	var spec: Dictionary = field(id)
	if spec.is_empty():
		return 0.0
	var value: Variant = (raw as Dictionary).get(id, spec.get("default", 0.0)) \
		if raw is Dictionary else spec.get("default", 0.0)
	if value is Dictionary and (value as Dictionary).has("track"):
		value = FxTracks.sample(value, t)
	if String(spec.get("kind", "float")) == "vec2":
		return vec2_of(value, spec["default"])
	return FxTracks.number(value, float(spec["default"]))


# ================= 矩阵 =================

## 变换矩阵。unit 是"设计像素 → 帧像素"的画布缩放（引擎的 _unit），
## 由调用方传入；组件本身不认识画布，因此可以脱离引擎单测。
static func matrix(raw: Variant, t: float, unit: float = 1.0) -> Transform2D:
	if is_identity(raw):
		return Transform2D.IDENTITY
	var tf: Dictionary = normalize(raw)
	var size: Vector2 = sample_field(tf, "size", t)
	var scale: Vector2 = sample_field(tf, "scale", t)
	var pos: Vector2 = sample_field(tf, "position", t)
	var ratio: Vector2 = sample_field(tf, "pivot_offset_ratio", t)
	var pivot_off: Vector2 = sample_field(tf, "pivot_offset", t)
	var rot: float = deg_to_rad(float(sample_field(tf, "rotation", t)))
	# 内容缩放 = 盒子相对设计画布的比例 × 额外倍数。零会让矩阵不可逆，
	# 于是"缩到 0"变成 0.001：视觉上是一个点，但反算（wipe 等）仍然成立。
	var content: Vector2 = content_scale_of(tf, t)
	# 轴心：ratio 以盒子中心为 0.5（因为图层内容本来就画在原点周围），
	# 再叠像素偏移。默认 (0.5,0.5)+0 = 原点 = 恒等。
	var pivot: Vector2 = (ratio - Vector2(0.5, 0.5)) * size + pivot_off
	var c: float = cos(rot)
	var s: float = sin(rot)
	var basis := Transform2D(Vector2(c * content.x, s * content.x),
		Vector2(-s * content.y, c * content.y), Vector2.ZERO)
	# 轴心是**不动点**：它在父空间里固定在 position + pivot 上（与 Control 的 pivot_offset 一致）。
	# 注意不是 position - basis*pivot —— 那样 pivot 非零时即使不旋转也会把图层推开。
	basis.origin = (pos + pivot) * unit - basis * (pivot * unit)
	return basis


## 内容缩放向量（不含位置/旋转）。素材层需要它来缩放自身尺寸。
static func content_scale_of(raw: Variant, t: float) -> Vector2:
	var tf: Dictionary = normalize(raw) if raw is Dictionary else identity()
	var size: Vector2 = sample_field(tf, "size", t)
	var scale: Vector2 = sample_field(tf, "scale", t)
	var content: Vector2 = Vector2(size.x / DESIGN_SIZE, size.y / DESIGN_SIZE) * scale
	return Vector2(_safe_scale(content.x), _safe_scale(content.y))


## 旋转角（度）。素材层自己的 rot 参数要与它相加。
static func rotation_of(raw: Variant, t: float) -> float:
	if raw == null:
		return 0.0
	return float(sample_field(normalize(raw), "rotation", t))


## 轴心在图层局部坐标里的位置（设计像素）。自检与工具用。
static func pivot_of(raw: Variant, t: float = 0.0) -> Vector2:
	var tf: Dictionary = normalize(raw) if raw is Dictionary else identity()
	var size: Vector2 = sample_field(tf, "size", t)
	var ratio: Vector2 = sample_field(tf, "pivot_offset_ratio", t)
	var off: Vector2 = sample_field(tf, "pivot_offset", t)
	return (ratio - Vector2(0.5, 0.5)) * size + off


## 一句话描述（节点副标题、日志、断言失败信息）。恒等时返回 ""。
static func summary(raw: Variant, t: float = 0.0) -> String:
	if raw == null or is_identity(raw):
		return ""
	var tf: Dictionary = normalize(raw)
	var parts: PackedStringArray = PackedStringArray()
	var pos: Vector2 = sample_field(tf, "position", t)
	if pos.distance_to(Vector2.ZERO) > 0.01:
		parts.append("位移 %s" % _fmt_vec(pos))
	var rot: float = float(sample_field(tf, "rotation", t))
	if absf(rot) > 0.01:
		parts.append("旋转 %s°" % str(snappedf(rot, 0.1)))
	var size: Vector2 = sample_field(tf, "size", t)
	if absf(size.x - DESIGN_SIZE) > 0.01 or absf(size.y - DESIGN_SIZE) > 0.01:
		parts.append("尺寸 %s" % _fmt_vec(size))
	var scale: Vector2 = sample_field(tf, "scale", t)
	if absf(scale.x - 1.0) > 0.001 or absf(scale.y - 1.0) > 0.001:
		parts.append("缩放 %s" % _fmt_vec(scale))
	var pivot: Vector2 = pivot_of(tf, t)
	if pivot.distance_to(Vector2.ZERO) > 0.01:
		parts.append("轴心 %s" % _fmt_vec(pivot))
	return " · ".join(parts)


# ================= 值转换 =================

## 任意值 → Vector2。标量广播、数组取前两位、字符串解析 "x,y" / "(x, y)"。
static func vec2_of(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	if value is Array:
		var arr: Array = value
		if arr.is_empty():
			return fallback
		if arr.size() == 1:
			var both: float = FxTracks.number(arr[0], fallback.x)
			return Vector2(both, both)
		return Vector2(FxTracks.number(arr[0], fallback.x), FxTracks.number(arr[1], fallback.y))
	if value is Dictionary:
		var dict: Dictionary = value
		if dict.has("x") or dict.has("y"):
			return Vector2(FxTracks.number(dict.get("x"), fallback.x),
				FxTracks.number(dict.get("y"), fallback.y))
		return fallback
	if value is String:
		var text: String = String(value).strip_edges().trim_prefix("(").trim_suffix(")")
		var parts: PackedStringArray = text.split(",", false)
		if parts.size() >= 2:
			return Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())
		if parts.size() == 1 and parts[0].strip_edges().is_valid_float():
			var both: float = parts[0].strip_edges().to_float()
			return Vector2(both, both)
		return fallback
	if value is int or value is float or value is bool:
		var scalar: float = FxTracks.number(value, fallback.x)
		return Vector2(scalar, scalar)
	return fallback


## Vector2 → 存盘用的 [x, y]。文档里**只放数组**：
## JSON.stringify(Vector2) 会写成字符串 "(12, -4)"，读回来就再也变不回向量了。
static func to_pair(value: Vector2) -> Array:
	return [snappedf(value.x, 0.001), snappedf(value.y, 0.001)]


static func _pair_of(value: Variant, fallback: Vector2) -> Array:
	return to_pair(vec2_of(value, fallback))


static func _safe_scale(value: float) -> float:
	if absf(value) < 0.001:
		return 0.001 if value >= 0.0 else -0.001
	return value


static func _fmt_vec(value: Vector2) -> String:
	return "(%s, %s)" % [str(snappedf(value.x, 0.01)), str(snappedf(value.y, 0.01))]
