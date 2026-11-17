class_name FxOpsComposite
extends RefCounted
## 图层合成与边缘算子。直接在 RGBA8 字节缓冲上做邻域/双图运算。

static func ops() -> Dictionary:
	return {
		&"image.mask": func(ctx, node, d, inputs, params): return mask(ctx, node, d, inputs, params),
		&"image.blend2": func(ctx, node, d, inputs, params): return blend2(ctx, node, d, inputs, params),
		&"image.outline": func(ctx, node, d, inputs, params): return outline(ctx, node, d, inputs, params),
		&"image.shadow": func(ctx, node, d, inputs, params): return shadow(ctx, node, d, inputs, params),
		&"image.bloom": func(ctx, node, d, inputs, params): return bloom(ctx, node, d, inputs, params),
	}


static func _rgba(image: Image) -> PackedByteArray:
	FxImageUtil._ensure_rgba(image)
	return image.get_data()


static func _commit(size: Vector2i, buf: PackedByteArray) -> Image:
	var out := FxPixelKit.canvas(size)
	out.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, buf)
	return out


static func mask(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := FxPixelKit.image_of(inputs, ctx)
	var size := Vector2i(source.get_width(), source.get_height())
	var mask_image: Variant = inputs.get("mask")
	var m: Image = mask_image if mask_image is Image else FxPixelKit.canvas(size)
	FxImageUtil._ensure_rgba(m)
	var channel := FxPortType.as_string(params.get("channel", "alpha"), "alpha")
	var invert := FxPortType.as_bool(params.get("invert", false), false)
	var softness := clampf(FxPortType.as_number(params.get("softness", 0.0), 0.0), 0.0, 1.0)
	var opacity := clampf(FxPortType.as_number(params.get("opacity", 1.0), 1.0), 0.0, 1.0)
	var channel_id := 4 if channel == "luma" else (
		1 if channel == "red" else (2 if channel == "green" else (3 if channel == "blue" else 0)))
	var native_mask := FxNativeBridge.mask_image(source, m, channel_id, invert, softness, opacity)
	if native_mask != null:
		return {"image": native_mask}
	var sb := source.get_data()
	var mb := m.get_data()
	var mw := m.get_width()
	var mh := m.get_height()
	var db := PackedByteArray()
	db.resize(sb.size())
	for y in range(size.y):
		for x in range(size.x):
			var mi: int = (clampi(int(float(y) / maxf(float(size.y), 1.0) * float(mh)), 0, mh - 1) * mw \
				+ clampi(int(float(x) / maxf(float(size.x), 1.0) * float(mw)), 0, mw - 1)) * 4
			var mc := Color(float(mb[mi]) / 255.0, float(mb[mi + 1]) / 255.0,
				float(mb[mi + 2]) / 255.0, float(mb[mi + 3]) / 255.0)
			var value := 0.0
			match channel:
				"luma": value = FxImageUtil.luma(mc)
				"red": value = mc.r
				"green": value = mc.g
				"blue": value = mc.b
				_: value = mc.a
			if invert:
				value = 1.0 - value
			if softness > 0.0:
				value = FxPixelKit.smoothstep(0.5 - softness * 0.5, 0.5 + softness * 0.5, value)
			var i: int = (y * size.x + x) * 4
			for c in range(3):
				db[i + c] = sb[i + c]
			db[i + 3] = int(round(clampf(float(sb[i + 3]) / 255.0 * value * opacity, 0.0, 1.0) * 255.0))
	return {"image": _commit(size, db)}


static func blend2(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var a: Variant = inputs.get("a")
	var b: Variant = inputs.get("b")
	var base: Image = a if a is Image else FxPixelKit.canvas(ctx.canvas)
	var top: Image = b if b is Image else FxPixelKit.canvas(FxPixelKit.size_of({"image": base}, ctx))
	var out: Image = base.duplicate()
	FxImageUtil._ensure_rgba(out)
	FxImageUtil._ensure_rgba(top)
	var mode := FxPortType.as_string(params.get("mode", "normal"), "normal")
	if not FxImageUtil.is_mode(mode):
		mode = "normal"
	var offset := FxPortType.as_vec2(params.get("offset", [0, 0]), Vector2.ZERO)
	var opacity := clampf(FxPortType.as_number(params.get("opacity", 1.0), 1.0), 0.0, 1.0)
	FxImageUtil.blend_image(out, top, offset, mode, opacity)
	return {"image": out}


static func outline(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := FxPixelKit.image_of(inputs, ctx)
	var size := Vector2i(source.get_width(), source.get_height())
	var buf := _rgba(source)
	var color := FxPortType.as_color(params.get("color", "#ffb454"), Color(1, 0.7, 0.33))
	var thickness := clampi(FxPortType.as_int(params.get("thickness", 2), 2), 1, 16)
	var mode := FxPortType.as_string(params.get("mode", "outside"), "outside")
	var threshold := FxPortType.as_number(params.get("threshold", 0.1), 0.1)
	# 原生快速路径：51.9ms → 4ms 级（示范工程实测），逐字节与下面这份一致。
	var native := FxNativeBridge.outline_alpha(source, thickness, mode == "inside",
		threshold, color)
	if native != null:
		return {"image": native}
	# 只取 8 个方向的邻域样本，而不是完整 (2r+1)^2 方块：16k 像素 × 8 次即可。
	# 8 个邻域方向展平成两个定长数组：原来每像素遍历 Array[Vector2i]
	# （8 次 Variant 拆箱）+ 调一次静态 smoothstep，是这里最大的开销。
	var dxs := PackedInt32Array([thickness, -thickness, 0, 0, thickness, -thickness, thickness, -thickness])
	var dys := PackedInt32Array([0, 0, thickness, -thickness, thickness, thickness, -thickness, -thickness])
	var db := PackedByteArray()
	db.resize(buf.size())
	var inside := mode == "inside"
	var e0 := threshold
	var inv_e := 1.0 / 0.15
	var cr := color.r
	var cg := color.g
	var cb := color.b
	for y in range(size.y):
		for x in range(size.x):
			var i: int = (y * size.x + x) * 4
			var own: float = float(buf[i + 3]) * 0.00392156862745098
			var edge := 0.0
			for k in range(8):
				var nx: int = clampi(x + dxs[k], 0, size.x - 1)
				var ny: int = clampi(y + dys[k], 0, size.y - 1)
				var na: float = float(buf[(ny * size.x + nx) * 4 + 3]) * 0.00392156862745098
				edge = maxf(edge, na - own) if not inside else maxf(edge, own - na)
			var st := clampf((edge - e0) * inv_e, 0.0, 1.0)
			var strength: float = st * st * (3.0 - 2.0 * st)
			var out_a: float = maxf(own, strength if not inside else strength * own)
			for c in range(3):
				var src_c: float = float(buf[i + c]) * 0.00392156862745098
				db[i + c] = int(round(clampf(lerpf(src_c, color[c], strength), 0.0, 1.0) * 255.0))
			db[i + 3] = int(round(clampf(out_a, 0.0, 1.0) * 255.0))
	return {"image": _commit(size, db)}


static func shadow(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := FxPixelKit.image_of(inputs, ctx)
	var size := Vector2i(source.get_width(), source.get_height())
	var buf := _rgba(source)
	var offset := FxPortType.as_vec2(params.get("offset", [6, 6]), Vector2(6, 6))
	var color := FxPortType.as_color(params.get("color", "#000000aa"), Color(0, 0, 0, 0.67))
	var blur := clampi(FxPortType.as_int(params.get("blur", 3), 3), 0, 32)
	var opacity := clampf(FxPortType.as_number(params.get("opacity", 0.6), 0.6), 0.0, 1.0)
	# 阴影 = 源 alpha 着色 → 引擎 C++ 的降采样/升采样做盒式模糊 → 平移 → 源图叠回。
	# 比原来「每个源像素扩散到 (2r+1)^2 个目标」快一个数量级。
	var layer := FxPixelKit.canvas(size)
	var native_layer := FxNativeBridge.alpha_tint(source, color, opacity)
	if native_layer != null:
		layer = native_layer
	else:
		var lb := layer.get_data()
		for i in range(0, buf.size(), 4):
			var a: float = float(buf[i + 3]) / 255.0 * opacity
			lb[i] = int(round(color.r * 255.0))
			lb[i + 1] = int(round(color.g * 255.0))
			lb[i + 2] = int(round(color.b * 255.0))
			lb[i + 3] = int(round(clampf(a, 0.0, 1.0) * 255.0))
		layer.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, lb)
	if blur > 0:
		var factor := maxi(2, blur * 2)
		var small := Vector2i(maxi(1, size.x / factor), maxi(1, size.y / factor))
		layer.resize(small.x, small.y, Image.INTERPOLATE_BILINEAR)
		layer.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	var out := FxPixelKit.canvas(size)
	out.blit_rect(layer, Rect2i(0, 0, size.x, size.y),
		Vector2i(int(offset.x), int(offset.y)))
	FxImageUtil.blend_image(out, source, Vector2.ZERO, "normal", 1.0)
	return {"image": out}


static func bloom(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := FxPixelKit.image_of(inputs, ctx)
	var size := Vector2i(source.get_width(), source.get_height())
	var buf := _rgba(source)
	var threshold := clampf(FxPortType.as_number(params.get("threshold", 0.7), 0.7), 0.0, 1.0)
	var amount := clampf(FxPortType.as_number(params.get("amount", 0.8), 0.8), 0.0, 3.0)
	var radius := clampi(FxPortType.as_int(params.get("radius", 4), 4), 1, 32)
	# 原生快速路径：阈值趟与叠加趟都是纯算术，中间的两次缩放交给引擎（C++）。
	var native_bright := FxNativeBridge.bright(source, threshold)
	if native_bright != null:
		var small_n := Vector2i(maxi(1, size.x / maxi(2, radius)),
			maxi(1, size.y / maxi(2, radius)))
		native_bright.resize(small_n.x, small_n.y, Image.INTERPOLATE_BILINEAR)
		native_bright.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		var merged := FxNativeBridge.bloom_add(source, native_bright, amount)
		if merged != null:
			return {"image": merged}
	var bright: Image = source.duplicate()
	# 两趟逐像素都按行并行：20736 像素 × 两趟算术，单线程要 30+ms，
	# 而这两趟只读输入、只写自己那几行，是最适合切片的一类。
	var bb := FxPixelParallel.map_rows(size.y, size.x, func(y0: int, y1: int) -> PackedByteArray:
		var part := PackedByteArray()
		part.resize((y1 - y0) * size.x * 4)
		var di := 0
		# 内层不再有 `for c in range(3)`：GDScript 里每次循环迭代都要付解释器开销，
		# 三个通道展开写比循环快得多（实测这一段从 11.3ms 降到 4ms 级）。
		# 亮度也内联成标量乘加，不再为每个像素构造一个 Color 对象。
		var hi: float = minf(threshold + 0.25, 1.0)
		var inv: float = 1.0 / maxf(hi - threshold, 0.00001)
		for i in range(y0 * size.x * 4, y1 * size.x * 4, 4):
			var r := float(buf[i]) * 0.00392156862745098
			var g := float(buf[i + 1]) * 0.00392156862745098
			var b := float(buf[i + 2]) * 0.00392156862745098
			var t := clampf((0.2126 * r + 0.7152 * g + 0.0722 * b - threshold) * inv, 0.0, 1.0)
			var keep: float = t * t * (3.0 - 2.0 * t)
			part[di] = int(float(buf[i]) * keep + 0.5)
			part[di + 1] = int(float(buf[i + 1]) * keep + 0.5)
			part[di + 2] = int(float(buf[i + 2]) * keep + 0.5)
			part[di + 3] = int(float(buf[i + 3]) * keep + 0.5)
			di += 4
		return part)
	bright.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, bb)
	var small := Vector2i(maxi(1, size.x / maxi(2, radius)), maxi(1, size.y / maxi(2, radius)))
	var reduced: Image = bright.duplicate()
	reduced.resize(small.x, small.y, Image.INTERPOLATE_BILINEAR)
	reduced.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	var rb := reduced.get_data()
	var db := FxPixelParallel.map_rows(size.y, size.x, func(y0: int, y1: int) -> PackedByteArray:
		var part := PackedByteArray()
		part.resize((y1 - y0) * size.x * 4)
		var di := 0
		for k in range(y0 * size.x * 4, y1 * size.x * 4, 4):
			var r := float(buf[k]) + float(rb[k]) * amount
			var g := float(buf[k + 1]) + float(rb[k + 1]) * amount
			var b := float(buf[k + 2]) + float(rb[k + 2]) * amount
			part[di] = 0 if r < 0.0 else (255 if r > 255.0 else int(r + 0.5))
			part[di + 1] = 0 if g < 0.0 else (255 if g > 255.0 else int(g + 0.5))
			part[di + 2] = 0 if b < 0.0 else (255 if b > 255.0 else int(b + 0.5))
			part[di + 3] = buf[k + 3]
			di += 4
		return part)
	return {"image": _commit(size, db)}
