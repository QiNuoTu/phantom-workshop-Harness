extends SceneTree
## 缩放是否被误判成「文档变了」的验证探针。
##
## 用户症状：在蓝图画布上滚轮缩放，缓存立刻重来一遍、标签出现未保存点。
## 数据没变就不该触发任何重建。这个探针把「缩放」期间的所有 store 通知、
## 缓存指纹变化、重绘次数都打出来。
##
## 必须带显示跑：
##   godot --path . --script res://tests/_probe_zoom.gd

const PROJECT := "res://examples/demo/示范工程.fxproj"

var shell: FxShell = null
var render: FxRenderService = null
var store: FxDocumentStore = null
var panel: FxGraphEditor = null

var changed_keys: Array = []
var rendered_count := 0
var preview_count := 0
var cache_events := 0
var fp_seen: Array[String] = []


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
		print("ZOOM_FAIL 外壳未实例化")
		quit(1)
		return
	store = shell.store
	render = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	panel = shell.panel("editor.graph") as FxGraphEditor
	if render == null or actions == null or panel == null:
		print("ZOOM_FAIL 服务未就绪")
		quit(1)
		return
	render.clear_cache()
	await actions.call("open_path_async", PROJECT)
	for i in range(90):
		await process_frame
		if (store.doc.get("nodes", []) as Array).size() >= 100:
			break
	if (store.doc.get("nodes", []) as Array).size() < 100:
		print("ZOOM_FAIL 工程没装载成功")
		quit(1)
		return
	store.changed.connect(func(keys: Array) -> void: changed_keys.append(keys))
	render.rendered.connect(func(_i: Image, _s: Dictionary) -> void: rendered_count += 1)
	render.node_previewed.connect(func(_id: String, _i: Image) -> void: preview_count += 1)
	render.cache_changed.connect(func(_s: Dictionary) -> void: cache_events += 1)
	# 等预渲染跑完，缓存全绿，此时任何「重建」都只可能来自缩放。
	for i in range(600):
		await process_frame
		var st := render.cache_stats()
		if int(st.get("missing", 0)) == 0 and not render.prefetching():
			break
	await process_frame
	var before_fp := render.cache.fingerprint()
	var before_missing := int(render.cache_stats().get("missing", 0))
	var before_changed := changed_keys.size()
	var before_rendered := rendered_count
	var before_views := _view_stamp()
	var before_focus := render.preview_focus()
	var before_thumbs := render.previews.stats()
	print("ZOOM_BASELINE missing=%d fp=%s changed=%d rendered=%d views=%s thumbs=%s" % [
		before_missing, before_fp, before_changed, before_rendered, before_views,
		str(before_thumbs.get("frames", 0))])
	# ---- 模拟真实滚轮缩放：把事件推进窗口，让 GraphEdit 自己处理 ----
	var graph: GraphEdit = panel.graph
	var center := graph.get_screen_position() + graph.size * 0.5
	Input.warp_mouse(center)
	await process_frame
	for step in range(4):
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP
		ev.pressed = true
		ev.factor = 1.0
		ev.position = center
		ev.global_position = center
		root.push_input(ev)
		await process_frame
	for step in range(4):
		var ev2 := InputEventMouseButton.new()
		ev2.button_index = MOUSE_BUTTON_WHEEL_DOWN
		ev2.pressed = true
		ev2.factor = 1.0
		ev2.position = center
		ev2.global_position = center
		root.push_input(ev2)
		await process_frame
	# 缩放后再等一小段，任何延迟重建都会在这期间露出。
	for i in range(90):
		await process_frame
	var after_views := _view_stamp()
	var after_focus := render.preview_focus()
	var after_thumbs := render.previews.stats()
	print("ZOOM_AFTER zoom=%.3f fp=%s missing=%d changed=%d rendered=%d previews=%d cache_events=%d" % [
		graph.zoom, render.cache.fingerprint(), int(render.cache_stats().get("missing", 0)),
		changed_keys.size() - before_changed, rendered_count - before_rendered,
		preview_count, cache_events])
	print("ZOOM_VIEWS before=%s after=%s rebuilt=%s" % [
		before_views, after_views, str(before_views != after_views)])
	print("ZOOM_FOCUS before=%d after=%d same=%s" % [
		before_focus.size(), after_focus.size(), str(before_focus == after_focus)])
	print("ZOOM_THUMBS before=%d after=%d" % [
		int(before_thumbs.get("frames", 0)), int(after_thumbs.get("frames", 0))])
	var unique: Array = []
	for keys in changed_keys.slice(before_changed):
		var text := ",".join(PackedStringArray(keys))
		if not unique.has(text):
			unique.append(text)
	print("ZOOM_KEYS %s" % [unique])
	var ok := changed_keys.size() == before_changed and render.cache.fingerprint() == before_fp \
		and rendered_count == before_rendered and before_views == after_views
	print("ZOOM_%s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## 全部节点视图的实例号指纹：任何一次视图重建都会换掉对象。
func _view_stamp() -> String:
	var ids: Array[int] = []
	for key in panel.node_views.keys():
		var view: Object = panel.node_views[key]
		if is_instance_valid(view):
			ids.append(view.get_instance_id())
	ids.sort()
	return str(ids.hash()) + ":" + str(ids.size())
