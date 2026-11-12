class_name FxRenderWorker
extends RefCounted
## 后台求帧线程：把「求一帧」从主线程搬到工作线程，界面不再被渲染卡住。
##
## 设计约束（都是硬要求，不满足就别用线程）：
##   · 只接受**快照后的文档**：主线程在提交前 duplicate，之后不再碰它；
##   · 结果通过互斥量交回主线程，主线程负责发信号、建纹理、动 UI；
##   · 同一时刻只有一个在跑的帧（最新请求覆盖旧请求 = 掉帧而不是排队）；
##   · 求值本身持 FxRenderGate 的锁，插件热重载不会与它撞车。
##
## 质量没有被牺牲：跑的就是完整求值（全分辨率输出链、逐节点预览），
## 只是换了个线程做同样的工作量。

var _thread: Thread = null
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _running: bool = false
var _busy: bool = false
var _job: Dictionary = {}
var _result: Dictionary = {}
var _has_result: bool = false
## 执行器只属于工作线程：跨帧静态缓存要保住，所以不每帧新建。
var _runner: FxGraphRunner = null


func start() -> bool:
	if _thread != null:
		return true
	_running = true
	_thread = Thread.new()
	var err := _thread.start(Callable(self, "_loop"))
	if err != OK:
		push_warning("FxRenderWorker：后台渲染线程启动失败（%s），回落到主线程" %
			error_string(err))
		_thread = null
		_running = false
		return false
	return true


## 立即停止并等线程退出（撤销/导出/退出前调用）。互斥量与信号量都允许重复调用。
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


## 提交一帧。job 需要：doc / t / signature / quality / operator_quality /
## options / preview_limit / capture_previews / static_cache / preview_nodes /
## muted / solo。调用前请确认 busy() 为 false。
func submit(job: Dictionary) -> void:
	_mutex.lock()
	if _thread == null or not _running:
		_mutex.unlock()
		return
	_job = job
	_busy = true
	_mutex.unlock()
	_sem.post()


## 主线程取结果：没有新结果返回空字典（不会阻塞）。
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
	runner.quality = int(job.get("quality", 1))
	runner.operator_quality = float(job.get("operator_quality", 1.0))
	runner.options = job.get("options", {}) as Dictionary
	runner.preview_limit = int(job.get("preview_limit", 128))
	runner.capture_previews = bool(job.get("capture_previews", true))
	runner.static_cache_enabled = bool(job.get("static_cache", true))
	var scope: Variant = job.get("preview_nodes", {})
	runner.preview_nodes = scope if scope is Dictionary else {}
	# solo/mute 状态快照成纯数据谓词：工作线程不回调主线程的对象。
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
	var gate := FxRenderGate.mutex()
	gate.lock()
	var result: Variant = {}
	if FxRenderBroker.has_backend():
		result = FxRenderBroker.frame(doc, t, job.get("policy", {}) as Dictionary,
			runner, {"playing": false, "exact": false,
				"signature": int(job.get("signature", -1))})
	gate.unlock()
	if result is Dictionary:
		var out: Dictionary = result
		# 播放补帧的急件算的是「第 N 帧」，不能按结果回来时的播放头位置归档。
		out["frame_index"] = int(job.get("frame_index", -1))
		# 世代 / 用途随结果回来：主线程据此判断这一帧还算不算「当前」。
		out["epoch"] = int(job.get("epoch", -1))
		out["doc_key"] = int(job.get("doc_key", -1))
		out["purpose"] = String(job.get("purpose", "live"))
		out["exact"] = bool(job.get("exact", false))
		# 这一帧到底是按哪一档质量算的，必须随结果回来。
		# 主线程归档时若拿「此刻」的 runner.quality 判断，播放档算出的急件
		# 会在暂停后按精确帧入账 —— 标尺上还没算的那一段就提前变绿了。
		out["frame_quality"] = int(job.get("quality", 1))
		out["frame_operator_quality"] = float(job.get("operator_quality", 1.0))
		return out
	return {"image": null, "previews": {}, "node_params": {}, "stats": {}, "warnings": []}
