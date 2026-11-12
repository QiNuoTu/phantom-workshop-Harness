extends SceneTree
## 只截一张：展开节点后的「帧状态签」长什么样（绿/黄两态）。
##   godot --path . --script res://tests/_shot_badge.gd

const PROJECT := "res://examples/demo/示范工程.fxproj"
const OUT := "res://tests/out_badge.png"


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	root.add_child(packed.instantiate())
	for i in range(15):
		await process_frame
	var shell: FxShell = null
	for child in root.get_children():
		if child is FxShell:
			shell = child as FxShell
			break
	var render: FxRenderService = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	var editor: FxGraphEditor = shell.panel("editor.graph") as FxGraphEditor
	await actions.call("open_path_async", PROJECT)
	for i in range(1200):
		await process_frame
		if render.cache.frame_count() >= 60 and render.cache.missing() == 0 \
				and not render.prefetching():
			break
	# 展开一个有图像输出的节点，并把它挪到视野中间。
	var target := ""
	for item in shell.store.doc.get("nodes", []):
		if String((item as Dictionary).get("type", "")) == "image.blur":
			target = String((item as Dictionary).get("id", ""))
			break
	if target.is_empty():
		for item in shell.store.doc.get("nodes", []):
			target = String((item as Dictionary).get("id", ""))
			if not target.is_empty():
				break
	var view: FxGraphNodeView = editor.node_views.get(target)
	if view != null:
		view.set_collapsed(false)
		editor.call("_on_collapse_changed", target, false)
		editor.graph.zoom = 1.0
		editor.graph.scroll_offset = (view.position_offset + view.size * 0.5) \
			- editor.graph.size * 0.5
		# 只留这一张卡片：其它节点会压在上面，截出来根本看不清状态签。
		for key in editor.node_views.keys():
			var other: FxGraphNodeView = editor.node_views[key]
			if other != null and is_instance_valid(other) and other != view:
				other.visible = false
	# 等它烘到绿。
	for i in range(600):
		await process_frame
		if int(render.bake_info(target).get("state", 0)) == 2:
			break
	for i in range(20):
		await process_frame
	await RenderingServer.frame_post_draw
	var green := root.get_texture().get_image()
	_save_crop(green, view, OUT.get_basename() + "_green.png")
	# 制造「等这一帧」：清掉伴随层并换到后面两帧。
	render.previews.clear()
	var fps := float(FxGraphDoc.timeline(shell.store.doc).get("fps", 30))
	shell.store.set_time(clampf(shell.store.current_time + 2.0 / fps, 0.0, 2.0))
	for i in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	var waiting := root.get_texture().get_image()
	_save_crop(waiting, view, OUT.get_basename() + "_waiting.png")
	var info: Dictionary = render.bake_info(target)
	print("SHOT node=%s state=%d frame=%d shown=%d" % [
		target, int(info.get("state", -1)), int(info.get("frame", -1)),
		int(info.get("shown", -1))])
	var badge: Label = view.get("_bake_badge")
	if badge != null:
		print("SHOT badge text=%s visible=%s rect=%s color=%s" % [
			badge.text, str(badge.visible), str(badge.get_global_rect()), str(badge.modulate)])
	print("SHOT green=%s waiting=%s" % [OUT.get_basename() + "_green.png",
		OUT.get_basename() + "_waiting.png"])
	quit(0)


## 只保留节点卡片那一块，放大看状态签。
func _save_crop(shot: Image, view: FxGraphNodeView, path: String) -> void:
	var rect := view.get_global_rect()
	var scale := float(shot.get_width()) / maxf(root.size.x, 1.0)
	var crop := Rect2i(
		int((rect.position.x - 4.0) * scale), int((rect.position.y - 4.0) * scale),
		int((rect.size.x + 8.0) * scale), int((rect.size.y + 8.0) * scale))
	crop = crop.intersection(Rect2i(Vector2i.ZERO, shot.get_size()))
	if crop.size.x < 8 or crop.size.y < 8:
		shot.save_png(path)
		return
	shot.get_region(crop).save_png(path)
