extends SceneTree
## 真实工程播放验证（唯一基准：examples/demo/示范工程.fxproj，103 节点 / 60 帧）。
##
## 必须带显示跑（GPU/UI 帧时间只有真实渲染循环里才有意义）：
##   godot --path . --script res://tests/_probe_playback.gd
##
## 检查四件事：
##   1. 打开工程后多久启动后台预渲染（要求 < 1 秒，不能等空闲 0.9 秒以上）；
##   2. 整段 60 帧并行算完要多久；
##   3. 播放时帧号是否连续（不能跳号）、缓存命中率、UI 帧时间是否被求值阻塞；
##   4. 切到 GPU 后端后是否仍然不跳帧、UI 不卡。

const PROJECT := "res://examples/demo/示范工程.fxproj"

var shell: FxShell = null
var render: FxRenderService = null
var frames: Array[int] = []
var ui_times: Array[float] = []
var _last_usec: int = 0
var _collecting: bool = false


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	root.add_child(packed.instantiate())
	for i in range(20):
		await process_frame
	for child in root.get_children():
		if child is FxShell:
			shell = child as FxShell
			break
	if shell == null:
		print("PLAY_FAIL 外壳未实例化")
		quit(1)
		return
	render = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	if render == null or actions == null:
		print("PLAY_FAIL 服务未就绪")
		quit(1)
		return

	# 冷启动：清掉上一次留下的磁盘缓存，测的就是「刚打开工程」的完整流程。
	render.clear_cache()
	var t0 := Time.get_ticks_usec()
	await actions.call("open_path_async", PROJECT)
	for i in range(60):
		await process_frame
		if (shell.store.doc.get("nodes", []) as Array).size() >= 100:
			break
	var loaded_at := Time.get_ticks_usec()
	var nodes := (shell.store.doc.get("nodes", []) as Array).size()
	var total := render.frame_count()
	print("PLAY_DOC nodes=%d frames=%d canvas=%s load=%.0fms" % [
		nodes, total, FxGraphDoc.canvas(shell.store.doc),
		float(Time.get_ticks_usec() - t0) / 1000.0])
	if nodes < 100:
		print("PLAY_FAIL 工程没装载成功")
		quit(1)
		return

	# 1) 预渲染启动延迟
	var start_ms := -1.0
	for i in range(120):
		await process_frame
		if render.prefetching():
			start_ms = float(Time.get_ticks_usec() - loaded_at) / 1000.0
			break
	var workers := int((render.prefetch_progress() as Dictionary).get("workers", 0))
	print("PLAY_PREFETCH start_after_load=%.0fms workers=%d" % [start_ms, workers])

	# 2) 整段算完的耗时
	var done_ms := -1.0
	for i in range(3600):
		await process_frame
		var stats := render.cache_stats()
		if int(stats.get("ready", 0)) >= int(stats.get("total", 1)):
			done_ms = float(Time.get_ticks_usec() - loaded_at) / 1000.0
			break
	print("PLAY_PREFETCH done_after_load=%.0fms ready=%d/%d" % [
		done_ms, int(render.cache_stats().get("ready", 0)),
		int(render.cache_stats().get("total", 0))])

	# 基线：完全不播放时界面自身的帧时间（真实 GUI 环境下不一定有 60fps）。
	var base := await _measure_idle(90)
	print("PLAY_IDLE ui_avg=%.1fms ui_max=%.1fms ticks=%d" % [base[0], base[1], base[2]])

	# 隔离实验 A：只推进时间（不播放、不发渲染信号）
	var probe_img: Image = render.cache.fetch(0)
	var a_times: Array[float] = []
	var a_last := Time.get_ticks_usec()
	for i in range(60):
		shell.store.set_time(fmod(float(i) / 30.0, 2.0))
		await process_frame
		var now := Time.get_ticks_usec()
		a_times.append(float(now - a_last) / 1000.0)
		a_last = now
	print("PLAY_SETTIME ui_avg=%.1fms" % (a_times.reduce(func(x, y): return x + y, 0.0) / 60.0))

	# 隔离实验 B：只发布一张缓存帧（时间不动）
	shell.store.set_time(0.0)
	var b_times: Array[float] = []
	var b_last := Time.get_ticks_usec()
	for i in range(60):
		render.call("_publish_cached", probe_img, i % 60)
		await process_frame
		var now := Time.get_ticks_usec()
		b_times.append(float(now - b_last) / 1000.0)
		b_last = now
	print("PLAY_PUBLISH ui_avg=%.1fms" % (b_times.reduce(func(x, y): return x + y, 0.0) / 60.0))

	# 3) CPU 后端播放
	render.rendered.connect(_on_rendered)
	await _play_segment("cpu.standard", 180)
	var cpu_result := _analyze("cpu", float(base[1]))

	# 4) GPU 后端播放（GPU 发布通道默认开锐化，会真实跑 compute）
	FxSettings.set_value("render.backend", "gpu.standard")
	FxRenderBroker.invalidate()
	render.request_render()
	for i in range(30):
		await process_frame
	frames.clear()
	ui_times.clear()
	await _play_segment("gpu.standard", 180)
	var gpu_result := _analyze("gpu", float(base[1]))

	FxSettings.reset("render.backend")
	FxRenderBroker.invalidate()
	print("PLAY_PASS=%s" % (cpu_result and gpu_result and start_ms >= 0.0
		and start_ms < 1000.0 and done_ms > 0.0 and nodes >= 100
		and int(render.cache_stats().get("ready", 0)) >= 60))
	FxPluginHost.shutdown()
	quit(0)


