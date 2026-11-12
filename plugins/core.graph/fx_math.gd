class_name FxMath
extends RefCounted
## 特效绘制用的确定性随机与几何工具。
## 全部基于整数哈希：同一个 seed 得到同一形状，逐帧调用不会闪烁。

## 0..1 稳定随机
static func h01(a: int, b: int = 0) -> float:
	var n: int = a * 374761393 + b * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7FFFFFFF) / 2147483647.0


## -1..1
static func h11(a: int, b: int = 0) -> float:
	return h01(a, b) * 2.0 - 1.0


static func rand_range(seed: int, i: int, lo: float, hi: float) -> float:
	return lo + (hi - lo) * h01(seed, i)


static func rand_angle(seed: int, i: int) -> float:
	return h01(seed, i) * TAU


## 圆形多边形的点集，jitter 为半径抖动比例
static func circle_points(radius: float, count: int, jitter: float, seed: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(count):
		var a := TAU * float(i) / float(count)
		var r := radius * (1.0 + h11(seed, i) * jitter)
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


## 星形（外尖内凹）
static func star_points(r_out: float, r_in: float, count: int, seed: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var total := count * 2
	for i in range(total):
		var a := TAU * float(i) / float(total) + h11(seed, i) * 0.06
		var r := r_out if i % 2 == 0 else r_in
		r *= 1.0 + h11(seed, i + 97) * 0.12
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


## 锯齿折线（闪电/裂隙）
static func jagged_line(from: Vector2, to: Vector2, segments: int, amplitude: float, seed: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.append(from)
	var dir := to - from
	var normal := Vector2(-dir.y, dir.x).normalized()
	for i in range(1, segments):
		var t := float(i) / float(segments)
		var base := from + dir * t
		var off := h11(seed, i) * amplitude * (1.0 - absf(t - 0.5) * 1.2)
		pts.append(base + normal * off)
	pts.append(to)
	return pts


## 阿基米德螺线
static func spiral_points(center: Vector2, r_start: float, r_end: float, turns: float,
		segments: int, start_angle: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var a := start_angle + t * turns * TAU
		var r := lerpf(r_start, r_end, t)
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts


## 一段圆弧的点集（用于手绘粗弧/环）
static func arc_points(center: Vector2, radius: float, a_from: float, a_to: float,
		segments: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var a := lerpf(a_from, a_to, t)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts


static func ease_out_cubic(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)


static func ease_in_cubic(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return x * x * x


static func ease_out_back(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)


## 把颜色按透明度缩放（保留 RGB，避免 use_alpha 变暗）
static func a(c: Color, alpha: float) -> Color:
	return Color(c.r, c.g, c.b, clampf(alpha, 0.0, 1.0))


## 提亮（用于白热核心）
static func lighten(c: Color, amount: float) -> Color:
	return c.lerp(Color(1, 1, 1, c.a), clampf(amount, 0.0, 1.0))
