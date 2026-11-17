extends SceneTree
## 临时探针：播放实测（发布次数 / 命中 / 垫图 / 草稿 / 缓冲），用于定位「播放卡顿」。
##
## 必须带显示跑：播放的耗时大头在主线程发布与贴图。
##   godot --path . --script res://tests/_probe_play2.gd
##   FX_BENCH_MODE=nodraft 时关掉动态质量做 A/B。

var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _close_welcome() -> void:
	# 启动页会盖住工作台，也让「首帧时序」和真实使用完全不同：测试里一律关掉。
	var actions: Object = shell.service("document")
	if actions != null and actions.has_method("set_show_welcome"):
		actions.call("set_show_welcome", false)
	for child in shell.get_children():
		var script: Script = child.get_script() as Script
		if script != null and String(script.resource_path).contains("welcome"):
			child.queue_free()
		elif child is Window:
			(child as Window).queue_free()


func _run() -> void:
	for i in range(12):
		await process_frame
	store = shell.store
	render = shell.service("render")
	_close_welcome()
	var mode := OS.get_environment("FX_BENCH_MODE")
	if mode == "nodraft" or mode == "cold-nodraft":
		FxSettings.set_value("render.draft", false)
	print("模式=%s 草稿=%s" % [mode if not mode.is_empty() else "默认",
		str(render.preview_pipeline_config().get("draft"))])
	shell.service("document").call("open_path", "res://examples/demo/示范工程.fxproj")
	for i in range(600):
		await process_frame
		if (store.doc.get("nodes", []) as Array).size() > 50:
			break

	var hits := {"publish": 0, "cached": 0, "approx": 0, "draft": 0, "exact": 0}
	var probe := func(image: Image, stats: Dictionary) -> void:
		hits["publish"] = int(hits["publish"]) + 1
		if bool(stats.get("draft", false)):
			hits["draft"] = int(hits["draft"]) + 1
		elif bool(stats.get("exact_frame", false)):
			hits["exact"] = int(hits["exact"]) + 1
		if bool(stats.get("cached", false)):
			hits["cached"] = int(hits["cached"]) + 1
		if bool(stats.get("approx", false)):
			hits["approx"] = int(hits["approx"]) + 1
	render.rendered.connect(probe)

	var cold := mode == "cold" or mode == "cold-nodraft"
	if not cold:
		for i in range(3000):
			await process_frame
			var st: Dictionary = render.cache.stats()
			if int(st.get("total", 0)) > 0 and int(st.get("missing", 99)) == 0:
				break
	print("缓存预热：%d/%d" % [int(render.cache.stats().get("ready", 0)),
		render.cache.frame_count()])
	if mode.begins_with("big"):
		var size := Vector2i(960, 540)
		store.set_canvas(size.x, size.y)
		for i in range(90):
			await process_frame
		print("大画布：尺寸=%s 就绪=%d/%d" % [str(FxGraphDoc.canvas(store.doc)),
			int(render.cache.stats().get("ready", 0)), render.cache.frame_count()])
	if mode == "canvas":
		var canvas0 := FxGraphDoc.canvas(store.doc)
		store.set_canvas(canvas0.x + 40, canvas0.y + 20)
		for i in range(30):
			await process_frame
		print("改画布后：%d/%d 尺寸=%s" % [int(render.cache.stats().get("ready", 0)),
			render.cache.frame_count(), str(FxGraphDoc.canvas(store.doc))])

	var frames_seen := {}
	var t0 := Time.get_ticks_msec()
	var last := -1
	var jumps := 0
	render.set_playing(true)
	var trace := OS.get_environment("FX_TRACE_PLAY") != ""
	for i in range(1200):
		await process_frame
		if trace and i < 120:
			var st: Dictionary = render.cache.stats()
			print("  f%02d 主线程 f=%d 播放头=%d 帧态=%d stall=%.2f 就绪=%d 草稿忙=%s 预渲染=%s" % [
				i, int(render.frame_index()), int(render._play_frame),
				int(render.cache_state(int(render._play_frame))), float(render._stall),
				int(st.get("ready", 0)), str(render.draft != null and render.draft.busy()),
				str(render.prefetch_progress())])
		var f := int(render.frame_index())
		if last >= 0 and f != last and f != last + 1:
			jumps += 1
		last = f
		if not frames_seen.has(f):
			frames_seen[f] = i
		if Time.get_ticks_msec() - t0 > 2000:
			break
	var elapsed := Time.get_ticks_msec() - t0
	render.set_playing(false)
	var per := float(elapsed) / maxf(float(frames_seen.size()), 1.0)
	print("播放 %d ms：%d 帧（每帧 %.1f ms，30fps 目标 33.3）· 跳帧 %d 次" % [
		elapsed, frames_seen.size(), per, jumps])
	print("发布 %d 次（命中 %d / 垫图 %d / 草稿 %d / 精确 %d）" % [int(hits["publish"]),
		int(hits["cached"]), int(hits["approx"]), int(hits["draft"]), int(hits["exact"])])
	print("计数器：命中 %d · 近似 %d · 缺帧 %d" % [render.cache_hits, render.cache_approx,
		render.cache_misses])
	print("结束")
	FxPluginHost.shutdown()
	quit(0)
