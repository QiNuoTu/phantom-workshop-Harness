extends SceneTree
## 播放中缩略图验证（唯一基准：examples/demo/示范工程.fxproj）。
##
## 要求：节点**展开**时小图跟着动画动，**收起**时不产生也不接收预览。
## 必须带显示跑：
##   godot --path . --script res://tests/_probe_preview_playback.gd
##
## 检查：
##   1. 只有报上去的展开节点会收到 frame_previews（收起的一个都不许有）；
##   2. 缩略图帧号随着播放推进而变化（不是一张静止图）；
##   3. 缩略图尺寸受 PREVIEW_THUMB 限制（不会把整帧图塞进卡片）；
##   4. 展开 → 收起后不再有新图（焦点清空）。

const PROJECT := "res://examples/demo/示范工程.fxproj"

var shell: FxShell = null
var render: FxRenderService = null
var frames: Array[int] = []
var node_ids_hit: Dictionary = {}
var sizes: Array[Vector2i] = []
var index_seen: Array[int] = []


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
		print("PREVIEW_FAIL 外壳未实例化")
		quit(1)
		return
	render = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	if render == null or actions == null:
		print("PREVIEW_FAIL 服务未就绪")
		quit(1)
		return
	render.clear_cache()
	await actions.call("open_path_async", PROJECT)
	for i in range(60):
		await process_frame
		if (shell.store.doc.get("nodes", []) as Array).size() >= 100:
			break
	var nodes: Array = shell.store.doc.get("nodes", [])
	if nodes.size() < 100:
		print("PREVIEW_FAIL 工程没装载成功（%d 节点）" % nodes.size())
		quit(1)
		return
	# 挑两个「有图像输出」的真实节点当展开目标，另一个保持收起。
	var expanded: Array[String] = []
	for item in nodes:
		var node_data: Dictionary = item
		var node_id := String(node_data.get("id", ""))
		if node_id.is_empty():
			continue
		expanded.append(node_id)
		if expanded.size() >= 2:
			break
	var collapsed_id := String((nodes[nodes.size() - 1] as Dictionary).get("id", ""))
	render.set_preview_focus(expanded)
	print("PREVIEW_FOCUS expanded=%s collapsed=%s" % [expanded, collapsed_id])

	render.frame_previews.connect(func(index: int, previews: Dictionary) -> void:
		index_seen.append(index)
		for key in previews.keys():
			node_ids_hit[String(key)] = int(node_ids_hit.get(String(key), 0)) + 1
			var image: Variant = previews[key]
			if image is Image:
				sizes.append((image as Image).get_size())
	)

	# 先等精确帧缓存就绪，再播放：播放只读缓存，不会现场求值。
	for i in range(600):
		await process_frame
		if int(render.cache_stats().get("ready", 0)) >= render.frame_count():
			break
	print("PREVIEW_CACHE ready=%s/%s" % [
		render.cache_stats().get("ready", 0), render.frame_count()])
	render.set_playing(true)
	for i in range(200):
		await process_frame
	render.set_playing(false)
	var hit_first := int(node_ids_hit.size())
	var idx_unique := {}
	for i in index_seen:
		idx_unique[i] = true
	var max_side := 0
	for size in sizes:
		max_side = maxi(max_side, maxi(size.x, size.y))
	var only_expanded := true
	for key in node_ids_hit.keys():
		if not expanded.has(String(key)):
			only_expanded = false
	print("PREVIEW_RESULT signals=%d frames=%d nodes=%s max_side=%d" % [
		index_seen.size(), idx_unique.size(), node_ids_hit.keys(), max_side])
	# 收起之后不应再有新图进来。
	var before := index_seen.size()
	render.set_preview_focus([])
	render.set_playing(true)
	for i in range(90):
		await process_frame
	render.set_playing(false)
	var after := index_seen.size()
	print("PREVIEW_COLLAPSED new_signals=%d focus=%s" % [after - before, render.preview_focus()])
	var pass_ok := only_expanded and hit_first > 0 and idx_unique.size() >= 3 \
		and max_side <= FxRenderService.PREVIEW_THUMB and after == before \
		and render.preview_focus().is_empty()
	print("PREVIEW_PASS=%s" % pass_ok)
	render.auto_render = false
	for i in range(2):
		await process_frame
	FxPluginHost.shutdown()
	quit(0 if pass_ok else 1)
