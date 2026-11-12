class_name FxOpsAnimCurves
extends RefCounted
## 时间驱动的数值曲线。输出 number，可绑定到任意可绑定参数（半径/位移/透明度…）。
## 不产生图像、不读写 ctx.state，纯函数；由插件声明 time_dependent_ops 禁用跨帧缓存。

static func ops() -> Dictionary:
	return {
		&"anim.ease": func(ctx, node, d, inputs, params): return ease_curve(ctx, node, d, inputs, params),
		&"anim.oscillator": func(ctx, node, d, inputs, params): return oscillator(ctx, node, d, inputs, params),
		&"anim.pulse": func(ctx, node, d, inputs, params): return pulse(ctx, node, d, inputs, params),
		&"anim.steps": func(ctx, node, d, inputs, params): return steps(ctx, node, d, inputs, params),
		&"anim.noise1d": func(ctx, node, d, inputs, params): return noise1d(ctx, node, d, inputs, params),
		&"anim.remap": func(ctx, node, d, inputs, params): return remap_value(ctx, node, d, inputs, params),
	}


static func _phase(ctx: FxEvalContext, params: Dictionary) -> float:
	var duration := maxf(0.001, FxPortType.as_number(params.get("duration", 1.0), 1.0))
	var offset := FxPortType.as_number(params.get("offset", 0.0), 0.0)
	var t: float = ctx.t + offset
	if FxPortType.as_bool(params.get("loop", true), true):
		return fposmod(t, duration) / duration
	return clampf(t / duration, 0.0, 1.0)


static func ease_curve(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var p := _phase(ctx, params)
	if FxPortType.as_bool(params.get("reverse", false), false):
		p = 1.0 - absf(p * 2.0 - 1.0)
	var curve := FxPortType.as_string(params.get("curve", "quad_inout"), "quad_inout")
	var start := FxPortType.as_number(params.get("from", 0.0), 0.0)
	var finish := FxPortType.as_number(params.get("to", 1.0), 1.0)
	return {"value": lerpf(start, finish, _apply_curve(curve, p))}


static func _apply_curve(name: String, t: float) -> float:
	match name:
		"quad_in": return t * t
		"quad_out": return t * (2.0 - t)
		"quad_inout": return 2.0 * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 2.0) * 0.5
		"cubic_in": return t * t * t
		"cubic_out": return 1.0 - pow(1.0 - t, 3.0)
		"sine_inout": return 0.5 - cos(t * PI) * 0.5
		"expo_out": return 1.0 - pow(2.0, -10.0 * t) if t < 1.0 else 1.0
		"back_out": return 1.0 + 2.70158 * pow(t - 1.0, 3.0) + 1.70158 * pow(t - 1.0, 2.0)
		"elastic_out": return 1.0 + pow(2.0, -10.0 * t) * sin((t * 10.0 - 0.75) * TAU / 3.0) if t > 0.0 and t < 1.0 else t
		"bounce_out":
			var n := 7.5625
			var d := 2.75
			if t < 1.0 / d: return n * t * t
			if t < 2.0 / d: return n * (t - 1.5 / d) * (t - 1.5 / d) + 0.75
			if t < 2.5 / d: return n * (t - 2.25 / d) * (t - 2.25 / d) + 0.9375
			return n * (t - 2.625 / d) * (t - 2.625 / d) + 0.984375
		_: return t


static func oscillator(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var wave := FxPortType.as_string(params.get("wave", "sine"), "sine")
	var frequency := maxf(0.001, FxPortType.as_number(params.get("frequency", 1.0), 1.0))
	var amplitude := FxPortType.as_number(params.get("amplitude", 1.0), 1.0)
	var offset := FxPortType.as_number(params.get("offset", 0.0), 0.0)
	var phase := FxPortType.as_number(params.get("phase", 0.0), 0.0)
	var duty := clampf(FxPortType.as_number(params.get("duty", 0.5), 0.5), 0.01, 0.99)
	var p: float = fposmod(ctx.t * frequency + phase / TAU, 1.0)
	var value := 0.0
	match wave:
		"square": value = 1.0 if p < duty else -1.0
		"triangle": value = 4.0 * absf(p - 0.5) - 1.0
		"saw": value = p * 2.0 - 1.0
		_: value = sin(p * TAU)
	return {"value": offset + value * amplitude}


static func pulse(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var attack := maxf(0.0001, FxPortType.as_number(params.get("attack", 0.15), 0.15))
	var hold := maxf(0.0, FxPortType.as_number(params.get("hold", 0.2), 0.2))
	var release := maxf(0.0001, FxPortType.as_number(params.get("release", 0.35), 0.35))
	var period := maxf(attack + hold + release, FxPortType.as_number(params.get("period", 1.0), 1.0))
	var amplitude := FxPortType.as_number(params.get("amplitude", 1.0), 1.0)
	var t: float = fposmod(ctx.t, period)
	var value := 0.0
	if t < attack:
		value = FxPixelKit.smoothstep(0.0, attack, t)
	elif t < attack + hold:
		value = 1.0
	elif t < attack + hold + release:
		value = 1.0 - FxPixelKit.smoothstep(0.0, release, t - attack - hold)
	return {"value": value * amplitude}


static func steps(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var text := FxPortType.as_string(params.get("values", "0,0.25,0.5,1"), "0,0.25,0.5,1")
	var values: Array[float] = []
	for part in text.split(","):
		values.append(float(String(part).strip_edges()))
	if values.is_empty():
		return {"value": 0.0}
	var p := _phase(ctx, params)
	var interp := FxPortType.as_string(params.get("interp", "linear"), "linear")
	if interp == "step":
		return {"value": values[clampi(int(p * float(values.size())), 0, values.size() - 1)]}
	var scaled: float = p * float(values.size() - 1)
	var i := clampi(int(floor(scaled)), 0, values.size() - 1)
	var j := mini(i + 1, values.size() - 1)
	return {"value": lerpf(values[i], values[j], scaled - float(i))}


static func noise1d(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var seed := FxPortType.as_int(params.get("seed", 13), 13)
	var frequency := maxf(0.001, FxPortType.as_number(params.get("frequency", 1.0), 1.0))
	var octaves := clampi(FxPortType.as_int(params.get("octaves", 3), 3), 1, 8)
	var amplitude := FxPortType.as_number(params.get("amplitude", 1.0), 1.0)
	var offset := FxPortType.as_number(params.get("offset", 0.0), 0.0)
	var n: float = FxPixelKit.fbm(ctx.t * frequency, 0.37, seed, octaves)
	return {"value": offset + (n * 2.0 - 1.0) * amplitude}


static func remap_value(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var raw := FxPortType.as_number(inputs.get("value", params.get("value", 0.0)), 0.0)
	var in_min := FxPortType.as_number(params.get("in_min", 0.0), 0.0)
	var in_max := FxPortType.as_number(params.get("in_max", 1.0), 1.0)
	var out_min := FxPortType.as_number(params.get("out_min", 0.0), 0.0)
	var out_max := FxPortType.as_number(params.get("out_max", 100.0), 100.0)
	var t: float = (raw - in_min) / maxf(in_max - in_min, 0.000001)
	if FxPortType.as_bool(params.get("clamp", true), true):
		t = clampf(t, 0.0, 1.0)
	var curve := FxPortType.as_string(params.get("curve", "linear"), "linear")
	match curve:
		"smooth": t = FxPixelKit.smoothstep(0.0, 1.0, t)
		"square": t = t * t
		"sqrt": t = sqrt(maxf(t, 0.0))
	return {"value": lerpf(out_min, out_max, t)}
