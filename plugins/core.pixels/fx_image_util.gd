class_name FxImageUtil
extends RefCounted
## 图像算子的公共积木：建画布、混合、缩放适配。
##
## 放在这里的原因：output.final、image.mix、image.accumulate 都要“把一张图叠到另一张上”，
## 如果各写一份，混合模式迟早不一致。这里只有纯函数，不认识节点、画布或时间。

const MODES := ["normal", "add", "multiply", "screen", "overlay", "subtract"]


static func new_canvas(size: Vector2i, fill: Color = Color(0, 0, 0, 0)) -> Image:
	var image := Image.create_empty(maxi(1, size.x), maxi(1, size.y), false, Image.FORMAT_RGBA8)
	image.fill(fill)
	return image


static func luma(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b


static func safe_scale(value: float) -> float:
	if absf(value) < 0.0001:
		return 0.0001 if value >= 0.0 else -0.0001
	return value


## 单像素混合。非 normal 模式先算混合色，再按 source-over 的 alpha 规则合成，
## 这样半透明图层的观感与常规合成软件一致。
static func blend_pixel(dst: Color, src: Color, mode: String, opacity: float) -> Color:
	var sa := clampf(src.a * opacity, 0.0, 1.0)
	if sa <= 0.0001:
		return dst
	var da := clampf(dst.a, 0.0, 1.0)
	var oa := sa + da * (1.0 - sa)
	if oa <= 0.0001:
		return Color(0, 0, 0, 0)
	var br := src.r
	var bg := src.g
	var bb := src.b
	match mode:
		"add":
			br = minf(dst.r + src.r, 1.0)
			bg = minf(dst.g + src.g, 1.0)
			bb = minf(dst.b + src.b, 1.0)
		"multiply":
			br = dst.r * src.r
			bg = dst.g * src.g
			bb = dst.b * src.b
		"screen":
			br = 1.0 - (1.0 - dst.r) * (1.0 - src.r)
			bg = 1.0 - (1.0 - dst.g) * (1.0 - src.g)
			bb = 1.0 - (1.0 - dst.b) * (1.0 - src.b)
		"overlay":
			br = 2.0 * dst.r * src.r if dst.r < 0.5 else 1.0 - 2.0 * (1.0 - dst.r) * (1.0 - src.r)
			bg = 2.0 * dst.g * src.g if dst.g < 0.5 else 1.0 - 2.0 * (1.0 - dst.g) * (1.0 - src.g)
			bb = 2.0 * dst.b * src.b if dst.b < 0.5 else 1.0 - 2.0 * (1.0 - dst.b) * (1.0 - src.b)
		"subtract":
			br = maxf(dst.r - src.r, 0.0)
			bg = maxf(dst.g - src.g, 0.0)
			bb = maxf(dst.b - src.b, 0.0)
	var k := sa / oa
	var kb := da * (1.0 - sa) / oa
	return Color(
		clampf(br * k + dst.r * kb, 0.0, 1.0),
		clampf(bg * k + dst.g * kb, 0.0, 1.0),
		clampf(bb * k + dst.b * kb, 0.0, 1.0),
		clampf(oa, 0.0, 1.0)
	)


## 把 src 按 offset 叠到 dst 上。超出画布的部分裁掉，不扩边。
##
## 性能：normal + 不透明直接走引擎的 Image.blend_rect（C++）；
## 其余模式在 PackedByteArray 上做整数通道运算，避免每像素 Color 分配 + String match。
static func blend_image(dst: Image, src: Image, offset: Vector2, mode: String, opacity: float) -> void:
	if dst == null or src == null or opacity <= 0.0001:
		return
	var ox := int(round(offset.x))
	var oy := int(round(offset.y))
	var dw := dst.get_width()
	var dh := dst.get_height()
	var sw := src.get_width()
	var sh := src.get_height()
	var x0 := maxi(0, ox)
	var y0 := maxi(0, oy)
	var x1 := mini(dw, ox + sw)
	var y1 := mini(dh, oy + sh)
	if x1 <= x0 or y1 <= y0:
		return
	_ensure_rgba(dst)
	var source := src
	if src.is_compressed() or src.get_format() != Image.FORMAT_RGBA8:
		source = src.duplicate()
		_ensure_rgba(source)
	var rect := Rect2i(x0 - ox, y0 - oy, x1 - x0, y1 - y0)
	var mode_id := MODES.find(mode)
	if mode_id <= 0 and opacity >= 0.999:
		dst.blend_rect(source, rect, Vector2i(x0, y0))
		return
	_blend_bytes(dst, source, rect, Vector2i(x0, y0), mode_id, opacity)


## 在字节层做 source-over 合成。mode_id 与 MODES 下标一致（0 = normal）。
##
## 这是整个渲染管线最核心的原语：`output.final` 的每层、`image.blend2`、
## 阴影、遮罩、文字合成都走它。所以它按行并行 —— 一处改动，所有合成类算子受益。
## 每块返回「自己那几行的整图宽字节」（先 slice 出来再改），拼接后一次 set_data：
## 直接让多线程写同一个 PackedByteArray 的不同区间会触发 COW 复制，反而是错的。
static func _blend_bytes(dst: Image, src: Image, rect: Rect2i, at: Vector2i,
		mode_id: int, opacity: float) -> void:
	# 原生快速路径：这是整个管线最核心的原语（每层合成、blend2、阴影、遮罩、
	# 文字全走它）。C++ 里一次算完，比 GDScript 分块并行还快一个档。
	# 扩展缺席时返回 false，继续走下面这条（不变）。
	if FxNativeBridge.blend(dst, src, rect, at, mode_id, opacity):
		return
	var sw := src.get_width()
	var dw := dst.get_width()
	var dh := dst.get_height()
	var sd := src.get_data()
	var dd := dst.get_data()
	var stride_s := sw * 4
	var stride_d := dw * 4
	var normal_only := mode_id <= 0
	var blended := FxPixelParallel.map_rows(dh, dw, func(y0: int, y1: int) -> PackedByteArray:
		return _blend_rows(dd, sd, rect, at, y0, y1, dw, dh, stride_s, stride_d,
			mode_id, opacity, normal_only))
	dst.set_data(dw, dh, false, Image.FORMAT_RGBA8, blended)


## 合成 [y0, y1) 这几行，返回该行段的**整图宽**字节（未落在 rect 内的像素原样拷贝）。
static func _blend_rows(dd: PackedByteArray, sd: PackedByteArray, rect: Rect2i,
		at: Vector2i, y0: int, y1: int, dw: int, _dh: int, stride_s: int, stride_d: int,
		mode_id: int, opacity: float, normal_only: bool) -> PackedByteArray:
	var part := dd.slice(y0 * stride_d, y1 * stride_d)
	# 只遍历与 rect 相交的那几行；其余行只是原样拷贝。
	var row_begin := maxi(y0, at.y)
	var row_end := mini(y1, at.y + rect.size.y)
	for y in range(row_begin, row_end):
		var local_y := y - at.y
		var si := (rect.position.y + local_y) * stride_s + rect.position.x * 4
		var di := (y - y0) * stride_d + at.x * 4
		for _x in range(rect.size.x):
			var sa := float(sd[si + 3]) / 255.0 * opacity
			if sa <= 0.002:
				si += 4
				di += 4
				continue
			var da := float(dd[di + 3]) / 255.0
			var oa := sa + da * (1.0 - sa)
			if oa <= 0.0001:
				part[di] = 0
				part[di + 1] = 0
				part[di + 2] = 0
				part[di + 3] = 0
				si += 4
				di += 4
				continue
			var sr := float(sd[si]) / 255.0
			var sg := float(sd[si + 1]) / 255.0
			var sb := float(sd[si + 2]) / 255.0
			var dr := float(dd[di]) / 255.0
			var dg := float(dd[di + 1]) / 255.0
			var db := float(dd[di + 2]) / 255.0
			var br := sr
			var bg := sg
			var bb := sb
			if not normal_only:
				match mode_id:
					1:
						br = minf(dr + sr, 1.0)
						bg = minf(dg + sg, 1.0)
						bb = minf(db + sb, 1.0)
					2:
						br = dr * sr
						bg = dg * sg
						bb = db * sb
					3:
						br = 1.0 - (1.0 - dr) * (1.0 - sr)
						bg = 1.0 - (1.0 - dg) * (1.0 - sg)
						bb = 1.0 - (1.0 - db) * (1.0 - sb)
					4:
						br = 2.0 * dr * sr if dr < 0.5 else 1.0 - 2.0 * (1.0 - dr) * (1.0 - sr)
						bg = 2.0 * dg * sg if dg < 0.5 else 1.0 - 2.0 * (1.0 - dg) * (1.0 - sg)
						bb = 2.0 * db * sb if db < 0.5 else 1.0 - 2.0 * (1.0 - db) * (1.0 - sb)
					5:
						br = maxf(dr - sr, 0.0)
						bg = maxf(dg - sg, 0.0)
						bb = maxf(db - sb, 0.0)
			var k := sa / oa
			var kb := da * (1.0 - sa) / oa
			part[di] = int(round(clampf(br * k + dr * kb, 0.0, 1.0) * 255.0))
			part[di + 1] = int(round(clampf(bg * k + dg * kb, 0.0, 1.0) * 255.0))
			part[di + 2] = int(round(clampf(bb * k + db * kb, 0.0, 1.0) * 255.0))
			part[di + 3] = int(round(clampf(oa, 0.0, 1.0) * 255.0))
			si += 4
			di += 4
	return part


## 算子拿到任意格式（灰度/压缩）的图时，先转成可逐字节处理的 RGBA8。
static func _ensure_rgba(image: Image) -> void:
	if image == null:
		return
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)


