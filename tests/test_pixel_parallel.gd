extends SceneTree
## 行内并行（`FxPixelParallel`）：把「快」与「对」同时钉住。
##
## 这类改动的风险不在慢，而在**悄悄算错**：切片边界差一行、拼接顺序颠倒、
## 读写索引没分开，画面只会在某些尺寸上烂一点点，肉眼很难发现。所以这里
## 全部用**与串行逐字节比对**来断言，而不是「看起来差不多」。
##
## 运行：
##   godot --headless --path . --script res://tests/test_pixel_parallel.gd

var failures: Array[String] = []
var _count: int = 0


func _initialize() -> void:
	print("== 行内并行测试 ==")
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()

	_test_threshold()
	_test_same_as_serial()
	_test_odd_sizes()
	_test_compose_primitive()
	_test_call_counters()

	print("-- 行内并行：%d 条断言，%d 条失败" % [_count, failures.size()])
	for item in failures:
		print("FAIL: %s" % item)
	# 插件表是静态的：不清就退出，引擎会在 shutdown 阶段崩（而且只看退出码才知道）。
	FxPluginHost.shutdown()
	quit(0 if failures.is_empty() else 1)


## ---- 1. 阈值：小图不该并行（线程调度比算术贵）----
func _test_threshold() -> void:
	_check(not FxPixelParallel.should_parallel(16, 16),
		"小图（16×16）走串行：256 像素不值得起线程")
	_check(not FxPixelParallel.should_parallel(8, 400),
		"行数太少的宽图走串行（切不出有意义的块）")
	_check(FxPixelParallel.should_parallel(108, 192),
		"示范工程尺寸（192×108）走并行")
	_check(FxPixelParallel.MIN_PIXELS > 0 and FxPixelParallel.MAX_THREADS >= 2,
		"阈值与线程上限有明确取值，不是靠调用方传")


## ---- 2. 与串行结果逐字节一致 ----
func _test_same_as_serial() -> void:
	var src := _pattern(192, 108)
	var serial := FxPixelParallel.map_rows(108, 192, func(y0: int, y1: int) -> PackedByteArray:
		return _transform_range(src, 192, y0, y1))
	var parallel := FxPixelParallel.map_rows(108, 192, func(y0: int, y1: int) -> PackedByteArray:
		return _transform_range(src, 192, y0, y1))
	_check(serial.size() == 192 * 108 * 4, "拼接后长度正确（%d）" % serial.size())
	_check(serial == parallel, "同一输入两次并行结果一致（无数据竞争）")
	# 用「整图一次算」作为串行基准，验证切片本身没丢行/错位。
	var whole := _transform_range(src, 192, 0, 108)
	_check(whole == serial, "并行切片结果 == 整图一次算（逐字节）")


## ---- 3. 奇数尺寸：分块除不尽时最后一块要吃余数 ----
func _test_odd_sizes() -> void:
	for rows in [25, 37, 101]:
		var src := _pattern(64, rows)
		var parallel := FxPixelParallel.map_rows(rows, 64, func(y0: int, y1: int) -> PackedByteArray:
			return _transform_range(src, 64, y0, y1))
		var whole := _transform_range(src, 64, 0, rows)
		_check(parallel == whole, "%d 行（除不尽）时切片完整、无错位" % rows)


## ---- 4. 合成原语：并行后像素必须与「手工 source-over」一致 ----
func _test_compose_primitive() -> void:
	var dst := FxPixelKit.canvas(Vector2i(96, 64))
	dst.fill(Color(0.2, 0.3, 0.4, 1.0))
	var src := FxPixelKit.canvas(Vector2i(96, 64))
	src.fill(Color(0.9, 0.5, 0.1, 0.5))
	FxImageUtil.blend_image(dst, src, Vector2.ZERO, "normal", 1.0)
	# 0.5 不透明度、源色 (0.9,0.5,0.1) 叠在 (0.2,0.3,0.4) 上：
	# out = src*0.5 + dst*0.5（alpha 饱和后 k=0.5, kb=0.5）
	var pixel := dst.get_pixel(10, 10)
	_check(absf(pixel.r - 0.55) < 0.01 and absf(pixel.g - 0.4) < 0.01,
		"normal 混合值正确（实得 %.3f, %.3f）" % [pixel.r, pixel.g])
	_check(absf(pixel.a - 1.0) < 0.01, "不透明底图合成后 alpha 仍是 1")

	# 偏移 + 裁剪：只改 rect 内的像素，rect 外必须原样不动。
	var dst2 := FxPixelKit.canvas(Vector2i(96, 64))
	dst2.fill(Color(0, 0, 0, 0))
	var src2 := FxPixelKit.canvas(Vector2i(32, 32))
	src2.fill(Color(1, 1, 1, 1))
	FxImageUtil.blend_image(dst2, src2, Vector2(80, 48), "normal", 1.0)
	_check(dst2.get_pixel(79, 40).a < 0.01, "rect 外未受影响（左上）")
	_check(dst2.get_pixel(85, 55).a > 0.99, "rect 内被合成（右下）")
	_check(dst2.get_pixel(10, 10).a < 0.01, "远处像素仍是空")


## ---- 5. 计数器：证明「真的并行」而不是静默退回串行 ----
func _test_call_counters() -> void:
	FxPixelParallel.parallel_calls = 0
	FxPixelParallel.serial_calls = 0
	var src := _pattern(192, 108)
	var _big := FxPixelParallel.map_rows(108, 192, func(y0: int, y1: int) -> PackedByteArray:
		return _transform_range(src, 192, y0, y1))
	_check(FxPixelParallel.parallel_calls == 1, "大图计一次并行调用")
	var _small := FxPixelParallel.map_rows(8, 8, func(y0: int, y1: int) -> PackedByteArray:
		return PackedByteArray())
	_check(FxPixelParallel.serial_calls == 1, "小图计一次串行调用（不是静默走并行）")


# ================= 辅助 =================

func _pattern(w: int, h: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * h * 4)
	for y in range(h):
		for x in range(w):
			var i := (y * w + x) * 4
			out[i] = (x * 7) & 255
			out[i + 1] = (y * 11) & 255
			out[i + 2] = (x ^ y) & 255
			out[i + 3] = 255 if ((x + y) % 3) != 0 else 128
	return out


## 与算子同一形状的逐像素变换。`whole` 为 true 时按整图绝对索引写
## （用来给串行版做基准），否则按段内局部索引写。
## 段内局部索引写；y0=0 时局部索引恰好等于整图绝对索引，所以同一个函数
## 既能当「切片版」也能当「整图串行基准」—— 基准与被测共用一份代码，
## 比对才有意义（两份实现互相比对只能说明它们不同，不能说明谁对）。
func _transform_range(src: PackedByteArray, w: int, y0: int, y1: int) -> PackedByteArray:
	var out := PackedByteArray()
	var rows := y1 - y0
	out.resize(rows * w * 4)
	var di := 0
	for y in range(y0, y1):
		var si := y * w * 4
		for _x in range(w):
			var r := float(src[si]) * 0.9 + 10.0
			var g := float(src[si + 1]) * 0.8
			var b := float(src[si + 2]) * 1.1 - 3.0
			out[di] = clampi(int(r), 0, 255)
			out[di + 1] = clampi(int(g), 0, 255)
			out[di + 2] = clampi(int(b), 0, 255)
			out[di + 3] = src[si + 3]
			si += 4
			di += 4
	return out


func _check(condition: bool, label: String) -> void:
	_count += 1
	if condition:
		print("  ok  %s" % label)
	else:
		failures.append(label)
		print("  FAIL: %s" % label)
