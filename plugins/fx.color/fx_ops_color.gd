class_name FxOpsColor
extends RefCounted
## 调色与色彩映射算子。FxPixelKit.map 在字节缓冲上一次遍历完成全部变换。

static func ops() -> Dictionary:
	return {
		&"image.hue": func(ctx, node, d, inputs, params): return hue(ctx, node, d, inputs, params),
		&"image.posterize": func(ctx, node, d, inputs, params): return posterize(ctx, node, d, inputs, params),
		&"image.ramp": func(ctx, node, d, inputs, params): return ramp(ctx, node, d, inputs, params),
		&"image.duotone": func(ctx, node, d, inputs, params): return duotone(ctx, node, d, inputs, params),
		&"image.chroma_key": func(ctx, node, d, inputs, params): return chroma_key(ctx, node, d, inputs, params),
	}


static func _source(ctx: FxEvalContext, inputs: Dictionary) -> Image:
	return FxPixelKit.image_of(inputs, ctx)


static func hue(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var shift: float = FxPortType.as_number(params.get("hue", 0.0), 0.0) / 360.0
	var sat: float = FxPortType.as_number(params.get("saturation", 0.0), 0.0)
	var val: float = FxPortType.as_number(params.get("value", 0.0), 0.0)
	var image := FxPixelKit.map_batch(source, func(src: PackedByteArray, bw: int, bh: int) -> PackedByteArray:
		var dst := PackedByteArray()
		dst.resize(src.size())
		var w := float(bw)
		var h := float(bh)
		var index := 0
		for by in range(bh):
			var y := float(by)
			for bx in range(bw):
				var x := float(bx)
				var c := Color(float(src[index]) / 255.0, float(src[index + 1]) / 255.0,
					float(src[index + 2]) / 255.0, float(src[index + 3]) / 255.0)
				var hsv := FxPixelKit.rgb_to_hsv(c)
				var out := FxPixelKit.hsv_to_rgb(hsv.x + shift,
					clampf(hsv.y + sat, 0.0, 1.0), clampf(hsv.z + val, 0.0, 1.0))
				out.a = c.a
				var result: Color = out
				dst[index] = int(clampf(result.r * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 1] = int(clampf(result.g * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 2] = int(clampf(result.b * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 3] = int(clampf(result.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return dst
	)
	return {"image": image}


static func posterize(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var levels := maxf(2.0, float(FxPortType.as_int(params.get("levels", 8), 8)))
	var dither := FxPortType.as_bool(params.get("dither", false), false)
	var amount := clampf(FxPortType.as_number(params.get("amount", 1.0), 1.0), 0.0, 1.0)
	var image := FxPixelKit.map_batch(source, func(src: PackedByteArray, bw: int, bh: int) -> PackedByteArray:
		var dst := PackedByteArray()
		dst.resize(src.size())
		var w := float(bw)
		var h := float(bh)
		var index := 0
		for by in range(bh):
			var y := float(by)
			for bx in range(bw):
				var x := float(bx)
				var c := Color(float(src[index]) / 255.0, float(src[index + 1]) / 255.0,
					float(src[index + 2]) / 255.0, float(src[index + 3]) / 255.0)
				var bias: float = 0.0
				if dither:
					bias = (FxPixelKit.hash2(int(x), int(y), 7) - 0.5) / levels
				var r: float = round((c.r + bias) * (levels - 1.0)) / (levels - 1.0)
				var g: float = round((c.g + bias) * (levels - 1.0)) / (levels - 1.0)
				var b: float = round((c.b + bias) * (levels - 1.0)) / (levels - 1.0)
				var result: Color = Color(lerpf(c.r, clampf(r, 0.0, 1.0), amount),
					lerpf(c.g, clampf(g, 0.0, 1.0), amount),
					lerpf(c.b, clampf(b, 0.0, 1.0), amount), c.a)
				dst[index] = int(clampf(result.r * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 1] = int(clampf(result.g * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 2] = int(clampf(result.b * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 3] = int(clampf(result.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return dst
	)
	return {"image": image}


static func ramp(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var shadow := FxPortType.as_color(params.get("shadow", "#101a30"), Color(0.06, 0.1, 0.19))
	var mid := FxPortType.as_color(params.get("mid", "#4cc2ff"), Color(0.3, 0.76, 1.0))
	var high := FxPortType.as_color(params.get("highlight", "#ffe6a7"), Color(1, 0.9, 0.65))
	var midpoint := clampf(FxPortType.as_number(params.get("midpoint", 0.5), 0.5), 0.05, 0.95)
	var amount := clampf(FxPortType.as_number(params.get("amount", 1.0), 1.0), 0.0, 1.0)
	var image := FxPixelKit.map_batch(source, func(src: PackedByteArray, bw: int, bh: int) -> PackedByteArray:
		var dst := PackedByteArray()
		dst.resize(src.size())
		var w := float(bw)
		var h := float(bh)
		var index := 0
		for by in range(bh):
			var y := float(by)
			for bx in range(bw):
				var x := float(bx)
				var c := Color(float(src[index]) / 255.0, float(src[index + 1]) / 255.0,
					float(src[index + 2]) / 255.0, float(src[index + 3]) / 255.0)
				var l := FxImageUtil.luma(c)
				var mapped := shadow.lerp(mid, clampf(l / midpoint, 0.0, 1.0)) if l <= midpoint \
					else mid.lerp(high, clampf((l - midpoint) / maxf(1.0 - midpoint, 0.001), 0.0, 1.0))
				var result: Color = Color(lerpf(c.r, mapped.r, amount), lerpf(c.g, mapped.g, amount),
					lerpf(c.b, mapped.b, amount), c.a)
				dst[index] = int(clampf(result.r * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 1] = int(clampf(result.g * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 2] = int(clampf(result.b * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 3] = int(clampf(result.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return dst
	)
	return {"image": image}


static func duotone(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var dark := FxPortType.as_color(params.get("dark", "#132038"), Color(0.07, 0.12, 0.22))
	var light := FxPortType.as_color(params.get("light", "#ffb454"), Color(1, 0.7, 0.33))
	var amount := clampf(FxPortType.as_number(params.get("amount", 1.0), 1.0), 0.0, 1.0)
	var gamma := clampf(FxPortType.as_number(params.get("gamma", 1.0), 1.0), 0.2, 4.0)
	var image := FxPixelKit.map_batch(source, func(src: PackedByteArray, bw: int, bh: int) -> PackedByteArray:
		var dst := PackedByteArray()
		dst.resize(src.size())
		var w := float(bw)
		var h := float(bh)
		var index := 0
		for by in range(bh):
			var y := float(by)
			for bx in range(bw):
				var x := float(bx)
				var c := Color(float(src[index]) / 255.0, float(src[index + 1]) / 255.0,
					float(src[index + 2]) / 255.0, float(src[index + 3]) / 255.0)
				var l := pow(clampf(FxImageUtil.luma(c), 0.0, 1.0), 1.0 / gamma)
				var mapped := dark.lerp(light, l)
				var result: Color = Color(lerpf(c.r, mapped.r, amount), lerpf(c.g, mapped.g, amount),
					lerpf(c.b, mapped.b, amount), c.a)
				dst[index] = int(clampf(result.r * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 1] = int(clampf(result.g * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 2] = int(clampf(result.b * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 3] = int(clampf(result.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return dst
	)
	return {"image": image}


static func chroma_key(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var key := FxPortType.as_color(params.get("key", "#00ff00"), Color(0, 1, 0))
	var tolerance := clampf(FxPortType.as_number(params.get("tolerance", 0.25), 0.25), 0.0, 1.0)
	var feather := clampf(FxPortType.as_number(params.get("feather", 0.08), 0.08), 0.0, 0.5)
	var despill := FxPortType.as_bool(params.get("despill", true), true)
	var image := FxPixelKit.map_batch(source, func(src: PackedByteArray, bw: int, bh: int) -> PackedByteArray:
		var dst := PackedByteArray()
		dst.resize(src.size())
		var w := float(bw)
		var h := float(bh)
		var index := 0
		for by in range(bh):
			var y := float(by)
			for bx in range(bw):
				var x := float(bx)
				var c := Color(float(src[index]) / 255.0, float(src[index + 1]) / 255.0,
					float(src[index + 2]) / 255.0, float(src[index + 3]) / 255.0)
				var dr: float = c.r - key.r
				var dg: float = c.g - key.g
				var db: float = c.b - key.b
				var dist: float = sqrt(dr * dr + dg * dg + db * db) / 1.732
				var alpha: float = FxPixelKit.smoothstep(tolerance, tolerance + maxf(feather, 0.0001), dist)
				var out := c
				if despill and alpha < 1.0:
					var excess: float = maxf(0.0, c.g - maxf(c.r, c.b))
					out.g = c.g - excess * (1.0 - alpha) * 0.9
				out.a = c.a * alpha
				var result: Color = out
				dst[index] = int(clampf(result.r * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 1] = int(clampf(result.g * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 2] = int(clampf(result.b * 255.0 + 0.5, 0.0, 255.0))
				dst[index + 3] = int(clampf(result.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return dst
	)
	return {"image": image}
