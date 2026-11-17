class_name FxFramePrefetcher
extends RefCounted
## 并行后台逐帧预渲染：把整段动画按精确质量算出来，顺手写进 FxFrameCache。
##
## 为什么是**多条**线程：
##   真实工程（示范工程.fxproj，103 节点）单帧要 600ms，60 帧用一条线程要 36 秒，
##   用户按播放时缓存根本追不上。这些帧彼此完全独立，天然适合并行；
##   12 核机器上开 6 条把整段压到几秒，播放头优先的队列让「接下来要播的帧」先出。
##
## 设计约束：
##   · 每条线程持有**自己的** FxGraphRunner 与静态缓存，不共享可变执行状态；
##   · 待算帧队列在互斥量里派发，FxFrameCache.put() 自身线程安全；
##   · 只吃深拷贝快照，逐帧检查注册表版本与取消标记，插件热重载立刻收手；
##   · 与界面求帧互不等待：不使用 FxRenderGate，界面线程可以随时插队出图。
##
## GPU 后端下同样启用：预渲染算的是 CPU 原始帧（与导出一致），
## GPU compute 增强由主线程的 postprocess 发布通道负责。

const MAX_WORKERS := 6

var _cache: FxFrameCache = null
var _threads: Array[Thread] = []
var _sems: Array[Semaphore] = []
var _runners: Array[FxGraphRunner] = []
var _mutex := Mutex.new()
var _running: bool = false
var _cancel: bool = false
var _job: Dictionary = {}
var _pending: Array[int] = []
var _cursor: int = 0
var _active: bool = false
var _done: int = 0
var _total: int = 0
var _note: String = ""
var _worker_count: int = 0
## 每条线程**此刻**在算哪一帧（slot → 帧号）。只给时间轴标尺着色用。
## 它是调度事实，不是缓存状态：算完不一定成功（取消、桶换了都会丢），
## 所以只用来回答「这一格现在有没有人在干」。
var _inflight: Dictionary = {}
## 这一趟是不是「只补缩略图」趟。它是真实计算，但不产出可缓存的帧，
## 所以不该让标尺上的格子变橘 —— 那会让用户以为「这一段正在补帧」。
var _preview_only: bool = false


func bind(p_cache: FxFrameCache) -> void:
	_cache = p_cache


func start(workers: int = 0) -> bool:
	if not _threads.is_empty():
		return true
	var n := clampi(workers if workers > 0 else int(OS.get_processor_count()) - 1,
		2, MAX_WORKERS)
	_running = true
	for slot in range(n):
		var sem := Semaphore.new()
		var runner := FxGraphRunner.new()
		var thread := Thread.new()
		var err := thread.start(Callable(self, "_loop").bind(slot))
		if err != OK:
			push_warning("FxFramePrefetcher：第 %d 条预渲染线程启动失败（%s）" %
				[slot, error_string(err)])
			continue
		_sems.append(sem)
		_runners.append(runner)
		_threads.append(thread)
	if _threads.is_empty():
		_running = false
		return false
	_worker_count = _threads.size()
	return true


func stop() -> void:
	if _threads.is_empty():
		return
	_mutex.lock()
	_running = false
	_cancel = true
	_inflight.clear()
	_mutex.unlock()
	for sem in _sems:
		sem.post()
	for thread in _threads:
		thread.wait_to_finish()
	_threads.clear()
	_sems.clear()
	_runners.clear()
	_worker_count = 0


func running() -> bool:
	return not _threads.is_empty()


func worker_count() -> int:
	return _worker_count


