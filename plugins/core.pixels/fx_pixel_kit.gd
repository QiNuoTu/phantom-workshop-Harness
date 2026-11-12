class_name FxPixelKit
extends RefCounted
## 程序化图像生成的共享套件（字节级 RGBA8，避免逐像素 get_pixel 的开销）。
## 所有图像/特效插件都注入 plugin.core.pixels 后使用，不各自复制一份数学工具。


static func canvas(size: Vector2i, fill: Color = Color(0, 0, 0, 0)) -> Image:
	return FxImageUtil.new_canvas(size, fill)


static func size_of(inputs: Dictionary, ctx: FxEvalContext) -> Vector2i:
	var image: Variant = inputs.get("image")
	if image is Image:
		return Vector2i((image as Image).get_width(), (image as Image).get_height())
	return ctx.canvas


static func image_of(inputs: Dictionary, ctx: FxEvalContext) -> Image:
	var image: Variant = inputs.get("image")
	if image is Image:
		FxImageUtil._ensure_rgba(image)
		return image
	return canvas(ctx.canvas)


## 生成一张图：fn(x: float, y: float, w: float, h: float) -> Color。
static func generate(size: Vector2i, fn: Callable) -> Image:
	var image := canvas(size)
	var buf := image.get_data()
	var w := float(size.x)
	var h := float(size.y)
	var index := 0
	for y in range(size.y):
		for x in range(size.x):
			var c: Color = fn.call(float(x), float(y), w, h)
			buf[index] = int(round(clampf(c.r, 0.0, 1.0) * 255.0))
			buf[index + 1] = int(round(clampf(c.g, 0.0, 1.0) * 255.0))
			buf[index + 2] = int(round(clampf(c.b, 0.0, 1.0) * 255.0))
			buf[index + 3] = int(round(clampf(c.a, 0.0, 1.0) * 255.0))
			index += 4
	image.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, buf)
	return image


## 逐像素变换：fn(x: float, y: float, c: Color, w: float, h: float) -> Color。
static func map(source: Image, fn: Callable) -> Image:
	FxImageUtil._ensure_rgba(source)
	var size := Vector2i(source.get_width(), source.get_height())
	var out := canvas(size)
	var src := source.get_data()
	var dst := out.get_data()
	var w := float(size.x)
	var h := float(size.y)
	var index := 0
	for y in range(size.y):
		for x in range(size.x):
			var c := Color(
				float(src[index]) / 255.0, float(src[index + 1]) / 255.0,
				float(src[index + 2]) / 255.0, float(src[index + 3]) / 255.0)
			var result: Color = fn.call(float(x), float(y), c, w, h)
			dst[index] = int(round(clampf(result.r, 0.0, 1.0) * 255.0))
			dst[index + 1] = int(round(clampf(result.g, 0.0, 1.0) * 255.0))
			dst[index + 2] = int(round(clampf(result.b, 0.0, 1.0) * 255.0))
			dst[index + 3] = int(round(clampf(result.a, 0.0, 1.0) * 255.0))
			index += 4
	out.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, dst)
	return out


## 双线性采样，坐标是像素单位；越界夹取到边缘。
static func sample(buf: PackedByteArray, size: Vector2i, px: float, py: float) -> Color:
	var w := size.x
	var h := size.y
	var x0 := clampi(int(floor(px)), 0, w - 1)
	var y0 := clampi(int(floor(py)), 0, h - 1)
	var x1 := clampi(x0 + 1, 0, w - 1)
	var y1 := clampi(y0 + 1, 0, h - 1)
	var fx := clampf(px - float(x0), 0.0, 1.0)
	var fy := clampf(py - float(y0), 0.0, 1.0)
	var i00 := (y0 * w + x0) * 4
	var i10 := (y0 * w + x1) * 4
	var i01 := (y1 * w + x0) * 4
	var i11 := (y1 * w + x1) * 4
	# 展开四个通道，避免在内层循环里做 match / PackedByteArray 动态下标分支。
	var top_r: float = lerpf(float(buf[i00]), float(buf[i10]), fx)
	var top_g: float = lerpf(float(buf[i00 + 1]), float(buf[i10 + 1]), fx)
	var top_b: float = lerpf(float(buf[i00 + 2]), float(buf[i10 + 2]), fx)
	var top_a: float = lerpf(float(buf[i00 + 3]), float(buf[i10 + 3]), fx)
	var bottom_r: float = lerpf(float(buf[i01]), float(buf[i11]), fx)
	var bottom_g: float = lerpf(float(buf[i01 + 1]), float(buf[i11 + 1]), fx)
	var bottom_b: float = lerpf(float(buf[i01 + 2]), float(buf[i11 + 2]), fx)
	var bottom_a: float = lerpf(float(buf[i01 + 3]), float(buf[i11 + 3]), fx)
	return Color(
		lerpf(top_r, bottom_r, fy) / 255.0,
		lerpf(top_g, bottom_g, fy) / 255.0,
		lerpf(top_b, bottom_b, fy) / 255.0,
		lerpf(top_a, bottom_a, fy) / 255.0)


