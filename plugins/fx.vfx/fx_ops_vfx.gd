class_name FxOpsVfx
extends RefCounted
## 时间驱动的程序化特效。所有形态只由 (ctx.t, seed, params) 决定，
## 因此同一帧的预览与导出逐像素一致；插件声明了 time_dependent_ops 关闭跨帧缓存。

static func ops() -> Dictionary:
	return {
		&"image.shockwave": func(ctx, node, d, inputs, params): return shockwave(ctx, node, d, inputs, params),
		&"image.flame": func(ctx, node, d, inputs, params): return flame(ctx, node, d, inputs, params),
		&"image.lightning": func(ctx, node, d, inputs, params): return lightning(ctx, node, d, inputs, params),
		&"image.sparks": func(ctx, node, d, inputs, params): return sparks(ctx, node, d, inputs, params),
		&"image.rays": func(ctx, node, d, inputs, params): return rays(ctx, node, d, inputs, params),
	}


static func _size(ctx: FxEvalContext, inputs: Dictionary) -> Vector2i:
	return FxPixelKit.size_of(inputs, ctx)


static func shockwave(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var max_radius := FxPortType.as_number(params.get("radius", 0.75), 0.75)
	var width := FxPortType.as_number(params.get("width", 0.08), 0.08)
	var speed := FxPortType.as_number(params.get("speed", 1.0), 1.0)
	var ring_color := FxPortType.as_color(params.get("color", "#ffd166"), Color(1, 0.82, 0.4))
	var core_color := FxPortType.as_color(params.get("core", "#ff7a2a"), Color(1, 0.48, 0.16))
	var intensity := FxPortType.as_number(params.get("intensity", 1.0), 1.0)
	var center := FxPortType.as_vec2(params.get("center", [0.5, 0.5]), Vector2(0.5, 0.5))
	var phase: float = fposmod(ctx.t * speed, 1.0)
	var r: float = phase * max_radius
	var fade: float = 1.0 - phase * 0.55
	var image := FxPixelKit.generate(size, func(x: float, y: float, w: float, h: float) -> Color:
		var dx: float = (x / maxf(w, 1.0) - center.x) * 1.6
		var dy: float = (y / maxf(h, 1.0) - center.y)
		var dist: float = sqrt(dx * dx + dy * dy)
		var ring: float = 1.0 - FxPixelKit.smoothstep(0.0, maxf(width, 0.001), absf(dist - r))
		var core: float = (1.0 - FxPixelKit.smoothstep(0.0, r * 0.6 + 0.01, dist)) * (1.0 - phase) * 0.6
		var energy: float = clampf((ring + core) * fade * intensity, 0.0, 1.0)
		var col := core_color.lerp(ring_color, clampf(ring / maxf(ring + core, 0.001), 0.0, 1.0))
		return Color(col.r, col.g, col.b, energy)
	)
	return {"image": image}


static func flame(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var base := FxPortType.as_color(params.get("base", "#ff3b1f"), Color(1, 0.23, 0.12))
	var tip := FxPortType.as_color(params.get("tip", "#ffe08a"), Color(1, 0.88, 0.54))
	var intensity := FxPortType.as_number(params.get("intensity", 1.0), 1.0)
	var speed := FxPortType.as_number(params.get("speed", 2.0), 2.0)
	var turbulence := FxPortType.as_number(params.get("turbulence", 4.0), 4.0)
	var height := clampf(FxPortType.as_number(params.get("height", 0.85), 0.85), 0.05, 1.0)
	var seed := FxPortType.as_int(params.get("seed", 11), 11)
	var t := ctx.t * speed
	# 噪声场只在 1/4 分辨率上算一次（R=抖动, G=火苗纹理），主循环双线性采样。
	# 原来每个像素要做两次 3 层 fbm ≈ 24 次 hash；现在降到 ~1/16。
	var step := 4
	var ns := Vector2i(maxi(4, size.x / step), maxi(4, size.y / step))
	var noise_image := FxPixelKit.generate(ns, func(x: float, y: float, w: float, h: float) -> Color:
		var nx: float = x / maxf(w, 1.0)
		var ny: float = y / maxf(h, 1.0)
		return Color(
			FxPixelKit.fbm(nx * turbulence, ny * turbulence - t, seed, 3),
			FxPixelKit.fbm(nx * turbulence * 2.0, ny * turbulence * 3.0 - t * 1.6, seed + 41, 3),
			0.0, 1.0)
	)
	var nb := noise_image.get_data()
	var image := FxPixelKit.generate(size, func(x: float, y: float, w: float, h: float) -> Color:
		var n := FxPixelKit.sample(nb, ns, x / float(step), y / float(step))
		var nx: float = x / maxf(w, 1.0)
		var ny: float = 1.0 - y / maxf(h, 1.0)
		var wobble: float = (n.r - 0.5) * 0.35
		var horizontal: float = 1.0 - FxPixelKit.smoothstep(0.12, 0.5,
			absf(nx - 0.5 + wobble) * (1.0 + ny))
		var vertical: float = 1.0 - FxPixelKit.smoothstep(height * 0.25, height,
			ny / maxf(height, 0.01))
		var heat: float = clampf(horizontal * vertical * n.g * 1.8 * intensity, 0.0, 1.0)
		var col := base.lerp(tip, clampf(n.g * 1.2, 0.0, 1.0))
		return Color(col.r, col.g, col.b, heat)
	)
	return {"image": image}


static func lightning(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var color := FxPortType.as_color(params.get("color", "#9fd8ff"), Color(0.62, 0.85, 1))
	var branches := clampi(FxPortType.as_int(params.get("branches", 3), 3), 0, 12)
	var width := FxPortType.as_number(params.get("width", 2.0), 2.0)
	var jitter := FxPortType.as_number(params.get("jitter", 0.35), 0.35)
	var speed := FxPortType.as_number(params.get("speed", 6.0), 6.0)
	var seed := FxPortType.as_int(params.get("seed", 5), 5)
	var frame := int(floor(ctx.t * speed))
	# 预先生成每条折线的逐行 x 偏移，避免在像素循环里做随机。
	var bolts: Array = []
	for b in range(branches + 1):
		var points: Array = []
		var drift := 0.0
		var row_count := maxi(2, size.y / 8)
		for i in range(row_count + 1):
			drift += (FxPixelKit.hash2(i, b * 31 + frame, seed) - 0.5) * jitter
			points.append(drift)
		bolts.append(points)
	var image := FxPixelKit.generate(size, func(x: float, y: float, w: float, h: float) -> Color:
		var best: float = 999.0
		for b in range(bolts.size()):
			var points: Array = bolts[b]
			var row: int = clampi(int(y / maxf(h, 1.0) * float(points.size() - 1)), 0, points.size() - 1)
			var spread: float = 0.15 + float(b) * 0.08
			var bolt_x: float = w * (0.5 + points[row] * spread + (float(b) - 0.5) * 0.02)
			var d: float = absf(x - bolt_x)
			if b > 0:
				d += y * 0.012
			best = minf(best, d)
		var alpha: float = (1.0 - FxPixelKit.smoothstep(width * 0.35, width, best))
		return Color(color.r, color.g, color.b, alpha)
	)
	return {"image": image}


static func sparks(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var count := clampi(FxPortType.as_int(params.get("count", 48), 48), 1, 300)
	var color := FxPortType.as_color(params.get("color", "#ffb454"), Color(1, 0.7, 0.33))
	var speed := FxPortType.as_number(params.get("speed", 0.6), 0.6)
	var gravity := FxPortType.as_number(params.get("gravity", 0.5), 0.5)
	var star_size := FxPortType.as_number(params.get("size", 1.6), 1.6)
	var life := maxf(0.1, FxPortType.as_number(params.get("life", 1.0), 1.0))
	var seed := FxPortType.as_int(params.get("seed", 9), 9)
	var blobs: Array[Dictionary] = []
	for i in range(count):
		var angle: float = FxPixelKit.hash2(i, 1, seed) * TAU
		var velocity: float = (0.3 + FxPixelKit.hash2(i, 2, seed) * 0.7) * speed
		var delay: float = FxPixelKit.hash2(i, 3, seed)
		var age: float = fposmod(ctx.t + delay * life, life) / life
		var vx: float = cos(angle) * velocity
		var vy: float = sin(angle) * velocity - speed * 0.5
		blobs.append({
			"x": float(size.x) * 0.5 + vx * float(size.x) * age,
			"y": float(size.y) * 0.55 + vy * float(size.y) * age
				+ gravity * float(size.y) * age * age,
			"radius": star_size * 2.0,
			"color": color,
			"strength": (1.0 - age) * (0.6 + FxPixelKit.hash2(i, 4, seed) * 0.4),
			"core": 0.3,
		})
	# 稀疏绘制：每颗粒子只处理自己的包围盒，不再对全图 × 粒子数做距离计算。
	return {"image": FxPixelKitBlobs.paint(size, Color(0, 0, 0, 0), blobs)}


static func rays(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var count := clampi(FxPortType.as_int(params.get("count", 12), 12), 1, 64)
	var color := FxPortType.as_color(params.get("color", "#ffe6a7"), Color(1, 0.9, 0.65))
	var length := FxPortType.as_number(params.get("length", 0.9), 0.9)
	var width := clampf(FxPortType.as_number(params.get("width", 0.12), 0.12), 0.001, 1.0)
	var speed := FxPortType.as_number(params.get("speed", 0.5), 0.5)
	var intensity := FxPortType.as_number(params.get("intensity", 1.0), 1.0)
	var center := FxPortType.as_vec2(params.get("center", [0.5, 0.5]), Vector2(0.5, 0.5))
	var spin: float = ctx.t * speed
	var image := FxPixelKit.generate(size, func(x: float, y: float, w: float, h: float) -> Color:
		var dx: float = (x / maxf(w, 1.0) - center.x) * 1.6
		var dy: float = y / maxf(h, 1.0) - center.y
		var dist: float = sqrt(dx * dx + dy * dy)
		var angle: float = fposmod(atan2(dy, dx) / TAU * float(count) + spin, 1.0)
		var spoke: float = 1.0 - FxPixelKit.smoothstep(0.0, width, minf(angle, 1.0 - angle))
		var falloff: float = 1.0 - FxPixelKit.smoothstep(length * 0.4, length, dist)
		var core: float = 1.0 - FxPixelKit.smoothstep(0.0, 0.16, dist)
		var alpha: float = clampf((spoke * falloff * 0.8 + core) * intensity, 0.0, 1.0)
		return Color(color.r, color.g, color.b, alpha)
	)
	return {"image": image}
