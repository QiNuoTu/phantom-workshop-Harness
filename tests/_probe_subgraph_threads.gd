extends SceneTree
## 并发子图求值回归：6 条线程同时求帧，不得出现「检测到循环依赖」。
## 旧实现把内层执行器与递归栈放在静态单例里，线程间互相覆盖 evaluating。
const PROJECT := "res://examples/demo/示范工程.fxproj"
var threads: Array[Thread] = []
var errors: Array[String] = []
var mutex := Mutex.new()
var doc: Dictionary = {}

func _initialize() -> void:
	FxPluginHost.ensure()
	var loaded := FxProjectArchive.read_zip(PROJECT)
	if not bool(loaded.get("ok", false)):
		print("SUBGRAPH_THREAD_FAIL 加载失败")
		quit(1); return
	doc = loaded.get("doc", {})
	for i in range(6):
		var t := Thread.new()
		threads.append(t)
		t.start(Callable(self, "_worker").bind(i))
	for i in range(900):
		await process_frame
		var alive := false
		for t in threads:
			if t.is_alive(): alive = true
		if not alive: break
	for t in threads:
		t.wait_to_finish()
	mutex.lock()
	var n := errors.size()
	mutex.unlock()
	print("SUBGRAPH_THREAD nodes=%d threads=6 bad=%d first=%s" % [
		(doc.get("nodes", []) as Array).size(), n, errors[0] if n > 0 else "-"])
	print("SUBGRAPH_THREAD_PASS=", n == 0)
	FxOpsSubgraph.clear_cache()
	FxPluginHost.shutdown()
	quit(0)

func _worker(id: int) -> void:
	var runner := FxGraphRunner.new()
	runner.quality = 0
	runner.capture_previews = false
	runner.static_cache_enabled = true
	runner.options = FxQualityPolicy.resolve({"playing": true, "width": 192, "height": 108,
		"node_count": 103, "t": 0.0, "paused_quality": 0, "seed": 1})
	for k in range(3):
		var result := runner.run(doc, float(k + id) / 30.0)
		for w in (result.get("warnings", []) as Array):
			var text := String(w)
			if text.contains("循环依赖"):
				mutex.lock(); errors.append(text); mutex.unlock()
