extends SceneTree
## 微基准：`FxPixelParallel.map_rows` 到底有没有真的并行。
##
## 为什么单独测：整帧数字噪声太大（±10%），而且中间夹着引擎 resize / 图像分配，
## 看不出「切片」这一步本身值不值。这里只留一段纯算术循环，串行 vs 并行各跑几轮。
##
## 运行：godot --headless --path . --script res://tests/_bench_parallel.gd

const W := 192
const H := 108
const RUNS := 7


func _initialize() -> void:
	print("== map_rows 微基准 ==（%dx%d = %d 像素，%d 核）" % [
		W, H, W * H, OS.get_processor_count()])
	var src := PackedByteArray()
	src.resize(W * H * 4)
	for i in range(src.size()):
		src[i] = (i * 37) & 255

	# 先跑一轮丢弃（JIT 预热 / 缓存效应）
	_serial(src)
	_parallel(src)

	var serial := 0.0
	var parallel := 0.0
	for i in range(RUNS):
		serial += _serial(src)
		parallel += _parallel(src)
	serial /= float(RUNS)
	parallel /= float(RUNS)
	print("  串行        %7.2f ms" % serial)
	print("  并行        %7.2f ms" % parallel)
	if parallel > 0.01:
		print("  加速比      %.2fx" % (serial / parallel))
	# 并行结果必须与串行逐字节一致，否则「快了」毫无意义。
	var a := _body(src, 0, H)
	var b := FxPixelParallel.map_rows(H, W,
		func(y0: int, y1: int) -> PackedByteArray: return _body(src, y0, y1))
	print("  长度       串行 %d / 并行 %d（应为 %d）" % [a.size(), b.size(), W * H * 4])
	print("  结果一致    %s" % ("是" if a == b else "否 ← 有 bug"))
	if a.size() == b.size() and a != b:
		var first := -1
		for i in range(a.size()):
			if a[i] != b[i]:
				first = i
				break
		print("  首个差异字节 %d（行 %d，列 %d）" % [first, first / (W * 4), (first % (W * 4)) / 4])

	FxPluginHost.shutdown()
	quit(0)


func _body(src: PackedByteArray, y0: int, y1: int) -> PackedByteArray:
	var part := PackedByteArray()
	part.resize((y1 - y0) * W * 4)
	var di := 0
	for y in range(y0, y1):
		var row := y * W * 4
		for x in range(W):
			var i := row + x * 4
			# 故意做点「像算子」的工作：三次乘加 + 一次 clamp
			var r := float(src[i]) * 0.9 + 12.0
			var g := float(src[i + 1]) * 0.7 + 30.0
			var b := float(src[i + 2]) * 1.1 - 5.0
			part[di] = clampi(int(r), 0, 255)
			part[di + 1] = clampi(int(g), 0, 255)
			part[di + 2] = clampi(int(b), 0, 255)
			part[di + 3] = src[i + 3]
			di += 4
	return part


func _serial(src: PackedByteArray) -> float:
	var t := Time.get_ticks_usec()
	var _out := _body(src, 0, H)
	return float(Time.get_ticks_usec() - t) / 1000.0


func _parallel(src: PackedByteArray) -> float:
	var t := Time.get_ticks_usec()
	var _out := FxPixelParallel.map_rows(H, W,
		func(y0: int, y1: int) -> PackedByteArray: return _body(src, y0, y1))
	return float(Time.get_ticks_usec() - t) / 1000.0