## 采样重映射：fn(x, y, w, h) -> Vector2(源像素坐标)，用于波/漩涡/涟漪。
static func remap(source: Image, fn: Callable) -> Image:
	FxImageUtil._ensure_rgba(source)
	var size := Vector2i(source.get_width(), source.get_height())
	var out := canvas(size)
	var src := source.get_data()
	var dst := out.get_data()
	var w := float(size.x)
	var h := float(size.y)
	var index := 0
	for y in range(size.y):
		for x in range(size.x):
			var uv: Vector2 = fn.call(float(x), float(y), w, h)
			var c := sample(src, size, uv.x, uv.y)
			dst[index] = int(round(c.r * 255.0))
			dst[index + 1] = int(round(c.g * 255.0))
			dst[index + 2] = int(round(c.b * 255.0))
			dst[index + 3] = int(round(c.a * 255.0))
			index += 4
	out.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, dst)
	return out


static func hash2(x: int, y: int, seed: int) -> float:
	var n := x * 374761393 + y * 668265263 + seed * 1442695041
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / 2147483647.0


static func value_noise(x: float, y: float, seed: int) -> float:
	var xi := int(floor(x))
	var yi := int(floor(y))
	var tx := x - float(xi)
	var ty := y - float(yi)
	var sx := tx * tx * (3.0 - 2.0 * tx)
	var sy := ty * ty * (3.0 - 2.0 * ty)
	var a := lerpf(hash2(xi, yi, seed), hash2(xi + 1, yi, seed), sx)
	var b := lerpf(hash2(xi, yi + 1, seed), hash2(xi + 1, yi + 1, seed), sx)
	return lerpf(a, b, sy)


static func fbm(x: float, y: float, seed: int, octaves: int = 4) -> float:
	var total := 0.0
	var amplitude := 0.5
	var frequency := 1.0
	var norm := 0.0
	for i in range(maxi(1, octaves)):
		total += value_noise(x * frequency, y * frequency, seed + i * 17) * amplitude
		norm += amplitude
		amplitude *= 0.5
		frequency *= 2.0
	return total / maxf(norm, 0.0001)


static func hsv_to_rgb(h: float, s: float, v: float) -> Color:
	var c := Color.from_hsv(fposmod(h, 1.0), clampf(s, 0.0, 1.0), clampf(v, 0.0, 1.0))
	return c


static func rgb_to_hsv(c: Color) -> Vector3:
	var maxc := maxf(c.r, maxf(c.g, c.b))
	var minc := minf(c.r, minf(c.g, c.b))
	var d := maxc - minc
	var h := 0.0
	if d > 0.00001:
		if maxc == c.r:
			h = fposmod((c.g - c.b) / d, 6.0) / 6.0
		elif maxc == c.g:
			h = ((c.b - c.r) / d + 2.0) / 6.0
		else:
			h = ((c.r - c.g) / d + 4.0) / 6.0
	return Vector3(h, 0.0 if maxc <= 0.0 else d / maxc, maxc)


