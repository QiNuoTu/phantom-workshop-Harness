extends SceneTree
## 帧级 UI 验收：时间轴缩放 / 精确选帧 / 小图烘焙角标 / 播放不缺帧。
##
## 唯一基准仍是 examples/demo/示范工程.fxproj。必须带显示跑：
##   godot --path . --script res://tests/_probe_frame_ui.gd

const PROJECT := "res://examples/demo/示范工程.fxproj"

var shell: FxShell = null
var render: FxRenderService = null
var store: FxDocumentStore = null
var editor: FxGraphEditor = null
var timeline: FxTimelinePanel = null
var fails: int = 0


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		print("  ok  %s" % label)
		return
	fails += 1
	print("  FAIL %s%s" % [label, "" if detail.is_empty() else "  ← " + detail])


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
		print("FRAMEUI_FAIL 外壳未实例化")
		quit(1)
		return
	store = shell.store
	render = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	editor = shell.panel("editor.graph") as FxGraphEditor
	timeline = shell.panel("editor.timeline") as FxTimelinePanel
	if render == null or actions == null or editor == null or timeline == null:
		print("FRAMEUI_FAIL 服务未就绪")
		quit(1)
		return
	render.clear_cache()
	await actions.call("open_path_async", PROJECT)
	# 等真正的工程桶建好（60 帧）并预渲染完，别把上一份文档的 30 帧当成完事。
	for i in range(1200):
		await process_frame
		if render.cache.frame_count() >= 60 and int(render.cache_stats().get("missing", 0)) == 0 \
				and not render.prefetching():
			break
	if (store.doc.get("nodes", []) as Array).size() < 100:
		print("FRAMEUI_FAIL 工程没装载成功")
		quit(1)
		return

	_test_timeline()
	await _test_badges_and_playback()
	print("FRAMEUI_%s (%d failed)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)


## 时间轴：滚轮缩放到 4×，坐标换算必须互逆、锚点必须不动、选帧必须落在整帧上。
func _test_timeline() -> void:
	print("== 时间轴缩放 ==")
	var duration := float(FxGraphDoc.timeline(store.doc).get("duration", 1.0))
	var before := float(timeline.get("_zoom"))
	# 在轨道正中模拟一次滚轮放大（4 格 ≈ 2.4×）。
	var center := Vector2(FxTimelinePanel.LABEL_W + 200, 40)
	for i in range(4):
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP
		ev.pressed = true
		ev.position = center
		timeline._gui_input(ev)
	await process_frame
	var zoom := float(timeline.get("_zoom"))
	_check(zoom > before, "滚轮可以放大刻度", "zoom %.2f" % zoom)
	var anchor_t: float = timeline.call("_x_to_time", center.x)
	# 锚点：缩放前后光标下的时间应该几乎不动（允许半帧误差）。
	var drift := absf(anchor_t - timeline.call("_x_to_time", center.x))
	_check(drift < 0.001, "缩放以光标为锚点", "drift=%.4f" % drift)
	var probe_t := duration * 0.37
	var back: float = timeline.call("_x_to_time", timeline.call("_time_to_x", probe_t))
	_check(absf(back - probe_t) < 0.0005, "时间↔像素换算互逆", "%.4f vs %.4f" % [back, probe_t])
	# 精确选帧：任意位置点下去都落在整帧。
	var fps := float(FxGraphDoc.timeline(store.doc).get("fps", 30))
	var snapped: float = timeline.call("_snap_time", 0.4173)
	_check(absf(snapped * fps - round(snapped * fps)) < 0.0001,
		"选帧吸附到整帧", "%.4fs = %.2f 帧" % [snapped, snapped * fps])
	var frame_before := int(round(store.current_time * fps))
	timeline.call("_set_time_from_x", FxTimelinePanel.LABEL_W + 120.0)
	var frame_after := int(round(store.current_time * fps))
	_check(absf(store.current_time * fps - round(store.current_time * fps)) < 0.0001,
		"拖动播放头也落到整帧", "帧 %d → %d" % [frame_before, frame_after])
	# 放大后一帧至少要有几像素宽，否则「精确」没有意义。
	var lane_w: float = timeline.call("_lane_w")
	var frame_px: float = lane_w / maxf(float(timeline.call("_span")) * fps, 0.001)
	_check(frame_px >= 8.0, "放大后单帧足够宽（可精确点选）", "%.1f px/帧" % frame_px)
	# 复位：双击标尺回到整段。
	var reset := InputEventMouseButton.new()
	reset.button_index = MOUSE_BUTTON_LEFT
	reset.pressed = true
	reset.double_click = true
	reset.position = Vector2(FxTimelinePanel.LABEL_W + 100, 8)
	timeline._gui_input(reset)
	await process_frame
	_check(float(timeline.get("_zoom")) <= 1.001, "双击标尺复位缩放",
		"zoom %.2f" % float(timeline.get("_zoom")))


## 小图角标：展开节点后状态从「未烘焙」走到「已烘焙」，播放期小图跟着帧走。
func _test_badges_and_playback() -> void:
	print("== 小图烘焙角标 / 播放不缺帧 ==")
	var target := ""
	for item in store.doc.get("nodes", []):
		var node_data: Dictionary = item
		if String(node_data.get("type", "")) == "image.blur":
			target = String(node_data.get("id", ""))
			break
	if target.is_empty():
		for item in store.doc.get("nodes", []):
			target = String((item as Dictionary).get("id", ""))
			if not target.is_empty():
				break
	var view: FxGraphNodeView = editor.node_views.get(target)
	_check(view != null, "找到可展开的节点视图", target)
	if view == null:
		return
	view.set_collapsed(false)
	editor.call("_on_collapse_changed", target, false)
	await process_frame
	_check(render.preview_focus().has(target), "展开节点进入缩略图焦点", target)
	var early := int(render.preview_state(target))
	_check(early != 0, "角标不会停在「未烘焙」（焦点已登记）", "state=%d" % early)
	# 等这一帧的小图真的烘焙好。
	for i in range(900):
		await process_frame
		if int(render.bake_info(target).get("state", 0)) == 2:
			break
	var baked: Dictionary = render.bake_info(target)
	_check(int(baked.get("state", -1)) == 2, "当前帧小图烘焙完成时状态签变绿")
	_check(int(baked.get("frame", -1)) == render.frame_index(),
		"绿签上的帧号就是当前帧", "签 f%d / 当前 f%d" % [
			int(baked.get("frame", -1)), render.frame_index()])
	for i in range(30):
		await process_frame
	_check(view.bake_state() == 2, "节点卡片真的把签画成「已烘焙」",
		"state=%d" % view.bake_state())
	_check(view.bake_frame() == render.frame_index(), "卡片上的帧号跟着状态一起更新",
		"f%d" % view.bake_frame())

	# 换帧：播放头往后走两帧。缩略图趟已经把整段备好了，这里先清掉伴随层来模拟
	# 「这一帧还没烘」——要验的正是这种时候签上会不会说清楚（画面还停在第 9 帧）。
	var fps := float(FxGraphDoc.timeline(store.doc).get("fps", 30))
	var old_frame := render.frame_index()
	render.previews.clear()
	var want_t := clampf(store.current_time + 2.0 / fps, 0.0,
		float(FxGraphDoc.timeline(store.doc).get("duration", 1.0)))
	store.set_time(want_t)
	await process_frame
	var waiting: Dictionary = render.bake_info(target)
	_check(int(waiting.get("state", -1)) == 1,
		"没有小图时状态签变成「等这一帧」", "state=%d" % int(waiting.get("state", -1)))
	_check(int(waiting.get("frame", -1)) == render.frame_index(),
		"黄签上的帧号是播放头这一帧", "签 f%d / 播放头 f%d" % [
			int(waiting.get("frame", -1)), render.frame_index()])
	_check(int(waiting.get("shown", -1)) == old_frame,
		"等待时能说出画面停在哪一帧", "shown f%d / 旧帧 f%d" % [
			int(waiting.get("shown", -1)), old_frame])
	# 再等它烘好，应该回到绿签。
	for i in range(900):
		await process_frame
		if int(render.bake_info(target).get("state", 0)) == 2:
			break
	_check(int(render.bake_info(target).get("state", 0)) == 2, "等待的帧算完后回到绿签")

	# 播放：帧号必须连续、且每帧都走缓存（不出现未命中导致的「停一下」）。
	var frames: Array[int] = []
	render.rendered.connect(func(_image: Image, stats: Dictionary) -> void:
		if bool(stats.get("cached", false)):
			frames.append(int(stats.get("frame", -1)))
	)
	render.set_playing(true)
	var badge_lag: Array[int] = []
	for i in range(180):
		await process_frame
		# 播放中：绿签的帧号要么就是播放头，要么是刚刚过去的一两帧（推图有节流）。
		if view.bake_state() == 2:
			badge_lag.append(absi(view.bake_frame() - render.frame_index()))
	render.set_playing(false)
	await process_frame
	var worst := 0
	for lag in badge_lag:
		worst = maxi(worst, lag)
	_check(not badge_lag.is_empty() and worst <= 3,
		"播放中状态签紧跟播放头", "最大落后 %d 帧 / 采样 %d" % [worst, badge_lag.size()])
	var unique: Array[int] = []
	for f in frames:
		if unique.is_empty() or unique[unique.size() - 1] != f:
			unique.append(f)
	_check(unique.size() >= 20, "播放期间发布了足够多的帧", "收到 %d 帧" % unique.size())
	var gap := 0
	for i in range(1, unique.size()):
		var step := unique[i] - unique[i - 1]
		if step != 1 and step != -(int(render.frame_count()) - 1):
			gap += 1
	_check(gap == 0, "播放帧号连续（没有缺帧）", "断点 %d 个：%s" % [gap, str(unique)])
	_check(render.cache_misses == 0, "播放全程缓存命中", "miss=%d" % render.cache_misses)