func _measure_idle(ticks: int) -> Array:
	var times: Array[float] = []
	var last := Time.get_ticks_usec()
	for i in range(ticks):
		await process_frame
		var now := Time.get_ticks_usec()
		times.append(float(now - last) / 1000.0)
		last = now
	var avg := 0.0
	var worst := 0.0
	for t in times:
		avg += t
		worst = maxf(worst, t)
	return [avg / maxf(float(times.size()), 1.0), worst, times.size()]


func _play_segment(_backend: String, ticks: int) -> void:
	render.set_playing(false)
	for i in range(4):
		await process_frame
	frames.clear()
	ui_times.clear()
	_collecting = true
	_last_usec = Time.get_ticks_usec()
	render.set_playing(true)
	for i in range(ticks):
		await process_frame
		var now := Time.get_ticks_usec()
		ui_times.append(float(now - _last_usec) / 1000.0)
		_last_usec = now
	render.set_playing(false)
	_collecting = false


func _on_rendered(_image: Image, stats: Dictionary) -> void:
	if not _collecting or not bool(stats.get("cached", false)):
		return
	frames.append(int(stats.get("frame", -1)))


func _analyze(label: String, idle_worst: float) -> bool:
	var count := maxi(render.frame_count(), 1)
	var jumps := 0
	for i in range(1, frames.size()):
		var delta := frames[i] - frames[i - 1]
		if delta != 1 and delta != -(count - 1):
			jumps += 1
	var avg := 0.0
	var worst := 0.0
	for t in ui_times:
		avg += t
		worst = maxf(worst, t)
	avg = avg / maxf(float(ui_times.size()), 1.0)
	print("PLAY_%s frames=%d jumps=%d hits=%d misses=%d ui_avg=%.1fms ui_max=%.1fms idle_max=%.1fms" % [
		label, frames.size(), jumps, render.cache_hits, render.cache_misses, avg, worst, idle_worst])
	# 帧号连续、至少播了 20 帧、且播放没有比「空闲基线」明显更卡。
	# 绝对阈值在不同机器/GPU 驱动下没有意义，用相对量才能验出「求值阻塞 UI」。
	return jumps == 0 and frames.size() >= 20 \
		and worst < maxf(80.0, idle_worst * 1.8 + 25.0)
