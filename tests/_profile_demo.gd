extends SceneTree
## 真实工程性能画像（唯一基准：examples/demo/示范工程.fxproj）。
## 无头跑，测 CPU 求值链；GUI 播放行为另用 _probe_playback.gd 验证。
const PROJECT := "res://examples/demo/示范工程.fxproj"

var doc: Dictionary = {}


func _initialize() -> void:
	FxPluginHost.ensure()
	var t0 := Time.get_ticks_usec()
	var loaded := FxProjectArchive.read_zip(PROJECT)
	var load_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if not bool(loaded.get("ok", false)):
		print("PROFILE_FAIL 无法加载：", loaded.get("message", ""))
		quit(1)
		return
	doc = loaded.get("doc", {}) as Dictionary
	var tl: Dictionary = FxGraphDoc.timeline(doc)
	print("PROFILE doc nodes=%d edges=%d canvas=%s fps=%d duration=%.2f frames=%d load=%.1fms" % [
		(doc.get("nodes", []) as Array).size(), (doc.get("edges", []) as Array).size(),
		FxGraphDoc.canvas(doc), int(tl.get("fps", 30)), float(tl.get("duration", 1.0)),
		int(tl.get("fps", 30)) * int(round(float(tl.get("duration", 1.0)))), load_ms,
	])

	# 指纹（每 0.25s 被 _cache_ensure_fingerprint 调一次）
	var fp_t := Time.get_ticks_usec()
	for i in range(10):
		var _unused := JSON.stringify(doc)
	print("PROFILE fingerprint JSON.stringify x10 = %.2fms" % [
		float(Time.get_ticks_usec() - fp_t) / 1000.0])

	_profile_fresh()
	_profile_stream()
	_profile_disk()
	FxPluginHost.shutdown()
	quit(0)


func _new_runner(previews: bool, static_cache: bool) -> FxGraphRunner:
	var r := FxGraphRunner.new()
	r.quality = 1
	r.operator_quality = 1.0
	r.options = FxQualityPolicy.resolve({
		"playing": false, "width": 192, "height": 108, "node_count": 103,
		"t": 0.0, "paused_quality": 1, "seed": 1,
	})
	r.capture_previews = previews
	r.static_cache_enabled = static_cache
	return r


## 冷启动：每次都新建执行器，测「单帧完整求值」与算子耗时分布。
func _profile_fresh() -> void:
	print("== 冷帧（新执行器 / 无静态缓存） ==")
	var times: Array[float] = []
	var last: Dictionary = {}
	for i in range(3):
		var r := _new_runner(true, false)
		var begin := Time.get_ticks_usec()
		last = r.run(doc, float(i) / 30.0)
		times.append(float(Time.get_ticks_usec() - begin) / 1000.0)
	print("PROFILE cold frames = %s ms" % str(times))
	var stats: Dictionary = last.get("stats", {})
	print("PROFILE cold stats steps=%s nodes=%s previews=%s cache_hits=%s ms=%s" % [
		stats.get("steps", "?"), stats.get("nodes", "?"), stats.get("previews", "?"),
		stats.get("cache_hits", "?"), stats.get("ms", "?"),
	])
	var timings: Dictionary = stats.get("timings", {})
	var rows: Array = []
	for node_id in timings.keys():
		var node_data := FxGraphDoc.node(doc, String(node_id))
		rows.append({"id": String(node_id), "type": String(node_data.get("type", "")),
			"ms": float(timings[node_id])})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["ms"] > b["ms"])
	var sum := 0.0
	for row in rows:
		sum += float(row["ms"])
	print("PROFILE op total = %.2fms across %d node evals" % [sum, rows.size()])
	for i in range(mini(18, rows.size())):
		var row: Dictionary = rows[i]
		print("PROFILE op %2d  %7.2fms  %-24s %s" % [i + 1, row["ms"], row["type"], row["id"]])
	# 按类型聚合，找最贵的算子族
	var by_type := {}
	for row in rows:
		var key := String(row["type"])
		by_type[key] = float(by_type.get(key, 0.0)) + float(row["ms"])
	var type_rows: Array = []
	for key in by_type.keys():
		type_rows.append({"type": key, "ms": by_type[key]})
	type_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["ms"] > b["ms"])
	for i in range(mini(10, type_rows.size())):
		print("PROFILE type %2d  %7.2fms  %s" % [i + 1, type_rows[i]["ms"], type_rows[i]["type"]])


## 播放流：复用同一个执行器（真实 worker 的行为），测稳态帧耗时。
func _profile_stream() -> void:
	print("== 播放流（复用执行器 / 静态缓存开） ==")
	var r := _new_runner(true, true)
	var times: Array[float] = []
	for i in range(12):
		var begin := Time.get_ticks_usec()
		var out := r.run(doc, float(i) / 30.0)
		times.append(float(Time.get_ticks_usec() - begin) / 1000.0)
		var stats: Dictionary = out.get("stats", {})
		if i in [0, 1, 11]:
			print("PROFILE stream[%d] ms=%.2f steps=%s cache_hits=%s previews=%s" % [
				i, times[i], stats.get("steps", "?"), stats.get("cache_hits", "?"),
				stats.get("previews", "?")])
	var sum := 0.0
	for t in times:
		sum += t
	print("PROFILE stream avg=%.2fms min=%.2f max=%.2f" % [sum / times.size(), times.min(), times.max()])
	# 关掉预览的对比
	var r2 := _new_runner(false, true)
	var t2 := 0.0
	for i in range(6):
		var begin := Time.get_ticks_usec()
		r2.run(doc, float(i) / 30.0)
		t2 += float(Time.get_ticks_usec() - begin) / 1000.0
	print("PROFILE stream no-preview avg=%.2fms" % [t2 / 6.0])


## 缓存写盘：PNG 编码在主线程的成本。
func _profile_disk() -> void:
	var r := _new_runner(false, true)
	var out := r.run(doc, 0.0)
	var image: Image = out.get("image") as Image
	if image == null:
		print("PROFILE disk 无输出图")
		return
	var dir := "user://graph_test/profile"
	DirAccess.make_dir_recursive_absolute(dir)
	var begin := Time.get_ticks_usec()
	for i in range(5):
		image.save_png(dir.path_join("f_%d.png" % i))
	print("PROFILE png save 192x108 x5 = %.2fms" % [float(Time.get_ticks_usec() - begin) / 1000.0])
