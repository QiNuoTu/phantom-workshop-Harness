extends SceneTree
## bloom 为什么还是 20ms？把它的五段拆开量。
##
## 逐段累加：每加一段测一次，差值就是这一段的价格。
## 这样能看出「是循环慢」还是「引擎 resize / 内存拷贝慢」，两者的解法完全不同。
##
## 运行：godot --headless --path . --script res://tests/_bench_bloom.gd

const W := 192
const H := 108
const RUNS := 10


func _initialize() -> void:
	FxPluginHost.ensure()
	var source: Image = FxPixelKit.canvas(Vector2i(W, H))
	source.fill(Color(0.5, 0.4, 0.3, 0.9))
	var size := Vector2i(W, H)

	for i in range(3):
		_stage(source, size)   # 预热

	var t := 0.0
	var prev := 0.0

	t = _avg(func() -> void:
		var _d := source.duplicate()
		var _b := source.get_data())
	print("  A duplicate+get_data        %7.3f ms" % t)
	prev = t

	t = _avg(func() -> void:
		var bright := source.duplicate()
		var bb: PackedByteArray = bright.get_data()
		var buf := source.get_data()
		for i2 in range(0, bb.size(), 4):
			var l := float(buf[i2] + buf[i2 + 1] + buf[i2 + 2]) / 765.0
			var keep := clampf((l - 0.6) / 0.25, 0.0, 1.0)
			for c in range(3):
				bb[i2 + c] = int(round(float(buf[i2 + c]) * keep))
			bb[i2 + 3] = int(round(float(buf[i2 + 3]) * keep))
		bright.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, bb))
	print("  B + 阈值化（串行）          %7.3f ms  （本段 %+.3f）" % [t, t - prev])
	prev = t

	t = _avg(func() -> void:
		var bright := source.duplicate()
		var buf := source.get_data()
		var bb := FxPixelParallel.map_rows(size.y, size.x, func(y0: int, y1: int) -> PackedByteArray:
			var part := PackedByteArray()
			part.resize((y1 - y0) * size.x * 4)
			var di := 0
			for i2 in range(y0 * size.x * 4, y1 * size.x * 4, 4):
				var l := float(buf[i2] + buf[i2 + 1] + buf[i2 + 2]) / 765.0
				var keep := clampf((l - 0.6) / 0.25, 0.0, 1.0)
				for c in range(3):
					part[di + c] = int(round(float(buf[i2 + c]) * keep))
				part[di + 3] = int(round(float(buf[i2 + 3]) * keep))
				di += 4
			return part)
		bright.set_data(size.x, size.y, false, Image.FORMAT_RGBA8, bb))
	print("  C + 阈值化（并行）          %7.3f ms  （比串行 %+.1f%%）" % [
		t, (t - prev) / maxf(prev, 0.0001) * 100.0])
	prev = t

	t = _avg(func() -> void:
		var bright := source.duplicate()
		var small := Vector2i(maxi(1, size.x / 8), maxi(1, size.y / 8))
		var reduced := bright.duplicate()
		reduced.resize(small.x, small.y, Image.INTERPOLATE_BILINEAR)
		reduced.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		var _rb: PackedByteArray = reduced.get_data())
	print("  D + 两次 resize（8 倍缩→放） %7.3f ms  （本段 %+.3f）" % [t, t - prev])
	prev = t

	t = _avg(func() -> void:
		var _img := FxPixelKit.canvas(size))
	print("  E canvas 分配               %7.3f ms" % t)

	FxPluginHost.shutdown()
	quit(0)


func _stage(source: Image, size: Vector2i) -> void:
	var _a := source.duplicate()
	var _b := source.get_data()
	var _c := FxPixelKit.canvas(size)


func _avg(fn: Callable) -> float:
	var total := 0.0
	for i in range(RUNS):
		var t := Time.get_ticks_usec()
		fn.call()
		total += float(Time.get_ticks_usec() - t) / 1000.0
	return total / float(RUNS)
