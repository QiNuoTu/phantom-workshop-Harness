class_name FxOpsGenerators
extends RefCounted
## 程序化贴图生成算子。全部是纯函数：ctx.canvas + params → Image。
## 用 FxPixelKit.generate（字节级缓冲）避免逐像素 get_pixel/set_pixel。

static func ops() -> Dictionary:
	return {
		&"image.gradient": func(ctx, node, d, inputs, params): return gradient(ctx, node, d, inputs, params),
		&"image.shape": func(ctx, node, d, inputs, params): return shape(ctx, node, d, inputs, params),
		&"image.stripes": func(ctx, node, d, inputs, params): return stripes(ctx, node, d, inputs, params),
		&"image.voronoi": func(ctx, node, d, inputs, params): return voronoi(ctx, node, d, inputs, params),
		&"image.starfield": func(ctx, node, d, inputs, params): return starfield(ctx, node, d, inputs, params),
	}


static func _size(ctx: FxEvalContext, inputs: Dictionary) -> Vector2i:
	return FxPixelKit.size_of(inputs, ctx)


static func gradient(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var mode := FxPortType.as_string(params.get("mode", "linear"), "linear")
	var a := FxPortType.as_color(params.get("color_a", "#102040"), Color(0.06, 0.12, 0.25))
	var b := FxPortType.as_color(params.get("color_b", "#ffb454"), Color(1, 0.7, 0.33))
	var angle := deg_to_rad(FxPortType.as_number(params.get("angle", 0.0), 0.0))
	var center := FxPortType.as_vec2(params.get("center", [0.5, 0.5]), Vector2(0.5, 0.5))
	var scale := maxf(0.01, FxPortType.as_number(params.get("scale", 1.0), 1.0))
	var soft := clampf(FxPortType.as_number(params.get("softness", 0.0), 0.0), 0.0, 1.0)
	var dir := Vector2(cos(angle), sin(angle))
	var image := FxPixelKit.generate_batch(size, func(bw: int, bh: int) -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(bw * bh * 4)
		var w := float(bw)
		var h := float(bh)
		var index := 0
		for by in range(bh):
			var y := float(by)
			for bx in range(bw):
				var x := float(bx)
				var nx: float = (x / maxf(w, 1.0) - center.x) * scale
				var ny: float = (y / maxf(h, 1.0) - center.y) * scale
				var t := 0.0
				match mode:
					"radial":
						t = clampf(sqrt(nx * nx + ny * ny) * 2.0, 0.0, 1.0)
					"angle":
						t = fposmod(atan2(ny, nx) / TAU + 0.5, 1.0)
					_:
						t = clampf(nx * dir.x + ny * dir.y + 0.5, 0.0, 1.0)
				if soft > 0.0:
					t = FxPixelKit.smoothstep(0.5 - soft * 0.5, 0.5 + soft * 0.5, t)
				var c: Color = a.lerp(b, clampf(t, 0.0, 1.0))
				buf[index] = int(clampf(c.r * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 1] = int(clampf(c.g * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 2] = int(clampf(c.b * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 3] = int(clampf(c.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return buf
	)
	return {"image": image}


static func shape(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var kind := FxPortType.as_string(params.get("shape", "circle"), "circle")
	var fill := FxPortType.as_color(params.get("color", "#ffcc66"), Color(1, 0.8, 0.4))
	var bg := FxPortType.as_color(params.get("background", "#00000000"), Color(0, 0, 0, 0))
	var radius := maxf(0.001, FxPortType.as_number(params.get("size", 0.6), 0.6))
	var feather := maxf(0.0001, FxPortType.as_number(params.get("feather", 0.02), 0.02))
	var sides := clampi(FxPortType.as_int(params.get("sides", 5), 5), 3, 16)
	var center := FxPortType.as_vec2(params.get("center", [0.5, 0.5]), Vector2(0.5, 0.5))
	var rotation := deg_to_rad(FxPortType.as_number(params.get("rotation", 0.0), 0.0))
	var aspect: float = float(size.x) / maxf(float(size.y), 1.0)
	# 常量全部外提：旋转的 cos/sin、星形分段、形状 id、feather 倒数
	# 原来都在每像素循环里重算（192×108 就是两万多次三角函数 + 字符串 match）。
	var cs: float = cos(rotation)
	var sn: float = sin(rotation)
	var seg: float = TAU / float(sides)
	var inv_feather := 1.0 / (2.0 * feather)
	var kind_id := 0
	match kind:
		"ring": kind_id = 1
		"rect": kind_id = 2
		"diamond": kind_id = 3
		"triangle": kind_id = 4
		"star": kind_id = 5
	var image := FxPixelKit.generate_batch(size, func(bw: int, bh: int) -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(bw * bh * 4)
		var w := float(bw)
		var h := float(bh)
		var inv_w := 1.0 / maxf(w, 1.0)
		var inv_h := 1.0 / maxf(h, 1.0)
		var index := 0
		for by in range(bh):
			var py: float = (float(by) * inv_h - center.y) * 2.0
			for bx in range(bw):
				var px: float = (float(bx) * inv_w - center.x) * 2.0 * aspect
				var rx: float = px * cs - py * sn
				var ry: float = px * sn + py * cs
				var dist := sqrt(rx * rx + ry * ry)
				var d := 0.0
				match kind_id:
					1:
						d = absf(dist - radius) - radius * 0.16
					2:
						var qx := absf(rx) - radius
						var qy := absf(ry) - radius
						d = sqrt(maxf(qx, 0.0) * maxf(qx, 0.0) + maxf(qy, 0.0) * maxf(qy, 0.0)) + minf(maxf(qx, qy), 0.0)
					3:
						d = (absf(rx) + absf(ry)) - radius
					4:
						d = maxf(absf(rx) * 0.866 + ry * 0.5, -ry) - radius * 0.7
					5:
						var ang: float = atan2(ry, rx)
						var bump: float = cos(fposmod(ang, seg) - seg * 0.5)
						d = dist - radius * (0.55 + 0.45 * bump)
					_:
						d = dist - radius
				var st := clampf((d + feather) * inv_feather, 0.0, 1.0)
				var coverage: float = 1.0 - st * st * (3.0 - 2.0 * st)
				var c: Color = bg.lerp(fill, clampf(coverage, 0.0, 1.0))
				buf[index] = int(clampf(c.r * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 1] = int(clampf(c.g * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 2] = int(clampf(c.b * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 3] = int(clampf(c.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return buf
	)
	return {"image": image}


static func stripes(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var mode := FxPortType.as_string(params.get("mode", "linear"), "linear")
	var a := FxPortType.as_color(params.get("color_a", "#1b2230"), Color(0.1, 0.13, 0.19))
	var b := FxPortType.as_color(params.get("color_b", "#4cc2ff"), Color(0.3, 0.76, 1.0))
	var freq := maxf(0.1, FxPortType.as_number(params.get("frequency", 8.0), 8.0))
	var angle := deg_to_rad(FxPortType.as_number(params.get("angle", 0.0), 0.0))
	var soft := clampf(FxPortType.as_number(params.get("softness", 0.05), 0.05), 0.0, 0.5)
	var phase := FxPortType.as_number(params.get("phase", 0.0), 0.0)
	var dir := Vector2(cos(angle), sin(angle))
	var image := FxPixelKit.generate_batch(size, func(bw: int, bh: int) -> PackedByteArray:
		var buf := PackedByteArray()
		buf.resize(bw * bh * 4)
		var w := float(bw)
		var h := float(bh)
		var index := 0
		for by in range(bh):
			var y := float(by)
			for bx in range(bw):
				var x := float(bx)
				var nx: float = x / maxf(w, 1.0) - 0.5
				var ny: float = y / maxf(h, 1.0) - 0.5
				var coord := 0.0
				match mode:
					"radial":
						coord = sqrt(nx * nx + ny * ny) * 2.0
					"conic":
						coord = fposmod(atan2(ny, nx) / TAU + 0.5, 1.0)
					_:
						coord = nx * dir.x + ny * dir.y
				var wave: float = sin((coord * freq + phase) * TAU)
				var t: float = 1.0 - FxPixelKit.smoothstep(-soft, soft, wave) if soft > 0.0 else (1.0 if wave >= 0.0 else 0.0)
				var c: Color = a.lerp(b, t)
				buf[index] = int(clampf(c.r * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 1] = int(clampf(c.g * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 2] = int(clampf(c.b * 255.0 + 0.5, 0.0, 255.0))
				buf[index + 3] = int(clampf(c.a * 255.0 + 0.5, 0.0, 255.0))
				index += 4
		return buf
	)
	return {"image": image}


static func voronoi(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var cells := clampi(FxPortType.as_int(params.get("cells", 12), 12), 2, 64)
	var seed := FxPortType.as_int(params.get("seed", 7), 7)
	var jitter := clampf(FxPortType.as_number(params.get("jitter", 1.0), 1.0), 0.0, 1.0)
	var outline := FxPortType.as_bool(params.get("outline", false), false)
	var a := FxPortType.as_color(params.get("color_a", "#20304a"), Color(0.12, 0.19, 0.29))
	var b := FxPortType.as_color(params.get("color_b", "#7ee787"), Color(0.49, 0.9, 0.53))
	# 特征点只在网格上算一次（(cells+2)^2 个），像素循环里只做 9 次距离比较。
	# 避免每个像素重复 hash：这是 voronoi 从 O(W·H·9·hash) 降下来的关键。
	var stride := cells + 2
	var grid: Array[Vector2] = []
	var ids: Array[float] = []
	for gy in range(-1, cells + 1):
		for gx in range(-1, cells + 1):
			grid.append(Vector2(
				float(gx) + lerpf(0.5, FxPixelKit.hash2(gx, gy, seed), jitter),
				float(gy) + lerpf(0.5, FxPixelKit.hash2(gx, gy, seed + 91), jitter)))
			ids.append(FxPixelKit.hash2(gx, gy, seed + 313))
	var image := FxPixelKit.generate(size, func(x: float, y: float, w: float, h: float) -> Color:
		var fx: float = x / maxf(w, 1.0) * float(cells)
		var fy: float = y / maxf(h, 1.0) * float(cells)
		var cx := clampi(int(floor(fx)), 0, cells - 1)
		var cy := clampi(int(floor(fy)), 0, cells - 1)
		var nearest := 999.0
		var second := 999.0
		var id := 0.0
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				var index: int = (cy + oy + 1) * stride + (cx + ox + 1)
				if index < 0 or index >= grid.size():
					continue
				var point: Vector2 = grid[index]
				var dx: float = fx - point.x
				var dy: float = fy - point.y
				var dist: float = sqrt(dx * dx + dy * dy)
				if dist < nearest:
					second = nearest
					nearest = dist
					id = ids[index]
				elif dist < second:
					second = dist
		if outline:
			var edge: float = 1.0 - FxPixelKit.smoothstep(0.0, 0.12, second - nearest)
			return a.lerp(b, edge)
		return a.lerp(b, id)
	)
	return {"image": image}


static func starfield(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var size := _size(ctx, inputs)
	var count := clampi(FxPortType.as_int(params.get("count", 80), 80), 1, 500)
	var seed := FxPortType.as_int(params.get("seed", 3), 3)
	var color := FxPortType.as_color(params.get("color", "#ffffff"), Color.WHITE)
	var bg := FxPortType.as_color(params.get("background", "#00000000"), Color(0, 0, 0, 0))
	var star_size := maxf(0.2, FxPortType.as_number(params.get("size", 1.4), 1.4))
	var glow := maxf(0.0, FxPortType.as_number(params.get("glow", 2.5), 2.5))
	var radius: float = star_size + glow
	var blobs: Array[Dictionary] = []
	for i in range(count):
		var brightness: float = 0.35 + FxPixelKit.hash2(i, 3, seed) * 0.65
		blobs.append({
			"x": FxPixelKit.hash2(i, 1, seed) * float(size.x),
			"y": FxPixelKit.hash2(i, 2, seed) * float(size.y),
			"radius": radius,
			"color": color,
			"strength": brightness,
			"core": star_size / maxf(radius, 0.001) * 0.5,
		})
	# 稀疏绘制：只遍历每颗星的包围盒，复杂度与「全图 × 星数」无关。
	return {"image": FxPixelKitBlobs.paint(size, bg, blobs)}
