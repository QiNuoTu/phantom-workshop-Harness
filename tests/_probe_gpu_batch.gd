extends SceneTree
## 合流效果：6 条线程各提交 8 个 GPU 请求，看总耗时与批次数。
## 旧实现是「每请求一次跨线程往返」(约 16ms) → 每线程 8×16 ≈ 128ms。
var threads: Array[Thread] = []
var log: Array[String] = []
var mutex := Mutex.new()

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("GPUBATCH_SKIP 无头"); quit(0); return
	FxPluginHost.ensure()
	await process_frame
	var warm := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	warm.fill(Color(0.3, 0.6, 0.9, 1.0))
	FxGpuCompute.run(warm, null, 4, 0, 0, 1.0, Vector2i.ZERO,
		PackedInt32Array([2, 0, 100, 1000, 700, 330]))
	await process_frame
	var before_calls := FxGpuCompute.bridged_calls()
	var before_batches := FxGpuCompute.bridge_batches()
	var t0 := Time.get_ticks_usec()
	for i in range(6):
		var t := Thread.new()
		threads.append(t)
		t.start(Callable(self, "_worker").bind(i))
	while true:
		await process_frame
		var alive := false
		for t in threads:
			if t.is_alive(): alive = true
		if not alive: break
	for t in threads:
		t.wait_to_finish()
	var span := float(Time.get_ticks_usec() - t0) / 1000.0
	var calls := FxGpuCompute.bridged_calls() - before_calls
	var batches := FxGpuCompute.bridge_batches() - before_batches
	for line in log:
		print("GPUBATCH ", line)
	print("GPUBATCH total=%.0fms calls=%d batches=%d per_call=%.2fms merge=%.2fx fb=%d" % [
		span, calls, batches, span / maxf(float(calls), 1.0),
		float(calls) / maxf(float(batches), 1.0), FxGpuCompute.bridge_fallbacks()])
	print("GPUBATCH_PASS=%s" % (calls == 48 and batches <= calls / 2
		and FxGpuCompute.bridge_fallbacks() == 0))
	FxGpuCompute.reset()
	FxPluginHost.shutdown()
	quit(0)

func _worker(id: int) -> void:
	var src := Image.create(192, 108, false, Image.FORMAT_RGBA8)
	src.fill(Color(0.3, 0.6, 0.9, 1.0))
	var t0 := Time.get_ticks_usec()
	for i in range(8):
		FxGpuCompute.outline_bridged(src, 2, false, 0.1, Color(1, 0.7, 0.33))
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	mutex.lock()
	log.append("thread %d: 8 requests %.1fms (%.2fms each)" % [id, ms, ms / 8.0])
	mutex.unlock()