## 开始（或重新开始）一次预渲染。job 需要：
## doc / fps / count / policy / revision / from / priority / signature / label
##
## `draft_scale > 0` 时这一趟是**草稿趟**：所有帧按缩小画布算，结果写进
## 帧缓存的「垫图层」（exact = false，标尺上是黄格）。它比精确趟快一个数量级，
## 几十毫秒就能把整段填满 —— 播放从此不会「一格都没有」，改画布也不会
## 眼看着标尺一路全红等几分钟。
func enqueue(job: Dictionary) -> void:
	var count := int(job.get("count", 0))
	if count <= 0:
		return
	var from := clampi(int(job.get("from", 0)), 0, count - 1)
	var priority := int(job.get("priority", -1))
	var order: Array[int] = []
	# 播放头优先：先把接下来要播的帧算出来，再回头补齐前面的。
	if priority >= 0 and priority < count:
		for i in range(priority, count):
			order.append(i)
		for i in range(from, mini(priority, count)):
			order.append(i)
	else:
		for i in range(from, count):
			order.append(i)
	_mutex.lock()
	if not _running or _threads.is_empty():
		_mutex.unlock()
		return
	_job = job
	_pending = order
	_cursor = 0
	_done = 0
	_total = order.size()
	_cancel = false
	_active = true
	_preview_only = bool(job.get("preview_only", false))
	_inflight.clear()
	_note = String(job.get("label", ""))
	var sems := _sems.duplicate()
	_mutex.unlock()
	# 盘目录在主线程一侧先建好，避免多条线程同时 make_dir_recursive_absolute。
	if _cache != null:
		_cache.ensure_dir()
	for sem in sems:
		sem.post()


func cancel() -> void:
	_mutex.lock()
	_cancel = true
	_active = false
	_inflight.clear()
	_mutex.unlock()


func active() -> bool:
	_mutex.lock()
	var value := _active
	_mutex.unlock()
	return value


## 主线程轮询用：{active, done, total, cursor, note, workers}。
func progress() -> Dictionary:
	_mutex.lock()
	var out := {
		"active": _active, "done": _done, "total": _total,
		"cursor": _cursor, "note": _note, "workers": _worker_count,
	}
	_mutex.unlock()
	return out


## 此刻各线程正在算的帧号（去重）。已经就绪的帧不算 —— 那是「算完了」。
func inflight() -> Array:
	_mutex.lock()
	var out: Array = []
	if _preview_only:
		_mutex.unlock()
		return out
	for slot in _inflight.keys():
		var index := int(_inflight[slot])
		if index >= 0 and not out.has(index):
			out.append(index)
	_mutex.unlock()
	return out


# ================= 工作线程 =================

func _loop(slot: int) -> void:
	while true:
		_mutex.lock()
		var alive := _running
		_mutex.unlock()
		if not alive:
			return
		# 一直从共享队列取帧，取空了才睡；避免「一帧一个唤醒」的抖动。
		while true:
			_mutex.lock()
			if _cancel or _cursor >= _pending.size():
				_mutex.unlock()
				break
			var index: int = _pending[_cursor]
			_cursor += 1
			var job: Dictionary = _job
			# 登记「这一格有人在干」：标尺的橘色就是这条登记表。
			# 必须在解锁前写，否则主线程可能读到「已派发但没人认领」的中间态。
			_inflight[slot] = index
			_mutex.unlock()
			_compute(job, index, slot)
			_mutex.lock()
			_inflight.erase(slot)
			_done += 1
			if _done >= _total:
				_active = false
			_mutex.unlock()
		if slot < _sems.size():
			_sems[slot].wait()


