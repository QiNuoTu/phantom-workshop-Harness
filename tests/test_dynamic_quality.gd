extends SceneTree
## 动态质量 + 画布尺寸不变量测试。
##
## 这套断言的是三条**契约**，不是三个功能：
##   1. 画布尺寸就是桶的布局：改了画布必须换桶，异形帧永不入库、永不上屏；
##   2. 「正在算」是一档独立的界面状态：它只影响颜色，绝不冒充「缓存好了」；
##   3. 草稿只服务显示：它可以在没有精确帧时上屏，但不写缓存、不参与精确性判定，
##      精确帧到达后原地替换。
##
## 运行：
##   godot --headless --path . --script res://tests/test_dynamic_quality.gd

const CANVAS_A := Vector2i(128, 72)
const CANVAS_B := Vector2i(200, 150)

var failures: Array[String] = []
var ok_count: int = 0
## 动过持久化设置就必须在退出前放回去（无论断言成没成）。
var _touched_draft_setting: bool = false
var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService


func _initialize() -> void:
	print("== 动态质量 / 画布尺寸不变量 ==")
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		push_error("主场景加载失败")
		_quit(1)
		return
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for i in range(10):
		await process_frame
	store = shell.store
	render = shell.service("render") as FxRenderService
	_check(store != null and render != null, "外壳、文档、渲染服务都已就位")
	if store == null or render == null:
		_quit(1)
		return

	# ================= 1. 缓存层：帧尺寸是布局，异形帧一律拒绝 =================
	var cache := render.cache
	var doc := FxGraphDoc.create("尺寸测试")
	FxGraphDoc.set_timeline(doc, 30, 0.2, false)
	cache.prepare(doc, 30, 0.2, CANVAS_A)
	_check(cache.frame_size() == CANVAS_A, "定桶记下帧尺寸（%s）" % str(cache.frame_size()))
	_check(cache.frame_count() == 6, "帧数与时长对齐（%d）" % cache.frame_count())

	var good := Image.create(CANVAS_A.x, CANVAS_A.y, false, Image.FORMAT_RGBA8)
	good.fill(Color(0.2, 0.4, 0.6, 1.0))
	cache.put(0, good, true, false, 1)
	_check(cache.state(0) == FxFrameCache.STATE_READY, "同尺寸帧可以入库")

	var bad := Image.create(CANVAS_B.x, CANVAS_B.y, false, Image.FORMAT_RGBA8)
	bad.fill(Color(1, 0, 0, 1))
	cache.put(1, bad, true, false, 1)
	_check(cache.state(1) == FxFrameCache.STATE_EMPTY, "异形帧被拒绝（不入库）")

	# 换尺寸必须重建：哪怕文档一模一样，帧尺寸变了桶就不能复用。
	cache.prepare(doc, 30, 0.2, CANVAS_B)
	var build := cache.last_build()
	_check(bool(build.get("rebuilt", false)), "只改帧尺寸也必须换桶")
	_check(cache.frame_size() == CANVAS_B, "换桶后帧尺寸跟上（%s）" % str(cache.frame_size()))
	_check(cache.state(0) != FxFrameCache.STATE_READY or cache.fetch(0) == null,
		"换桶后旧尺寸的帧不会被当成命中取出来")

	# 内存层也要过尺寸校验：换桶前先塞一张，换桶后取出来必须不是它。
	cache.prepare(doc, 30, 0.2, CANVAS_A)
	cache.put(2, good, true, false, 1)
	var fetched := cache.fetch(2)
	_check(fetched != null and fetched.get_size() == CANVAS_A, "内存热层命中尺寸正确")
	cache.prepare(doc, 30, 0.2, CANVAS_B)
	var after := cache.fetch(2)
	_check(after == null or after.get_size() == CANVAS_B,
		"换尺寸后内存里那张旧图不再冒充命中（%s）" % (
			str(after.get_size()) if after != null else "null"))

	# ================= 2. 「渲染中」是界面态，不是缓存态 =================
	cache.prepare(doc, 30, 0.2, CANVAS_A)
	cache.set_rendering([1, 3])
	_check(cache.display_state(1) == FxFrameCache.STATE_RENDERING, "在飞帧显示为「渲染中」（橘）")
	_check(cache.state(1) == FxFrameCache.STATE_EMPTY, "「渲染中」不改变缓存语义（仍是没算过）")
	var stats := cache.stats()
	_check(int(stats.get("rendering", 0)) == 2, "统计里能数出在飞帧（%d）" % int(stats.get("rendering", 0)))
	cache.set_rendering([])
	_check(cache.display_state(1) == FxFrameCache.STATE_EMPTY, "任务结束后橘色消失")
	# 已经就绪的帧永远显示绿：在飞标记不许把绿格涂橘。
	cache.put(3, good, true, false, 1)
	cache.set_rendering([3])
	_check(cache.display_state(3) == FxFrameCache.STATE_READY, "已就绪的帧不会被标成渲染中")
	cache.set_rendering([])

	# ================= 3. 渲染服务：画布尺寸改变后屏幕必须跟上 =================
	var actions: Object = shell.service("document")
	actions.call("open_path", "res://examples/demo/示范工程.fxproj")
	for i in range(600):
		await process_frame
		if (store.doc.get("nodes", []) as Array).size() > 50:
			break
	_check((store.doc.get("nodes", []) as Array).size() > 50, "示范工程打开")
	for i in range(900):
		await process_frame
		if render.last_image() != null and render.cache.frame_count() > 0:
			break
	_check(render.last_image() != null, "出第一帧")

	var canvas0 := FxGraphDoc.canvas(store.doc)
	for target in [CANVAS_B, Vector2i(96, 96), canvas0]:
		store.set_canvas(target.x, target.y)
		var got := Vector2i.ZERO
		# 屏幕与桶是**两条独立的路**：屏幕可以靠一次交互求帧立刻跟上，
		# 桶要等下一次 0.25s 巡检才换。所以两件事各等各的，不能用一个等待条件。
		for i in range(300):
			await process_frame
			var img: Image = render.last_image()
			if img != null and img.get_size() == target:
				got = img.get_size()
				break
		_check(got == target, "改画布到 %s 后屏幕上就是它（实得 %s）" % [str(target), str(got)])
		for i in range(120):
			if render.cache.frame_size() == target:
				break
			await process_frame
		_check(render.cache.frame_size() == target,
			"桶的帧尺寸跟着画布（%s）" % str(render.cache.frame_size()))

	# ================= 4. 动态质量：草稿先上屏，精确帧随后替换 =================
	var pipe := render.preview_pipeline_config()
	_check(pipe.has("draft"), "管线参数里能查到草稿通道（诊断/测试可见）")
	var draft_on := bool(pipe.get("draft", false))
	var steps: Array = pipe.get("draft_steps", [])
	_check(not steps.is_empty() or not draft_on, "草稿阶梯有档位声明")
	if not draft_on:
		print("  ·  草稿通道当前不可用（线程前提不满足），跳过第 4、5 段")
		_quit(0)
		return

	# 挑一个真的改得动内容的数值参数：先列候选，逐个试到内容身份变化为止。
	var sample_id := ""
	var sample_path := ""
	var sample_value: Variant = 0.0
	var candidates: Array[Dictionary] = []
	for item in store.doc.get("nodes", []):
		var node: Dictionary = item
		var params: Dictionary = node.get("params", {})
		for key in params.keys():
			if params[key] is float or params[key] is int:
				candidates.append({"id": String(node.get("id", "")),
					"path": String(key), "value": params[key]})
				break
		if candidates.size() >= 12:
			break
	var rev_before := store.content_key()
	for cand in candidates:
		store.apply_param(String(cand["id"]), String(cand["path"]),
			float(cand["value"]) + 4.0, false)
		await process_frame
		if store.content_key() != rev_before:
			sample_id = String(cand["id"])
			sample_path = String(cand["path"])
			sample_value = cand["value"]
			break
	_check(not sample_id.is_empty(), "找到能改内容的样本参数（%s:%s）" % [sample_id, sample_path])
	if sample_id.is_empty():
		_quit(0)
		return

	# 冷路径才是草稿的战场：清掉缓存，让这一帧真的没有图。
	render.clear_cache()
	await _wait(90)
	var canvas := FxGraphDoc.canvas(store.doc)
	# lambda 按值捕获局部变量，计数只能放进字典里带回外层。
	var marks := {"draft": -1, "exact": -1, "draft_size": Vector2i.ZERO,
		"draft_cache_state": -1}
	var started := Time.get_ticks_msec()
	var probe := func(image: Image, stats: Dictionary) -> void:
		var dt := Time.get_ticks_msec() - started
		if int(marks["draft"]) < 0 and bool(stats.get("draft", false)):
			marks["draft"] = dt
			marks["draft_size"] = image.get_size()
			# 草稿上屏的那一刻，缓存里这一格必须仍然是「没算好」。
			marks["draft_cache_state"] = cache.state(int(stats.get("frame", 0)))
		if int(marks["exact"]) < 0 and bool(stats.get("exact_frame", false)) \
				and not bool(stats.get("draft", false)):
			marks["exact"] = dt
	render.rendered.connect(probe)
	started = Time.get_ticks_msec()
	store.apply_param(sample_id, sample_path, float(sample_value) + 9.0, false)
	var saw_rendering := false
	for i in range(1800):
		await process_frame
		if not saw_rendering and bool(pipe.get("draft", false)):
			for index in range(render.frame_count()):
				if int(render.cache_state(index)) == FxFrameCache.STATE_RENDERING:
					saw_rendering = true
					break
		if int(marks["exact"]) >= 0 and int(marks["draft"]) >= 0:
			break
	render.rendered.disconnect(probe)
	var draft_ms := int(marks["draft"])
	var exact_ms := int(marks["exact"])
	_check(draft_ms >= 0, "没有缓存时草稿帧也能上屏（%d ms）" % draft_ms)
	_check(Vector2i(marks["draft_size"]) == canvas,
		"草稿按画布尺寸上屏（%s vs %s）" % [str(marks["draft_size"]), str(canvas)])
	_check(exact_ms >= 0, "草稿之后精确帧仍然会到（%d ms）" % exact_ms)
	_check(exact_ms < 0 or draft_ms < 0 or draft_ms <= exact_ms,
		"草稿不晚于精确帧（草稿 %d / 精确 %d）" % [draft_ms, exact_ms])
	_check(int(marks["draft_cache_state"]) != FxFrameCache.STATE_READY,
		"草稿上屏不等于这一帧算好了（缓存状态 %d）" % int(marks["draft_cache_state"]))
	if exact_ms >= 0:
		var index := render.frame_index()
		_check(cache.state(index) == FxFrameCache.STATE_READY,
			"精确帧最终落进缓存（第 %d 帧）" % index)
	_check(saw_rendering, "标尺能报出「渲染中」（橘色 = 有线程正在为这一格干活）")

	# 精确帧就位后不该再出草稿：那纯属浪费一条线程的 CPU。
	var extra := {"draft": 0}
	var counter := func(image: Image, stats: Dictionary) -> void:
		if bool(stats.get("draft", false)):
			extra["draft"] = int(extra["draft"]) + 1
	render.rendered.connect(counter)
	await _wait(120)
	render.rendered.disconnect(counter)
	_check(int(extra["draft"]) == 0, "精确帧就位后不再产出草稿（实得 %d 帧）" % int(extra["draft"]))

	# ================= 5. 关掉开关就真的没有草稿 =================
	# 这条设置是**持久化**的：半路失败也必须恢复，否则下一次跑测试就是
	# 「草稿通道莫名其妙不见了」——查起来要一下午。收尾在 `_quit` 里兜底。
	_touched_draft_setting = true
	FxSettings.set_value("render.draft", false)
	await _wait(40)
	render.clear_cache()
	await _wait(20)
	var off := {"draft": 0}
	var off_counter := func(image: Image, stats: Dictionary) -> void:
		if bool(stats.get("draft", false)):
			off["draft"] = int(off["draft"]) + 1
	render.rendered.connect(off_counter)
	store.apply_param(sample_id, sample_path, float(sample_value) + 13.0, false)
	await _wait(240)
	render.rendered.disconnect(off_counter)
	_check(int(off["draft"]) == 0, "关掉 render.draft 后不再出草稿（实得 %d）" % int(off["draft"]))
	_check(not bool(render.preview_pipeline_config().get("draft", true)),
		"管线参数如实报告草稿已关")
	FxSettings.set_value("render.draft", true)
	await _wait(30)

	_quit(0)


func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		ok_count += 1
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	if _touched_draft_setting:
		FxSettings.set_value("render.draft", true)
		_touched_draft_setting = false
	if not failures.is_empty():
		print("失败 %d 条：" % failures.size())
		for item in failures:
			print("  - ", item)
		code = 1
	else:
		print("全部通过（%d 条断言）" % ok_count)
	FxPluginHost.shutdown()
	quit(code)
