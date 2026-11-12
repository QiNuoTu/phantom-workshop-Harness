class_name FxPixelKitBlobs
extends RefCounted
## 稀疏光点绘制：不去遍历「每个像素 × 每个粒子」，而是只遍历每个粒子的包围盒。
## 星场 / 火花 / 光斑这类算子的复杂度从 O(W·H·N) 降到 O(N·r²)。

static func paint(size: Vector2i, background: Color,
		blobs: Array[Dictionary]) -> Image:
	var image := FxPixelKit.canvas(size, background)
	var buf := image.get_data()
	for raw in blobs:
		var blob: Dictionary = raw
		var cx: float = float(blob.get("x", 0.0))
		var cy: float = float(blob.get("y", 0.0))
		var radius: float = maxf(0.5, float(blob.get("radius", 1.0)))
		var tint: Color = blob.get("color", Color.WHITE)
		var strength: float = clampf(float(blob.get("strength", 1.0)), 0.0, 1.0)
		var core: float = clampf(float(blob.get("core", 0.35)), 0.01, 1.0)
		var x0 := clampi(int(floor(cx - radius)), 0, size.x - 1)
		var x1 := clampi(int(ceil(cx + radius)), 0, size.x - 1)
		var y0 := clampi(int(floor(cy - radius)), 0, size.y - 1)
		var y1 := clampi(int(ceil(cy + radius)), 0, size.y - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var dx: float = float(x) - cx
				var dy: float = float(y) - cy
				var dist: float = sqrt(dx * dx + dy * dy)
				if dist > radius:
					continue
				var fall: float = 1.0 - FxPixelKit.smoothstep(core * radius, radius, dist)
				var add: float = fall * strength
				if add <= 0.002:
					continue
				var index: int = (y * size.x + x) * 4
				var da: float = float(buf[index + 3]) / 255.0
				var oa: float = minf(1.0, da + add * tint.a)
				for c in range(3):
					var src_c: float = float(buf[index + c]) / 255.0
					buf[index + c] = int(round(clampf(
						(src_c * da + tint[c] * add * tint.a) / maxf(oa, 0.001), 0.0, 1.0) * 255.0))
				buf[index + 3] = int(round(oa * 255.0))
	image.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, buf)
	return image
