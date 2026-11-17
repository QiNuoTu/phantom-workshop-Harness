extends SceneTree
## 缓存重建归因测试：把「什么操作允许重建、什么操作不允许」钉成断言。
##
## 背景：之前只有「重建了很多次」这个数字，没有人知道是谁在重建，于是每次优化都靠猜。
## 这套测试断言的是**归因链本身**：事件记不记、档位分得对不对、被挡下的路径是不是真被挡下。
##
## 运行：
##   godot --headless --path . --script res://tests/test_cache_trace.gd

var failures: Array[String] = []
var shell: FxShell
var store: FxDocumentStore
var render: FxRenderHost
## 具体实现用于「桶」层面的断言（指纹 / 统计）；契约那一部分只用 FxRenderHost 调。
var service: FxRenderService


func _initialize() -> void:
	print("== 帧缓存归因测试（重建来源 / 失效档位）==")
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		push_error("主场景加载失败")
		_quit(1)
		return
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for i in range(8):
		await process_frame
	store = shell.store
	service = shell.service("render") as FxRenderService
	render = service
	_check(store != null and render != null, "外壳与呈现器都已就位")
	if store == null or render == null:
		_quit(1)
		return
	for i in range(90):
		if render.last_image() != null:
			break
		await process_frame

	# ---- 1. 契约：呈现器实现归因日志，且清空有效 ----
	_check(render.has_method("cache_trace"), "呈现器实现 cache_trace 契约")
	shell.run_command("diag.cache", ["reset"])
	_check((render.cache_trace() as Array).is_empty(), "reset 之后日志为空（可重复观测）")

	# ---- 2. 设置影响面：声明值决定一次改动的代价 ----
	var locale_impact := FxSettings.impact_of("general.locale")
	var workers_impact := FxSettings.impact_of("render.prefetch_workers")
	var operator_impact := FxSettings.impact_of("quality.operator")
	var backend_impact := FxSettings.impact_of("render.backend")
	var sharpen_impact := FxSettings.impact_of("render.gpu_sharpen")
	_check(locale_impact == "none", "换界面语言不碰渲染（impact=none，实得 %s）" % locale_impact)
	_check(workers_impact == "none", "预渲染线程数只影响调度（impact=none，实得 %s）" % workers_impact)
	_check(operator_impact == "derived", "算子质量只换算法不换内容（impact=derived）")
	_check(backend_impact == "content", "切渲染后端要重建帧（impact=content）")
	_check(sharpen_impact == "display", "GPU 锐化只影响贴屏（impact=display）")

	# ---- 3. 拖动节点：只改布局，必须静默 ----
	var node_id := ""
	for item in store.doc.get("nodes", []):
		var data: Dictionary = item
		node_id = String(data.get("id", ""))
		if not node_id.is_empty():
			break
	_check(not node_id.is_empty(), "测试文档里有节点")
	shell.run_command("diag.cache", ["reset"])
	var fp_before: String = service.cache.fingerprint()
	store.begin_batch()
	store.set_node_position(node_id, Vector2(321, 123))
	store.commit_batch(["positions"])
	await _wait(6)
	var fp_after: String = service.cache.fingerprint()
	_check(fp_before == fp_after, "拖动节点不换桶（指纹不变）")
	_check(_buckets().is_empty(), "拖动节点不产生重建事件")
	var gates := _gates()
	_check(int(gates.get("layout_only", 0)) >= 1, "变更通知被「纯布局」闸门挡下并留下记录")

	# 归因断言的前提是**桶已经建好了**。装载工程后的稳定期（CONTENT_SETTLE = 0.35s）
	# 里改参数是故意不立刻换桶的（那时的指纹还不是最终的），所以「第一次建桶」
	# 完全可能由归档/巡检触发 —— 那不是归因错，是测试没等到桶。
	# 这条等待把时间依赖从断言里拿掉：之前它靠「刚好多跑了 30ms」才通过。
	for i in range(240):
		if service.cache.frame_count() > 0:
			break
		await process_frame
	_check(service.cache.frame_count() > 0,
		"桶已建好（%d 帧）" % service.cache.frame_count())

	# ---- 4. 改参数：必须换桶，且只换一次 ----
	shell.run_command("diag.cache", ["reset"])
	var radius := 0.0
	var raw_radius: Variant = store.param_value("blur", "radius")
	if raw_radius is float or raw_radius is int:
		radius = float(raw_radius)
	store.apply_param("blur", "radius", radius + 3.0, false)
	await _wait(10)
	var buckets := _buckets()
	_check(buckets.size() == 1, "改一次参数只重建一次桶（实得 %d）" % buckets.size())
	if buckets.size() == 1:
		var event: Dictionary = buckets[0]
		_check(String(event.get("reason", "")) == "param", "重建来源记为「改参数」")
		var before: Dictionary = event.get("parts_before", {})
		var after: Dictionary = event.get("parts_after", {})
		_check(before.get("nodes") != after.get("nodes"), "分段哈希指出变的是图（nodes）")
		_check(int(event.get("cleared", 0)) > 0, "换桶会清空帧状态（这就是绿格消失的来源）")

	# ---- 4b. 重建事件必须能指认到「谁变了」，不能只说「图变了」----
	shell.run_command("diag.cache", ["reset"])
	store.apply_param("blur", "radius", radius + 7.0, false)
	await _wait(10)
	var one := _buckets()
	if one.size() == 1:
		var ev: Dictionary = one[0]
		var detail_before: Dictionary = ev.get("detail_before", {})
		var detail_after: Dictionary = ev.get("detail_after", {})
		_check(not detail_after.is_empty(), "重建事件带逐节点明细")
		_check((detail_after.get("nodes", {}) as Dictionary).has("blur"),
			"明细里能查到被改的节点")
		_check((detail_before.get("nodes", {}) as Dictionary).get("blur")
				!= (detail_after.get("nodes", {}) as Dictionary).get("blur"),
			"明细指出 blur 的内容哈希变了")
		_check(not bool(ev.get("silent", false)), "走正常写入的变更不算静默写入")
		var detail_text := FxCacheReport.render(FxCacheReport.report({"render": render}))
		_check(detail_text.contains("变了："), "报告里列出具体是哪个节点变了")

	# ---- 5. 不回写同值：不该有任何动静 ----
	shell.run_command("diag.cache", ["reset"])
	var settled_radius: Variant = store.param_value("blur", "radius")
	store.apply_param("blur", "radius", settled_radius, false)
	await _wait(6)
	_check(_buckets().is_empty(), "把同一个值再写一遍不重建（写前==写后静默）")

	# ---- 6. 只影响调度的设置：不得失效 ----
	shell.run_command("diag.cache", ["reset"])
	var workers := 2 if int(FxSettings.value("render.prefetch_workers")) != 2 else 3
	FxSettings.set_value("render.prefetch_workers", workers)
	await _wait(6)
	_check(_invalidates().is_empty(), "调预渲染线程数不产生失效请求")
	_check(_buckets().is_empty(), "调预渲染线程数不重建桶")

	# ---- 7. 影响算法的设置：只丢派生缓存，不动桶 ----
	shell.run_command("diag.cache", ["reset"])
	var operator := 0.8 if absf(float(FxSettings.value("quality.operator")) - 0.8) > 0.001 else 0.6
	FxSettings.set_value("quality.operator", operator)
	await _wait(6)
	var invalidates := _invalidates()
	_check(invalidates.size() == 1, "改算子质量产生 1 次失效请求（实得 %d）" % invalidates.size())
	if invalidates.size() == 1:
		var event: Dictionary = invalidates[0]
		_check(String(event.get("tier", "")) == "derived",
			"档位是 derived（保留已算好的精确帧）")
		_check(String(event.get("source", "")) == "quality.operator", "记录了失效来源")
	_check(_buckets().is_empty(), "derived 档不重建桶")

	# ---- 8. 命令本身可用：报告能出、能归因 ----
	var data := FxCacheReport.report({"render": render})
	_check(bool(data.get("available", false)), "diag.cache 能读到呈现器的日志")
	_check(not (data.get("impacts", {}) as Dictionary).is_empty(), "报告里带设置影响面表")
	var text := FxCacheReport.render(data)
	_check(text.contains("== 帧缓存归因 =="), "报告有标题")
	_check(text.contains("失效请求"), "报告统计失效请求")

	# ---- 9. 视图态不得进内容指纹 ----
	# 拖动节点早已不换桶，但「挪分组框」「折叠卡片」同样是纯布局：
	# 它们混进内容指纹时，用户每挪一下框，整段缓存就白算一次。
	var probe := {
		"nodes": [{"id": "a", "type": "x", "pos": [1, 2], "size": [10, 20],
			"collapsed": true, "params": {"v": 1}}],
		"edges": [{"from": "a", "from_port": "out", "to": "a", "to_port": "in",
			"pos": [[0, 0]]}],
		"frames": [{"id": "f", "title": "区域", "rect": [0, 0, 100, 80], "nodes": ["a"]}],
		"meta": {"timeline": {"fps": 30, "duration": 1.0}},
	}
	var content := FxFrameCache.content_of(probe)
	_check(not (content["nodes"][0] as Dictionary).has("pos"), "内容指纹不含节点位置")
	_check(not (content["nodes"][0] as Dictionary).has("collapsed"), "内容指纹不含折叠状态")
	_check(not (content["frames"][0] as Dictionary).has("rect"), "内容指纹不含分组框矩形")
	var moved := probe.duplicate(true)
	moved["frames"][0]["rect"] = [50, 60, 300, 200]
	moved["nodes"][0]["collapsed"] = false
	_check(FxFrameCache.fingerprint_of(moved, 30, 1.0) == FxFrameCache.fingerprint_of(probe, 30, 1.0),
		"挪分组框 / 折叠卡片不换指纹")
	var edited := probe.duplicate(true)
	edited["nodes"][0]["params"]["v"] = 2
	_check(FxFrameCache.fingerprint_of(edited, 30, 1.0) != FxFrameCache.fingerprint_of(probe, 30, 1.0),
		"改参数仍然换指纹")

	# ---- 10. 「内容变了却没说」必须被判成问题 ----
	# 构造一条静默写入事件（修订号没变、指纹却变了），断言报告能把它认出来。
	shell.run_command("diag.cache", ["reset"])
	FxCacheTrace.record(FxCacheTrace.KIND_BUCKET, {
		"reason": "tick", "rebuilt": true, "silent": true,
		"parts_before": {"nodes": 1, "edges": 1, "meta": 1},
		"parts_after": {"nodes": 2, "edges": 1, "meta": 1},
		"detail_before": {"nodes": {"a": 1}, "edges": {}},
		"detail_after": {"nodes": {"a": 2}, "edges": {}},
	})
	var silent_titles: Array[String] = []
	for raw in FxCacheReport.report({"render": render}).get("findings", []):
		silent_titles.append(String((raw as Dictionary).get("title", "")))
	var caught := false
	for title in silent_titles:
		if title.contains("没走变更通知"):
			caught = true
	_check(caught, "静默写入被判成问题（%s）" % " / ".join(PackedStringArray(silent_titles)))

	# 收尾：把本套件动过的设置恢复成默认值。
	# 设置是**落盘**的（settings.cfg），留着一个 quality.operator=0.8 会让别的套件
	# 里的「精确帧」断言全部失败 —— 这坑本轮已经踩过一次。
	FxSettings.reset("quality.operator")
	FxSettings.reset("render.prefetch_workers")

	_quit(0 if failures.is_empty() else 1)


func _buckets() -> Array:
	var out: Array = []
	for raw in render.cache_trace():
		var item: Dictionary = raw
		if String(item.get("kind", "")) == "bucket":
			out.append(item)
	return out


func _invalidates() -> Array:
	var out: Array = []
	for raw in render.cache_trace():
		var item: Dictionary = raw
		if String(item.get("kind", "")) == "invalidate":
			out.append(item)
	return out


func _gates() -> Dictionary:
	var out := {}
	for raw in render.cache_trace():
		var item: Dictionary = raw
		if String(item.get("kind", "")) != "change":
			continue
		var gate := String(item.get("gate", "?"))
		out[gate] = int(out.get(gate, 0)) + 1
	return out


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
