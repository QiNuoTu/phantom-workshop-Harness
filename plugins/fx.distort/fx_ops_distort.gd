class_name FxOpsDistort
extends RefCounted
## 采样重映射类算子：目标像素反算源坐标，FxPixelKit.remap_batch 统一做双线性采样。
##
## 这里的 Callable 都是「整批一次」：循环写在 lambda 里，外部常数（角度、频率、
## 中心、半径、模式分支）全部外提。旧的每像素 Callable 版本在 192×108 上
## 光调用开销就 ~10ms/算子，是真实工程单帧 600ms 的主要来源之一。

static func ops() -> Dictionary:
	return {
		&"image.wave": func(ctx, node, d, inputs, params): return wave(ctx, node, d, inputs, params),
		&"image.swirl": func(ctx, node, d, inputs, params): return swirl(ctx, node, d, inputs, params),
		&"image.pixelate": func(ctx, node, d, inputs, params): return pixelate(ctx, node, d, inputs, params),
		&"image.mirror": func(ctx, node, d, inputs, params): return mirror(ctx, node, d, inputs, params),
		&"image.ripple": func(ctx, node, d, inputs, params): return ripple(ctx, node, d, inputs, params),
	}


static func _source(ctx: FxEvalContext, inputs: Dictionary) -> Image:
	return FxPixelKit.image_of(inputs, ctx)


static func wave(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var amplitude := FxPortType.as_number(params.get("amplitude", 8.0), 8.0)
	var frequency := FxPortType.as_number(params.get("frequency", 0.08), 0.08)
	var speed := FxPortType.as_number(params.get("speed", 2.0), 2.0)
	var axis := FxPortType.as_string(params.get("axis", "y"), "y")
	var axis_x := axis == "x"
	var axis_both := axis == "both"
	var omega := frequency * TAU
	var phase := ctx.t * speed
	var image := FxPixelKit.remap_batch(source, func(w: int, h: int) -> PackedFloat32Array:
		var coords := PackedFloat32Array()
		coords.resize(w * h * 2)
		# 位移只依赖单一坐标轴：把 sin 预计算成一行/一列查表，
		# 20736 次三角函数调用压到最多 max(w,h) 次。
		var shift_x := PackedFloat32Array()
		shift_x.resize(w)
		var shift_y := PackedFloat32Array()
		shift_y.resize(h)
		if axis_x:
			for y in range(h):
				shift_y[y] = sin(float(y) * omega + phase) * amplitude
		else:
			for x in range(w):
				shift_x[x] = sin(float(x) * omega + phase) * amplitude
		var ci := 0
		for y in range(h):
			var sy := shift_y[y]
			for x in range(w):
				var shift := sy if axis_x else shift_x[x]
				var ux := float(x)
				var uy := float(y)
				if axis_x or axis_both:
					ux += shift
				if axis_both:
					uy += shift * 0.6
				elif not axis_x:
					uy += shift
				coords[ci] = ux
				coords[ci + 1] = uy
				ci += 2
		return coords
	)
	return {"image": image}


static func swirl(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var strength := FxPortType.as_number(params.get("strength", 2.0), 2.0)
	var radius := maxf(0.01, FxPortType.as_number(params.get("radius", 0.8), 0.8))
	var center := FxPortType.as_vec2(params.get("center", [0.5, 0.5]), Vector2(0.5, 0.5))
	var image := FxPixelKit.remap_batch(source, func(w: int, h: int) -> PackedFloat32Array:
		var coords := PackedFloat32Array()
		coords.resize(w * h * 2)
		var cx: float = center.x * float(w)
		var cy: float = center.y * float(h)
		var inv := 1.0 / maxf(minf(float(w), float(h)) * 0.5, 1.0)
		var ci := 0
		for y in range(h):
			var dy: float = float(y) - cy
			for x in range(w):
				var dx: float = float(x) - cx
				var dist: float = sqrt(dx * dx + dy * dy) * inv
				var angle: float = strength * (1.0 - FxPixelKit.smoothstep(0.0, radius, dist))
				var cs: float = cos(angle)
				var sn: float = sin(angle)
				coords[ci] = cx + dx * cs - dy * sn
				coords[ci + 1] = cy + dx * sn + dy * cs
				ci += 2
		return coords
	)
	return {"image": image}


static func pixelate(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var block := float(clampi(FxPortType.as_int(params.get("block", 8), 8), 1, 256))
	var half := block * 0.5
	var image := FxPixelKit.remap_batch(source, func(w: int, h: int) -> PackedFloat32Array:
		var coords := PackedFloat32Array()
		coords.resize(w * h * 2)
		var map_x := PackedFloat32Array()
		map_x.resize(w)
		for x in range(w):
			map_x[x] = floor(float(x) / block) * block + half
		var map_y := PackedFloat32Array()
		map_y.resize(h)
		for y in range(h):
			map_y[y] = floor(float(y) / block) * block + half
		var ci := 0
		for y in range(h):
			var uy := map_y[y]
			for x in range(w):
				coords[ci] = map_x[x]
				coords[ci + 1] = uy
				ci += 2
		return coords
	)
	return {"image": image}


static func mirror(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var axis := FxPortType.as_string(params.get("axis", "x"), "x")
	var flip_x := axis == "x" or axis == "both"
	var flip_y := axis == "y" or axis == "both"
	var pivot := clampf(FxPortType.as_number(params.get("offset", 0.5), 0.5), 0.0, 1.0)
	var image := FxPixelKit.remap_batch(source, func(w: int, h: int) -> PackedFloat32Array:
		var coords := PackedFloat32Array()
		coords.resize(w * h * 2)
		var px := 2.0 * pivot * float(w)
		var py := 2.0 * pivot * float(h)
		var cut_x := pivot * float(w)
		var cut_y := pivot * float(h)
		var ci := 0
		for y in range(h):
			var fy := float(y)
			var uy := (py - fy) if flip_y and fy > cut_y else fy
			for x in range(w):
				var fx := float(x)
				coords[ci] = (px - fx) if flip_x and fx > cut_x else fx
				coords[ci + 1] = uy
				ci += 2
		return coords
	)
	return {"image": image}


static func ripple(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _source(ctx, inputs)
	var amplitude := FxPortType.as_number(params.get("amplitude", 6.0), 6.0)
	var frequency := FxPortType.as_number(params.get("frequency", 0.18), 0.18)
	var speed := FxPortType.as_number(params.get("speed", 3.0), 3.0)
	var center := FxPortType.as_vec2(params.get("center", [0.5, 0.5]), Vector2(0.5, 0.5))
	var omega := frequency * TAU
	var phase := ctx.t * speed * TAU
	var image := FxPixelKit.remap_batch(source, func(w: int, h: int) -> PackedFloat32Array:
		var coords := PackedFloat32Array()
		coords.resize(w * h * 2)
		var cx: float = center.x * float(w)
		var cy: float = center.y * float(h)
		var ci := 0
		for y in range(h):
			var dy: float = float(y) - cy
			for x in range(w):
				var dx: float = float(x) - cx
				var dist: float = sqrt(dx * dx + dy * dy)
				var shift: float = sin(dist * omega - phase) * amplitude
				var scale: float = (dist + shift) / maxf(dist, 0.001)
				coords[ci] = cx + dx * scale
				coords[ci + 1] = cy + dy * scale
				ci += 2
		return coords
	)
	return {"image": image}
