extends SceneTree
## 发布用截图：打开真实示范工程（103 节点 / 60 帧），按「整图适配」取景，
## 存进 docs/screenshots/。必须是带显示的运行（要真实渲染）：
##   godot --path . --script res://tests/_shot_release.gd --resolution 1600x900

const PROJECT := "res://examples/demo/示范工程.fxproj"
const OUT := "res://docs/screenshots/"

var shell: FxShell = null


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
		print("SHOT_FAIL 外壳未实例化")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var actions: Object = shell.service("document") as Object
	await actions.call("open_path_async", PROJECT)
	for i in range(240):
		await process_frame
		if (shell.store.doc.get("nodes", []) as Array).size() >= 100:
			break
	var render: Object = shell.service("render")
	render.set("auto_render", true)
	# 等首帧出图，整图适配再截。
	for i in range(60):
		await process_frame
	_frame_all()
	for i in range(40):
		await process_frame
	await _shot("01-overview.png")
	# 展开一个有图像输出的节点，让卡片缩略图与状态签出现在画面里。
	var target := ""
	for item in shell.store.doc.get("nodes", []):
		var node: Dictionary = item
		if String(node.get("type", "")) == "output.final":
			target = String(node.get("id", ""))
			break
	var editor: Variant = shell.call("panel", "editor.graph")
	if not target.is_empty() and editor != null:
		editor.call("_on_collapse_changed", target, false)
		var view: Variant = (editor.get("node_views") as Dictionary).get(target)
		if view != null:
			_focus(view, editor)
		for i in range(120):
			await process_frame
			break
		await _shot("02-node-card.png")
	# 时间轴单独一张：底部区域放大取景。
	if editor != null:
		_frame_all()
		for i in range(30):
			await process_frame
	var timeline: Variant = shell.call("panel", "editor.timeline")
	if timeline != null:
		await _shot("03-timeline.png")
	print("SHOT_DONE nodes=%d frames=%d" % [
		(shell.store.doc.get("nodes", []) as Array).size(), int(render.call("frame_count"))])
	quit(0)


func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(OUT + name))
	print("SHOT %s %dx%d" % [name, image.get_width(), image.get_height()])


## 把整张图缩放到画布里：算所有节点视图的包围盒，反推 zoom 与滚动偏移。
func _frame_all() -> void:
	var editor: Variant = shell.call("panel", "editor.graph")
	if editor == null:
		return
	var graph: GraphEdit = editor.get("graph")
	if graph == null:
		return
	var views: Dictionary = editor.get("node_views")
	if views.is_empty():
		return
	var box := Rect2()
	var first := true
	for key in views.keys():
		var view: Control = views[key]
		var rect := Rect2(view.position_offset, view.size)
		box = rect if first else box.merge(rect)
		first = false
	var pad := 80.0
	var zoom := clampf(minf(graph.size.x / (box.size.x + pad * 2.0),
		graph.size.y / (box.size.y + pad * 2.0)), 0.12, 1.0)
	graph.zoom = zoom
	graph.scroll_offset = (box.position + box.size * 0.5) * zoom - graph.size * 0.5


## 把某个节点居中放大：宣传图里要看得清卡片上的小图与状态签。
func _focus(view: Control, editor: Variant) -> void:
	var graph: GraphEdit = editor.get("graph")
	if graph == null:
		return
	graph.zoom = 1.35
	graph.scroll_offset = (view.position_offset + view.size * 0.5) * graph.zoom \
		- graph.size * 0.5