func _compute(job: Dictionary, index: int, slot: int) -> void:
	if _cancelled() or _cache == null or slot >= _runners.size():
		return
	var doc: Dictionary = job.get("doc", {})
	if doc.is_empty():
		return
	var revision := int(job.get("revision", -1))
	if revision >= 0 and FxRegistry.revision != revision:
		return
	# 桶换了（文档/帧率/时长变化）就停手：不能把上一份文档的帧写进新桶。
	var expected_fp := String(job.get("fingerprint", ""))
	if not expected_fp.is_empty() and _cache.fingerprint() != expected_fp:
		return
	var runner := _runners[slot]
	# 草稿趟：缩小画布 + 低算子质量 + 不跑汇点。它唯一的产物是「一张能看的图」。
	var draft_scale := clampf(float(job.get("draft_scale", 0.0)), 0.0, 1.0)
	var draft := draft_scale > 0.0 and draft_scale < 0.999
	# 「缩略图趟」用低质量算：小图看不出差别，但整段能快好几倍。
	runner.quality = clampi(int(job.get("quality", 1)), 0, 1)
	# 算子质量可以由任务显式指定（节点小图那条管线有独立档位）。
	# 没指定时才按 quality 推导 —— 精确帧预渲染走的仍是这条老路，行为不变。
	var want_operator := float(job.get("operator_quality", -1.0))
	if want_operator < 0.0:
		want_operator = 1.0 if runner.quality >= 1 else 0.5
	runner.operator_quality = clampf(want_operator, 0.0, 1.0)
	# 草稿趟在这三件事上必须和精确趟分开：画布倍率、汇点副作用、缩略图。
	runner.base_scale = draft_scale if draft else 1.0
	if draft:
		runner.quality = 0
		runner.operator_quality = clampf(float(job.get("operator_quality", 0.35)), 0.0, 1.0)
		runner.skip_sinks = true
	else:
		runner.skip_sinks = false
	runner.options = job.get("policy", {}) as Dictionary
	# 只给**展开的节点**留缩略图：收起的节点连求值预览都省掉。
	# preview_nodes 为空表时完全关闭捕获（整段预渲染的常态）。
	var preview_nodes: Dictionary = job.get("preview_nodes", {})
	var track: Variant = job.get("preview_track")
	var want_previews: bool = not preview_nodes.is_empty() and track is Object
	# 已经精确缓存的帧不必再算一遍：打开工程后补几帧、或播放追上来的场景，
	# 旧实现会把整段 60 帧全部重算（约 9 秒纯浪费）。缩略图趟与「小图也还没备」的
	# 帧仍然照算。
	if not bool(job.get("preview_only", false)) and _cache.has_frame(index):
		if not want_previews or bool((track as Object).call("has_frame", index)):
			return
	# 草稿趟只补「一张图都没有」的帧：已经有垫图的不必再画一遍。
	if draft and _cache.state(index) != FxFrameCache.STATE_EMPTY:
		return
	runner.capture_previews = want_previews
	runner.preview_nodes = preview_nodes if want_previews else {}
	# 后台预渲染是第三条求值路径：预览根与剪枝计划必须和同步/工作线程一致，
	# 否则「预渲染算出来的帧」和「当场算出来的帧」会在旁支上分叉。
	var roots_raw: Variant = job.get("preview_roots", [])
	var roots: Array[String] = []
	if roots_raw is Array:
		for item in (roots_raw as Array):
			roots.append(String(item))
	runner.preview_roots = roots
	runner.compile_plan = job.get("compile_plan", {}) as Dictionary
	if want_previews:
		runner.preview_limit = maxi(int(job.get("preview_limit", 64)), 16)
	var fps := maxi(int(job.get("fps", 30)), 1)
	var t := float(index) / float(fps)
	var result: Variant = FxRenderBroker.frame(doc, t, runner.options, runner,
		{"playing": false, "exact": true,
			"signature": int(job.get("signature", -1))})
	if _cancelled():
		return
	if result is Dictionary:
		var payload: Dictionary = result
		if want_previews:
			var got: Variant = payload.get("previews")
			if got is Dictionary:
				(track as Object).call("put", index, got)
		if bool(job.get("preview_only", false)):
			# 缩略图趟只补小图，绝不把低质量结果写回精确帧缓存。
			return
		var image: Variant = payload.get("image")
		if image is Image:
			# 身份随帧一起写：预渲染跑在后台，作业开始时的那份文档就是这一帧的出处。
			if draft:
				# 垫图必须是画布尺寸（帧缓存的定长布局没得商量）：在这里放大，
				# 别丢给主线程 —— 主线程每帧只该贴图，不该做 2 MB 的双线性缩放。
				var up := image as Image
				var want := _cache.frame_size()
				if want.x > 0 and up.get_size() != want:
					up = up.duplicate()
					up.resize(want.x, want.y, Image.INTERPOLATE_BILINEAR)
				_cache.put(index, up, false, true, int(job.get("signature", -1)), draft_scale)
			else:
				_cache.put(index, image as Image, true, true,
					int(job.get("signature", -1)))


func _cancelled() -> bool:
	_mutex.lock()
	var value := _cancel
	_mutex.unlock()
	return value
