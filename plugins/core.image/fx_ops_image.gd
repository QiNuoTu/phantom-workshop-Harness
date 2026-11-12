class_name FxOpsImage
extends RefCounted
## 图像处理算子：模糊、色阶、染色、变换、混合、阈值、反相、最终图层合成。
##
## 所有算子都是纯函数：输入 Image + 参数 → 新的 Image。
## 不读写 ctx.state（那是 image.accumulate 的事），也不关心自己排在第几个。

static func ops() -> Dictionary:
	return {
		&"image.blur": func(ctx, node, d, inputs, params): return blur(ctx, node, d, inputs, params),
		&"image.levels": func(ctx, node, d, inputs, params): return levels(ctx, node, d, inputs, params),
		&"image.tint": func(ctx, node, d, inputs, params): return tint(ctx, node, d, inputs, params),
		&"image.transform": func(ctx, node, d, inputs, params): return transform(ctx, node, d, inputs, params),
		&"image.mix": func(ctx, node, d, inputs, params): return mix(ctx, node, d, inputs, params),
		&"image.threshold": func(ctx, node, d, inputs, params): return threshold(ctx, node, d, inputs, params),
		&"image.invert": func(ctx, node, d, inputs, params): return invert(ctx, node, d, inputs, params),
		&"output.final": func(ctx, node, d, inputs, params): return output_final(ctx, node, d, inputs, params),
		&"output.preview": func(ctx, node, d, inputs, params): return output_preview(ctx, node, d, inputs, params),
	}


static func _image_or_canvas(inputs: Dictionary, ctx: FxEvalContext) -> Image:
	var image: Variant = inputs.get("image")
	if image is Image:
		return image
	return FxImageUtil.new_canvas(ctx.canvas)


