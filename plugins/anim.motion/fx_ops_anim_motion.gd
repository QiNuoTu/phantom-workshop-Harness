class_name FxOpsAnimMotion
extends RefCounted
## 时间驱动的 vec2 运动。输出可直接连到「位移 / 缩放 / 轴心」等可绑定参数。

static func ops() -> Dictionary:
	return {
		&"anim.orbit": func(ctx, node, d, inputs, params): return orbit(ctx, node, d, inputs, params),
		&"anim.shake": func(ctx, node, d, inputs, params): return shake(ctx, node, d, inputs, params),
		&"anim.path": func(ctx, node, d, inputs, params): return path(ctx, node, d, inputs, params),
		&"anim.spring": func(ctx, node, d, inputs, params): return spring(ctx, node, d, inputs, params),
	}


static func orbit(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var radius := FxPortType.as_vec2(params.get("radius", [32, 32]), Vector2(32, 32))
	var speed := FxPortType.as_number(params.get("speed", 1.0), 1.0)
	var phase := FxPortType.as_number(params.get("phase", 0.0), 0.0)
	var center := FxPortType.as_vec2(params.get("center", [0, 0]), Vector2.ZERO)
	var tilt := FxPortType.as_number(params.get("tilt", 0.0), 0.0)
	var a: float = ctx.t * speed * TAU + phase
	var x: float = cos(a) * radius.x
	var y: float = sin(a) * radius.y
	var rotated := Vector2(x * cos(tilt) - y * sin(tilt), x * sin(tilt) + y * cos(tilt))
	return {"vec": center + rotated}


static func shake(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var amplitude := FxPortType.as_vec2(params.get("amplitude", [6, 6]), Vector2(6, 6))
	var frequency := maxf(0.001, FxPortType.as_number(params.get("frequency", 12.0), 12.0))
	var seed := FxPortType.as_int(params.get("seed", 17), 17)
	var decay := FxPortType.as_number(params.get("decay", 2.0), 2.0)
	var period := maxf(0.001, FxPortType.as_number(params.get("period", 1.0), 1.0))
	var t: float = fposmod(ctx.t, period)
	var index := int(floor(ctx.t * frequency))
	var nx: float = FxPixelKit.value_noise(float(index) * 0.7, 0.3, seed) * 2.0 - 1.0
	var ny: float = FxPixelKit.value_noise(float(index) * 0.7, 7.3, seed + 31) * 2.0 - 1.0
	var envelope: float = exp(-decay * t / period)
	return {"vec": Vector2(nx * amplitude.x, ny * amplitude.y) * envelope}


static func path(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var text := FxPortType.as_string(params.get("points", "0,0;32,0;32,32;0,32"), "0,0;32,0;32,32;0,32")
	var points: Array[Vector2] = []
	for token in text.split(";"):
		var pair := String(token).split(",")
		if pair.size() >= 2:
			points.append(Vector2(float(String(pair[0]).strip_edges()),
				float(String(pair[1]).strip_edges())))
	if points.is_empty():
		return {"vec": Vector2.ZERO}
	var duration := maxf(0.001, FxPortType.as_number(params.get("duration", 2.0), 2.0))
	var loop := FxPortType.as_bool(params.get("loop", true), true)
	var smooth := FxPortType.as_bool(params.get("smooth", true), true)
	var p: float = fposmod(ctx.t, duration) / duration if loop else clampf(ctx.t / duration, 0.0, 1.0)
	var count := float(points.size())
	var scaled: float = p * count
	var i := clampi(int(floor(scaled)), 0, points.size() - 1)
	var j := (i + 1) % points.size()
	var f: float = scaled - float(i)
	if smooth:
		f = FxPixelKit.smoothstep(0.0, 1.0, f)
	return {"vec": points[i].lerp(points[j], f)}


static func spring(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var target := FxPortType.as_number(params.get("target", 100.0), 100.0)
	var stiffness := maxf(0.01, FxPortType.as_number(params.get("stiffness", 120.0), 120.0))
	var damping := maxf(0.0, FxPortType.as_number(params.get("damping", 14.0), 14.0))
	var duration := maxf(0.001, FxPortType.as_number(params.get("duration", 1.5), 1.5))
	var t: float = fposmod(ctx.t, duration)
	# 解析解（欠阻尼）；临界/过阻尼用指数包络近似，保证任意参数都稳定。
	var omega: float = sqrt(stiffness)
	var zeta: float = damping / maxf(2.0 * omega, 0.001)
	var position := 0.0
	var velocity := 0.0
	if zeta < 0.999:
		var wd: float = omega * sqrt(1.0 - zeta * zeta)
		var envelope: float = exp(-zeta * omega * t)
		position = target * (1.0 - envelope * (cos(wd * t) + zeta * omega / maxf(wd, 0.001) * sin(wd * t)))
		velocity = target * envelope * sin(wd * t) * stiffness / maxf(wd, 0.001)
	else:
		var decay: float = exp(-omega * t)
		position = target * (1.0 - decay * (1.0 + omega * t))
		velocity = target * decay * omega * omega * t
	return {"vec": Vector2(position, velocity)}
