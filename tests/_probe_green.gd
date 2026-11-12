extends SceneTree
## 验收「需要等待的帧不会提前变绿」：
##   清空缓存后立刻播放，播放档垫图（stats.approx = true）出现的每一刻，
##   该帧在缓存里的状态必须是 PENDING（黄），绝不能是 READY（绿）。
## 必须带显示跑（要真实渲染循环）：
##   godot --path . --script res://tests/_probe_green.gd

const PROJECT := "res://examples/demo/示范工程.fxproj"

var shell: FxShell = null
var render: FxRenderService = null
var approx := 0
var premature := 0
var exact_seen := 0
var shown: Array[int] = []


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
		print("GREEN_FAIL 外壳未实例化")
		quit(1)
		return
	render = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	await actions.call("open_path_async", PROJECT)
	for i in range(240):
		await process_frame
		if (shell.store.doc.get("nodes", []) as Array).size() >= 100:
			break
	if render == null:
		print("GREEN_FAIL 渲染服务缺失")
		quit(1)
		return
	# 关掉后台预渲染：这样播放时唯一的图源就是「播放档急件」，
	# 正是旧实现会把它们误标成绿格的那条路径。
	FxSettings.set_value("render.prefetch", false)
	# 从「一张图都没有」开始播：这正是用户看到「提前变绿」的场景。
	render.clear_cache()
	render.rendered.connect(_on_rendered)
	render.set_playing(true)
	for i in range(420):
		await process_frame
	render.set_playing(false)
	for i in range(30):
		await process_frame
	FxSettings.reset("render.prefetch")
	var ready := int(render.cache_stats().get("ready", 0))
	var total := int(render.cache_stats().get("total", 0))
	print("GREEN approx=%d premature=%d exact=%d frames=%d ready=%d/%d" % [
		approx, premature, exact_seen, shown.size(), ready, total])
	# 垫图确实出现过（否则这条验收是空跑），且从来没有冒充绿格。
	var ok := approx > 0 and premature == 0 and shown.size() >= 5
	print("GREEN_%s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _on_rendered(_image: Image, stats: Dictionary) -> void:
	var frame := int(stats.get("frame", -1))
	if frame < 0:
		return
	if not bool(stats.get("cached", false)):
		return
	if not shown.is_empty() and shown[shown.size() - 1] == frame:
		return
	shown.append(frame)
	if bool(stats.get("approx", false)):
		approx += 1
		# 垫图发布的这一刻，这一格必须还是黄的。
		if int(render.cache_state(frame)) == 2:
			premature += 1
			print("GREEN_PREMATURE frame=%d state=%d" % [frame, render.cache_state(frame)])
	elif bool(stats.get("exact_frame", true)):
		exact_seen += 1