static func blur(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _image_or_canvas(inputs, ctx)
	# 半径上限、是否走快速路径、算子质量系数全部来自质量策略代理，
	# 插件可以覆盖其中任意一项，核心算子不写死任何阈值。
	var max_radius := clampi(ctx.int_option("max_blur_radius", 32), 1, 128)
	var radius := clampi(FxPortType.as_int(params.get("radius", 2), 2), 0, max_radius)
	if radius <= 0:
		return {"image": source.duplicate()}
	var fast := ctx.bool_option("blur_fast_path", true)
	var threshold := ctx.float_option("operator_quality_threshold", 0.999)
	if fast and (ctx.quality == 0 or ctx.operator_quality < threshold):
		return {"image": _fast_blur(source, radius, ctx.operator_quality)}
	return {"image": _box_blur(source, radius)}


## 预览用快速模糊：缩到 1/factor 再放大，双向双线性。
## 质量系数越低缩得越狠；1.0 时退化为精确路径（由调用方判断）。
static func _fast_blur(source: Image, radius: int, operator_quality: float = 0.0) -> Image:
	var width := source.get_width()
	var height := source.get_height()
	var factor := clampf(float(radius) * 0.9, 1.35, 12.0)
	factor *= lerpf(1.6, 1.0, clampf(operator_quality, 0.0, 1.0))
	var small_w := maxi(1, int(round(float(width) / factor)))
	var small_h := maxi(1, int(round(float(height) / factor)))
	if small_w >= width or small_h >= height:
		return source.duplicate()
	var out: Image = source.duplicate()
	out.resize(small_w, small_h, Image.INTERPOLATE_BILINEAR)
	out.resize(width, height, Image.INTERPOLATE_BILINEAR)
	return out


## 可分离盒式模糊：先横后竖，边界夹取。导出/精确路径使用。
static func _box_blur(source: Image, radius: int) -> Image:
	var width := source.get_width()
	var height := source.get_height()
	var window := float(radius * 2 + 1)
	var temp := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	var out := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in range(height):
		var r := 0.0
		var g := 0.0
		var b := 0.0
		var a := 0.0
		for k in range(-radius, radius + 1):
			var c := source.get_pixel(clampi(k, 0, width - 1), y)
			r += c.r
			g += c.g
			b += c.b
			a += c.a
		for x in range(width):
			temp.set_pixel(x, y, Color(r / window, g / window, b / window, a / window))
			var leaving := source.get_pixel(clampi(x - radius, 0, width - 1), y)
			var entering := source.get_pixel(clampi(x + radius + 1, 0, width - 1), y)
			r += entering.r - leaving.r
			g += entering.g - leaving.g
			b += entering.b - leaving.b
			a += entering.a - leaving.a
	for x in range(width):
		var r2 := 0.0
		var g2 := 0.0
		var b2 := 0.0
		var a2 := 0.0
		for k in range(-radius, radius + 1):
			var c2 := temp.get_pixel(x, clampi(k, 0, height - 1))
			r2 += c2.r
			g2 += c2.g
			b2 += c2.b
			a2 += c2.a
		for y2 in range(height):
			out.set_pixel(x, y2, Color(r2 / window, g2 / window, b2 / window, a2 / window))
			var leaving2 := temp.get_pixel(x, clampi(y2 - radius, 0, height - 1))
			var entering2 := temp.get_pixel(x, clampi(y2 + radius + 1, 0, height - 1))
			r2 += entering2.r - leaving2.r
			g2 += entering2.g - leaving2.g
			b2 += entering2.b - leaving2.b
			a2 += entering2.a - leaving2.a
	return out


static func levels(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _image_or_canvas(inputs, _ctx)
	var brightness := clampf(FxPortType.as_number(params.get("brightness", 0.0), 0.0), -1.0, 1.0)
	var contrast := clampf(FxPortType.as_number(params.get("contrast", 1.0), 1.0), 0.0, 4.0)
	var gamma := maxf(FxPortType.as_number(params.get("gamma", 1.0), 1.0), 0.05)
	var out: Image = source.duplicate()
	FxImageUtil._ensure_rgba(out)
	# 三通道共用同一条曲线：先算 256 项 LUT，再逐字节查表。
	var lut := PackedByteArray()
	lut.resize(256)
	for i in range(256):
		lut[i] = int(round(clampf(_level_channel(float(i) / 255.0, brightness, contrast, gamma), 0.0, 1.0) * 255.0))
	var data := out.get_data()
	for i in range(0, data.size(), 4):
		data[i] = lut[data[i]]
		data[i + 1] = lut[data[i + 1]]
		data[i + 2] = lut[data[i + 2]]
	out.set_data(out.get_width(), out.get_height(), false, Image.FORMAT_RGBA8, data)
	return {"image": out}


static func _level_channel(value: float, brightness: float, contrast: float, gamma: float) -> float:
	var v := (value - 0.5) * contrast + 0.5 + brightness
	v = clampf(v, 0.0, 1.0)
	return pow(v, 1.0 / gamma)


static func tint(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _image_or_canvas(inputs, _ctx)
	var tint_color := FxPortType.as_color(params.get("color", "#ff7a2a"), Color(1.0, 0.48, 0.16))
	var amount := clampf(FxPortType.as_number(params.get("amount", 1.0), 1.0), 0.0, 1.0)
	var preserve := FxPortType.as_bool(params.get("preserve_luma", false), false)
	var out: Image = source.duplicate()
	var width := out.get_width()
	var height := out.get_height()
	var tint_luma := maxf(FxImageUtil.luma(tint_color), 0.001)
	for y in range(height):
		for x in range(width):
			var c := out.get_pixel(x, y)
			var tinted := Color(c.r * tint_color.r, c.g * tint_color.g, c.b * tint_color.b, c.a)
			if preserve:
				var l := FxImageUtil.luma(c)
				tinted = Color(
					clampf(tint_color.r * l / tint_luma, 0.0, 1.0),
					clampf(tint_color.g * l / tint_luma, 0.0, 1.0),
					clampf(tint_color.b * l / tint_luma, 0.0, 1.0),
					c.a
				)
			out.set_pixel(x, y, c.lerp(tinted, amount))
	return {"image": out}


static func transform(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _image_or_canvas(inputs, _ctx)
	var offset := FxPortType.as_vec2(params.get("offset", [0, 0]), Vector2.ZERO)
	var scale := FxPortType.as_vec2(params.get("scale", [1, 1]), Vector2.ONE)
	scale.x = FxImageUtil.safe_scale(scale.x)
	scale.y = FxImageUtil.safe_scale(scale.y)
	var angle := deg_to_rad(FxPortType.as_number(params.get("rotation", 0.0), 0.0))
	var anchor := FxPortType.as_vec2(params.get("anchor", [0.5, 0.5]), Vector2(0.5, 0.5))
	var wrap := FxPortType.as_string(params.get("wrap", "transparent"), "transparent")
	var width := source.get_width()
	var height := source.get_height()
	FxImageUtil._ensure_rgba(source)
	var src := source.get_data()
	var dst := PackedByteArray()
	dst.resize(width * height * 4)
	# 原来每像素 get_pixel + set_pixel 两次 GDScript 调用（192×108 实测 ~68ms）。
	# 改成字节缓冲直接搬运：旋转/缩放常数外提，wrap 判断内联。
	var cx := anchor.x * float(width)
	var cy := anchor.y * float(height)
	var cs := cos(angle)
	var sn := sin(angle)
	var inv_sx := 1.0 / scale.x
	var inv_sy := 1.0 / scale.y
	var repeat := wrap == "repeat"
	var clamp_edge := wrap == "clamp"
	var index := 0
	for y in range(height):
		var py: float = float(y) + 0.5 - cy - offset.y
		for x in range(width):
			var px: float = float(x) + 0.5 - cx - offset.x
			# Vector2.rotated(-angle)：x' = px*cos + py*sin，y' = -px*sin + py*cos
			var sx := int(floor((px * cs + py * sn) * inv_sx + cx))
			var sy := int(floor((-px * sn + py * cs) * inv_sy + cy))
			if repeat:
				sx = posmod(sx, width)
				sy = posmod(sy, height)
			elif clamp_edge:
				sx = clampi(sx, 0, width - 1)
				sy = clampi(sy, 0, height - 1)
			elif sx < 0 or sy < 0 or sx >= width or sy >= height:
				index += 4
				continue
			var si: int = (sy * width + sx) * 4
			if src[si + 3] > 0:
				dst[index] = src[si]
				dst[index + 1] = src[si + 1]
				dst[index + 2] = src[si + 2]
				dst[index + 3] = src[si + 3]
			index += 4
	var out := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, dst)
	return {"image": out}


static func _sample(source: Image, x: int, y: int, wrap: String) -> Color:
	var width := source.get_width()
	var height := source.get_height()
	if wrap == "repeat":
		x = posmod(x, width)
		y = posmod(y, height)
	elif wrap == "clamp":
		x = clampi(x, 0, width - 1)
		y = clampi(y, 0, height - 1)
	elif x < 0 or y < 0 or x >= width or y >= height:
		return Color(0, 0, 0, 0)
	return source.get_pixel(x, y)


static func mix(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var base: Variant = inputs.get("a")
	var top: Variant = inputs.get("b")
	if not (base is Image) and not (top is Image):
		return {"image": FxImageUtil.new_canvas(ctx.canvas)}
	if not base is Image:
		return {"image": (top as Image).duplicate()}
	var out: Image = (base as Image).duplicate()
	if not top is Image:
		return {"image": out}
	var mode := FxPortType.as_string(params.get("mode", "normal"), "normal")
	var amount := clampf(FxPortType.as_number(params.get("amount", 1.0), 1.0), 0.0, 1.0)
	FxImageUtil.blend_image(out, top as Image, Vector2.ZERO, mode, amount)
	return {"image": out}


static func threshold(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source := _image_or_canvas(inputs, ctx)
	var cutoff := clampf(FxPortType.as_number(params.get("cutoff", 0.5), 0.5), 0.0, 1.0)
	var softness := clampf(FxPortType.as_number(params.get("softness", 0.02), 0.02), 0.0, 0.5)
	var channel := FxPortType.as_string(params.get("channel", "alpha"), "alpha")
	var color := FxPortType.as_color(params.get("color", "#ffffff"), Color.WHITE)
	var out := FxImageUtil.new_canvas(Vector2i(source.get_width(), source.get_height()))
	var src: Image = source
	if src.is_compressed() or src.get_format() != Image.FORMAT_RGBA8:
		src = src.duplicate()
		FxImageUtil._ensure_rgba(src)
	var data := src.get_data()
	var out_data := out.get_data()
	var cr := int(round(color.r * 255.0))
	var cg := int(round(color.g * 255.0))
	var cb := int(round(color.b * 255.0))
	var ca := int(round(color.a * 255.0))
	for i in range(0, data.size(), 4):
		var value := 0.0
		if channel == "alpha":
			value = float(data[i + 3]) / 255.0
		else:
			value = (0.2126 * float(data[i]) + 0.7152 * float(data[i + 1])
				+ 0.0722 * float(data[i + 2])) / 255.0
		var k := 0.0
		if softness <= 0.0001:
			k = 1.0 if value >= cutoff else 0.0
		else:
			k = smoothstep(cutoff - softness, cutoff + softness, value)
		if k <= 0.0:
			continue
		out_data[i] = cr
		out_data[i + 1] = cg
		out_data[i + 2] = cb
		out_data[i + 3] = int(round(float(ca) * k))
	out.set_data(out.get_width(), out.get_height(), false, Image.FORMAT_RGBA8, out_data)
	return {"image": out}


static func invert(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var source := _image_or_canvas(inputs, ctx)
	var out: Image = source.duplicate()
	FxImageUtil._ensure_rgba(out)
	var data := out.get_data()
	for i in range(0, data.size(), 4):
		data[i] = 255 - data[i]
		data[i + 1] = 255 - data[i + 1]
		data[i + 2] = 255 - data[i + 2]
	out.set_data(out.get_width(), out.get_height(), false, Image.FORMAT_RGBA8, data)
	return {"image": out}


## 最终输出：背景色 → 背景图 → 图层 0..n（从底到顶）。
## 图层的端口由 FxPortProviders 按 params.layers 动态长出；模型与界面共用。
##
## 输出链**永不降采样**：播放时 quality=0 只用来给中间算子省算力，
## 若这里降到半分辨率再放大，预览窗口在播放时会明显发糊、与导出结果不一致。
## 输出预览：纯直通。没有输入时给一张透明画布，节点预览区不至于空着。
static func output_preview(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var image: Variant = inputs.get("image")
	if not image is Image:
		return {"image": FxImageUtil.new_canvas(ctx.canvas, Color(0, 0, 0, 0))}
	return {"image": image}


static func output_final(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var width := FxPortType.as_int(params.get("canvas_width", 0), 0)
	var height := FxPortType.as_int(params.get("canvas_height", 0), 0)
	var size := Vector2i(
		clampi(width, 1, FxGraphDoc.MAX_CANVAS) if width > 0 else ctx.canvas.x,
		clampi(height, 1, FxGraphDoc.MAX_CANVAS) if height > 0 else ctx.canvas.y
	)
	var work := size
	var canvas := FxImageUtil.new_canvas(work, FxPortType.as_color(
		params.get("background_color", "#00000000"), Color(0, 0, 0, 0)))
	var background: Variant = inputs.get("background")
	if background is Image:
		FxImageUtil.blend_image(canvas, _scaled((background as Image), work), Vector2.ZERO, "normal", 1.0)
	var layers: Variant = params.get("layers", [])
	if not layers is Array:
		layers = []
	for i in range((layers as Array).size()):
		var layer: Variant = (layers as Array)[i]
		if not layer is Dictionary:
			continue
		var layer_data: Dictionary = layer
		if not FxPortType.as_bool(layer_data.get("visible", true), true):
			continue
		var layer_id := String(layer_data.get("id", str(i)))
		var image: Variant = inputs.get("layer_%s" % layer_id)
		if not image is Image:
			continue
		var offset := FxPortType.as_vec2(layer_data.get("offset", [0, 0]), Vector2.ZERO)
		var mode := FxPortType.as_string(layer_data.get("blend", "normal"), "normal")
		var opacity := clampf(FxPortType.as_number(layer_data.get("opacity", 1.0), 1.0), 0.0, 1.0)
		FxImageUtil.blend_image(canvas, _scaled((image as Image), work), offset, mode, opacity)
	return {"image": canvas}


static func _scaled(image: Image, target: Vector2i) -> Image:
	if image.get_width() == target.x and image.get_height() == target.y:
		return image
	var copy: Image = image.duplicate()
	copy.resize(target.x, target.y, Image.INTERPOLATE_BILINEAR)
	return copy
