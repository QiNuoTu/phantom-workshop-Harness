class_name FxPixelParallel
extends RefCounted
## 逐像素算子的行内并行：把 [0, rows) 切成几块，各线程只写自己那几行。
##
## 为什么是「按行切」：行是 PackedByteArray 里连续的区间，拼接只是一次
## `append_array`；按像素切则要逐点归位，光归位就比省下的算术更贵。
##
## 为什么**只在主线程**启用：预渲染本身就按帧并行（2–6 条线程），
## 在 worker 里再往同一个 WorkerThreadPool 提交子任务会把池占满 ——
## 那时几条线程互相等对方的子任务，就是死锁。主线程求值没有这个问题。
## 纯数据线程安全：lambda 只读输入、只写自己那段输出，不碰 Node / RenderingServer。
##
## 低于阈值不并行：线程调度 + 拼接的开销比省下的算术还多（实测 8k 像素以下反而更慢）。

## 少于这么多像素就串行跑。16384 = 128×128，基本覆盖所有节点小图。
const MIN_PIXELS := 16384
## 行数太少时切不出有意义的块（每块至少 8 行）。
const MIN_ROWS := 24
const MAX_THREADS := 8

## 总开关：`FX_NO_PARALLEL=1` 时全部回落串行。
## 留它是为了能做干净的 A/B —— 同一个二进制、同一份数据，只切一个变量。
## 排查「并行之后画面不对」时，第一步就该先关掉它确认是不是这里的问题。
static var enabled: bool = OS.get_environment("FX_NO_PARALLEL") != "1"

## 可观测：这一帧到底走了并行还是串行、切了几块。
## 性能问题最怕的就是「以为在并行」——没有计数器时，参数写错一个 0 就静默退回串行。
static var parallel_calls: int = 0
static var serial_calls: int = 0
static var last_threads: int = 0


static func should_parallel(rows: int, width: int) -> bool:
	if not enabled:
		return false
	if rows < MIN_ROWS or rows * width < MIN_PIXELS:
		return false
	if OS.get_processor_count() <= 1:
		return false
	return OS.get_thread_caller_id() == OS.get_main_thread_id()


## fn(y0, y1) -> PackedByteArray，只含 [y0, y1) 这几行的字节。
## 返回按行顺序拼好的整块；不并行时就是一次 fn(0, rows) 调用。
static func map_rows(rows: int, width: int, fn: Callable) -> PackedByteArray:
	if not should_parallel(rows, width):
		serial_calls += 1
		return fn.call(0, rows)
	# 线程数按像素量给，不按核数给：20736 像素切成 8 份，每份只剩 2600 像素，
	# 任务唤醒 + 跨核搬运的开销会吃掉大半收益（实测 8 线程与 2 线程持平，
	# 而噪声让相邻算子看起来「变慢了」）。每线程约 4k 像素起才有正收益（更少就开始亏在唤醒与拼接上）。
	var ideal := maxi(2, (rows * width) / 2048)
	var count := mini(mini(ideal, OS.get_processor_count()), MAX_THREADS)
	parallel_calls += 1
	last_threads = count
	var parts: Array = []
	parts.resize(count)
	for i in range(count):
		# 用整数分块，最后一块自动吃掉余数：不丢行、不越界。
		parts[i] = [rows * i / count, rows * (i + 1) / count, PackedByteArray()]
	var group := WorkerThreadPool.add_group_task(func(i: int) -> void:
		var slot: Array = parts[i]
		slot[2] = fn.call(int(slot[0]), int(slot[1]))
	, count, -1, false)
	WorkerThreadPool.wait_for_group_task_completion(group)
	var out := PackedByteArray()
	for slot in parts:
		out.append_array(slot[2])
	return out
