class_name FxDraftWorker
extends RefCounted
## 草稿帧线程：用**缩小画布 + 低算子质量**先算出一张「看得见变化」的图。
##
## 为什么要有它：精确帧一次要几十到上千毫秒，这段时间屏幕上什么都没有，
## 用户改完参数看到的是「没反应」。草稿把首现时间从「一帧精确」压到「一帧框架」，
## 随后由精确帧原地替换 —— 画质是阶梯上升的，而不是「要么没有、要么完美」。
##
## 硬边界（这些是它存在的合法性，不是优化）：
##   · **只服务显示**：不写帧缓存、不归档、不参与「这一帧好了没」的判定；
##   · 只算输出链，**不跑汇点**（`skip_sinks`）：草稿绝不允许触发导出写文件；
##   · 结果自带内容身份与帧号，主线程只接受「仍然是当前文档当前帧」的那一张；
##   · 与精确帧互不等待：各自一条线程，谁先好谁上屏，画质高的后到就覆盖。
##
## 线程模型与 FxRenderWorker 一致：只吃深拷贝快照，同一时刻最多一帧在算。
## 与精确帧不同的是**不持 FxRenderGate**：那把锁被精确帧整帧握着，
## 排队就等于把自己变成「精确帧算完之后的第一件事」，毫无意义。

var _thread: Thread = null
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _running: bool = false
var _busy: bool = false
var _job: Dictionary = {}
var _result: Dictionary = {}
var _has_result: bool = false
## 执行器只属于这条线程：跨帧静态缓存要保住，所以不每帧新建。
var _runner: FxGraphRunner = null


func start() -> bool:
	if _thread != null:
		return true
	_running = true
	_thread = Thread.new()
	var err := _thread.start(Callable(self, "_loop"))
	if err != OK:
		push_warning("FxDraftWorker：草稿线程启动失败（%s），动态质量关闭" %
			error_string(err))
		_thread = null
		_running = false
		return false
	return true


func stop() -> void:
	_mutex.lock()
	_running = false
	_job = {}
	_mutex.unlock()
	_sem.post()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_mutex.lock()
	_has_result = false
	_busy = false
	_result = {}
	_mutex.unlock()
	_runner = null


func running() -> bool:
	return _thread != null


func busy() -> bool:
	_mutex.lock()
	var value := _busy
	_mutex.unlock()
	return value


## 提交一帧草稿。调用方负责 busy() 检查；忙时覆盖队列（掉帧而不是排队）。
func submit(job: Dictionary) -> void:
	_mutex.lock()
	if _thread == null or not _running:
		_mutex.unlock()
		return
	_job = job
	_busy = true
	_mutex.unlock()
	_sem.post()


## 主线程取结果：没有新结果返回空字典（不阻塞）。
func take_result() -> Dictionary:
	_mutex.lock()
	if not _has_result:
		_mutex.unlock()
		return {}
	var result := _result
	_result = {}
	_has_result = false
	_mutex.unlock()
	return result


# ================= 工作线程 =================

func _loop() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		var alive := _running
		var job: Dictionary = _job
		_job = {}
		_mutex.unlock()
		if not alive:
			return
		if job.is_empty():
			continue
		var result := _run(job)
		_mutex.lock()
		_result = result
		_has_result = true
		_busy = false
		_mutex.unlock()


func _run(job: Dictionary) -> Dictionary:
	if _runner == null:
		_runner = FxGraphRunner.new()
	var runner := _runner
	var scale := clampf(float(job.get("canvas_scale", 0.125)), 0.0625, 1.0)
	# 草稿的画布就是靠 `base_scale` 缩的：所有节点都按它算，输出自然是小图。
	# 不去改文档 meta —— 那会让「草稿」看起来像「改了画布」。
	runner.base_scale = scale
	runner.quality = 0
	runner.operator_quality = clampf(float(job.get("operator_quality", 0.35)), 0.0, 1.0)
	runner.options = job.get("options", {}) as Dictionary
	# 草稿不要缩略图、不要汇点副作用：它唯一的产品是「一张能看的图」。
	runner.capture_previews = false
	runner.preview_nodes = {}
	runner.skip_sinks = true
	# 草稿不出缩略图：旁支预览根一个都不跑（它们只在 `preview_roots` 里被额外求值，
	# 剪枝的「活节点」判定已经由 compile_plan 带上，不受影响）。
	runner.preview_roots = []
	runner.compile_plan = job.get("compile_plan", {}) as Dictionary
	var muted: Dictionary = job.get("muted", {})
	var solo: Dictionary = job.get("solo", {})
	runner.track_enabled = func(node_id: String, path: String) -> bool:
		var key := FxDocumentStore.track_key(node_id, path)
		if not solo.is_empty():
			return solo.has(key)
		return not muted.has(key)
	if bool(job.get("invalidate", false)):
		runner.invalidate_cache()
	var doc: Dictionary = job.get("doc", {})
	var t := float(job.get("t", 0.0))
	# **不拿 FxRenderGate**：那把锁是「一帧求值 ↔ 插件表结构变更」的互斥量，
	# 精确帧那条线程会把整帧（几百毫秒）都握在手里。草稿要是也去排队，
	# 它永远只能等精确帧算完才开始 —— 那正是它想抢回来的那段时间。
	# 预渲染的 6 条线程本来就不拿这把锁（见 fx_frame_prefetcher 的设计约束），
	# 草稿是同一类风险等级：插件热重载时最多算错一帧草稿，而草稿随时可以被丢弃。
	var result: Variant = {}
	if FxRenderBroker.has_backend():
		result = FxRenderBroker.frame(doc, t, job.get("policy", {}) as Dictionary,
			runner, {"playing": false, "exact": false,
				"signature": int(job.get("signature", -1))})
	runner.base_scale = 1.0
	var image: Image = null
	var stats: Dictionary = {}
	if result is Dictionary:
		var payload: Dictionary = result
		image = payload.get("image") as Image
		var got: Variant = payload.get("stats")
		stats = got if got is Dictionary else {}
	return {
		"image": image,
		"frame_index": int(job.get("frame_index", -1)),
		"epoch": int(job.get("epoch", -1)),
		"doc_key": int(job.get("doc_key", -1)),
		"canvas_scale": scale,
		"stats": stats,
	}