## 按 contain / cover / stretch / none 把图片适配进目标尺寸。
static func fit_image(src: Image, target_size: Vector2i, mode: String) -> Image:
	var target := Vector2i(maxi(1, target_size.x), maxi(1, target_size.y))
	if src == null:
		return new_canvas(target)
	var sw := float(maxi(1, src.get_width()))
	var sh := float(maxi(1, src.get_height()))
	if mode == "stretch":
		var stretched: Image = src.duplicate()
		stretched.resize(target.x, target.y, Image.INTERPOLATE_NEAREST)
		return stretched
	if mode == "none":
		var canvas_none := new_canvas(target)
		var copy_w := mini(src.get_width(), target.x)
		var copy_h := mini(src.get_height(), target.y)
		var crop_x := maxi(0, (src.get_width() - target.x) / 2)
		var crop_y := maxi(0, (src.get_height() - target.y) / 2)
		canvas_none.blit_rect(src, Rect2i(crop_x, crop_y, copy_w, copy_h),
			Vector2i(maxi(0, (target.x - src.get_width()) / 2), maxi(0, (target.y - src.get_height()) / 2)))
		return canvas_none
	var scale := minf(float(target.x) / sw, float(target.y) / sh) if mode != "cover" \
		else maxf(float(target.x) / sw, float(target.y) / sh)
	var tw := maxi(1, int(round(sw * scale)))
	var th := maxi(1, int(round(sh * scale)))
	var scaled: Image = src.duplicate()
	scaled.resize(tw, th, Image.INTERPOLATE_NEAREST)
	var canvas := new_canvas(target)
	if mode == "cover":
		var sx := maxi(0, (tw - target.x) / 2)
		var sy := maxi(0, (th - target.y) / 2)
		canvas.blit_rect(scaled, Rect2i(sx, sy, target.x, target.y), Vector2i.ZERO)
	else:
		canvas.blit_rect(scaled, Rect2i(0, 0, tw, th),
			Vector2i((target.x - tw) / 2, (target.y - th) / 2))
	return canvas


static func is_mode(value: String) -> bool:
	return MODES.has(value)