static func smoothstep(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / maxf(b - a, 0.00001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


# ================= 批量快速路径 =================
#
# 旧 API（generate / map / remap）每像素调一次 Callable.call()：192×108 的单张
# 图上光调用开销就 ~10ms（实测 4× 于循环体本身），一个 103 节点工程每帧有
# 几十万次这种调用。批量 API 把「循环」移进 Callable，整张图只调用一次，
# 常量（角度、方向、颜色、mode 分支）也随之外提到循环外。
#
# 旧 API 全部保留，第三方插件继续可用；内建热点算子迁移到批量版本。

const _BYTE_CLAMP := 255.0


## fn(w: int, h: int) -> PackedByteArray，长度必须为 w*h*4（RGBA8）。
static func generate_batch(size: Vector2i, fn: Callable) -> Image:
	var buf: PackedByteArray = fn.call(size.x, size.y)
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, buf)


## fn(src: PackedByteArray, w: int, h: int) -> PackedByteArray。
static func map_batch(source: Image, fn: Callable) -> Image:
	FxImageUtil._ensure_rgba(source)
	var w := source.get_width()
	var h := source.get_height()
	var dst: PackedByteArray = fn.call(source.get_data(), w, h)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, dst)


## fn(w: int, h: int) -> PackedFloat32Array，每像素两个 float：源像素坐标 (u, v)。
## 采样在套件内部内联完成（旧 remap 每像素还要再调一次 sample()）。
static func remap_batch(source: Image, fn: Callable) -> Image:
	FxImageUtil._ensure_rgba(source)
	var w := source.get_width()
	var h := source.get_height()
	var src := source.get_data()
	var coords: PackedFloat32Array = fn.call(w, h)
	var dst := PackedByteArray()
	dst.resize(w * h * 4)
	var last_x := w - 1
	var last_y := h - 1
	var index := 0
	var ci := 0
	for _y in range(h):
		for _x in range(w):
			var px := coords[ci]
			var py := coords[ci + 1]
			ci += 2
			var x0 := clampi(int(floor(px)), 0, last_x)
			var y0 := clampi(int(floor(py)), 0, last_y)
			var x1 := mini(x0 + 1, last_x)
			var y1 := mini(y0 + 1, last_y)
			var fx := clampf(px - float(x0), 0.0, 1.0)
			var fy := clampf(py - float(y0), 0.0, 1.0)
			var i00 := (y0 * w + x0) * 4
			var i10 := (y0 * w + x1) * 4
			var i01 := (y1 * w + x0) * 4
			var i11 := (y1 * w + x1) * 4
			dst[index] = int(round(lerpf(lerpf(float(src[i00]), float(src[i10]), fx),
				lerpf(float(src[i01]), float(src[i11]), fx), fy)))
			dst[index + 1] = int(round(lerpf(lerpf(float(src[i00 + 1]), float(src[i10 + 1]), fx),
				lerpf(float(src[i01 + 1]), float(src[i11 + 1]), fx), fy)))
			dst[index + 2] = int(round(lerpf(lerpf(float(src[i00 + 2]), float(src[i10 + 2]), fx),
				lerpf(float(src[i01 + 2]), float(src[i11 + 2]), fx), fy)))
			dst[index + 3] = int(round(lerpf(lerpf(float(src[i00 + 3]), float(src[i10 + 3]), fx),
				lerpf(float(src[i01 + 3]), float(src[i11 + 3]), fx), fy)))
			index += 4
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, dst)


## 批量循环里写一个 Color。等价于 round(clampf(channel,0,1)*255)，
## 但少一次函数调用；对 0..1 全 256 级逐字节验证过一致。
static func pack(buf: PackedByteArray, index: int, c: Color) -> void:
	buf[index] = int(clampf(c.r * 255.0 + 0.5, 0.0, _BYTE_CLAMP))
	buf[index + 1] = int(clampf(c.g * 255.0 + 0.5, 0.0, _BYTE_CLAMP))
	buf[index + 2] = int(clampf(c.b * 255.0 + 0.5, 0.0, _BYTE_CLAMP))
	buf[index + 3] = int(clampf(c.a * 255.0 + 0.5, 0.0, _BYTE_CLAMP))
