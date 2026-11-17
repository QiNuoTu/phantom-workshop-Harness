extends SceneTree
## 开窗验收（app 0.0.17）：①拖时间轴跟不跟手 ②输出节点的画布滑块会不会把渲染器弄坏。
##
##   godot --path . --resolution 1440x900 --script res://tests/_probe_ui_fix.gd
##
## 只打印事实 + 截图（user://graph_test/）。

const PROJECT := "res://examples/demo/示范工程.fxproj"

var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService
var preview: Control
var params_ui: Variant


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	root.add_child(packed.instantiate())
	_run.call_deferred()


func _run() -> void:
	for i in range(10):
		await process_frame
	shell = null
	for child in root.get_children():
		if child is FxShell:
			shell = child as FxShell
			break
	store = shell.get("store") as FxDocumentStore
	render = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	if actions.has_method("set_show_welcome"):
		actions.call("set_show_welcome", false)
	for child in shell.get_children():
		if child is FxWelcomeWindow:
			(child as FxWelcomeWindow).queue_free()
	preview = shell.panel("editor.preview")
	render.clear_cache()
	await actions.call("open_path_async", PROJECT)
	for i in range(600):
		await process_frame
		var st := render.cache_stats()
		if int(st.get("total", 0)) > 0 and int(st.get("ready", 0)) >= int(st.get("total", 1)):
			break
	print("FIX 缓存 %d/%d canvas=%s" % [
		int(render.cache_stats().get("ready", 0)), int(render.cache_stats().get("total", 0)),
		str(FxGraphDoc.canvas(store.doc))])

	# ① 连续拖动：模拟一次真实的拖动（每帧一个 set_time），看最后是否跟手
	var t0 := Time.get_ticks_msec()
	for step in range(24):
		store.set_time(0.1 + 0.07 * float(step))
		await process_frame
	var index := render.frame_index()
	var want := _hash(render.cache.fetch(index))
	var shown := _hash(preview.get("preview_rect").texture.get_image())
	print("FIX 拖动 24 步：耗时 %d ms · 末帧 %d · 上屏一致=%s（%s vs %s）" % [
		Time.get_ticks_msec() - t0, index, str(shown == want), shown, want])
	_save("fix_scrub.png")

	# ①b 拖动为什么慢？把「发布一张缓存帧」的每一段拆开量一次。
	var img: Image = render.cache.fetch(render.frame_index())
	if img != null:
		var t_post := Time.get_ticks_usec()
		for i in range(10):
			render._postprocess(img)
		print("FIX postprocess ×10 = %.1f ms" % (float(Time.get_ticks_usec() - t_post) / 1000.0))
		var t_disp := Time.get_ticks_usec()
		for i in range(10):
			render._gpu_display(100 + i, img)
		print("FIX _gpu_display ×10（不同帧号）= %.1f ms"
			% (float(Time.get_ticks_usec() - t_disp) / 1000.0))
	var t_pub := Time.get_ticks_usec()
	for i in range(10):
		render._publish_cached(img, render.frame_index(), true, false)
	print("FIX _publish_cached ×10 = %.1f ms"
		% (float(Time.get_ticks_usec() - t_pub) / 1000.0))

	# ② 输出节点的画布滑块
	var t_idle := Time.get_ticks_usec()
	for i in range(60):
		await process_frame
	print("FIX 空转 60 帧 = %.1f ms/帧" % (float(Time.get_ticks_usec() - t_idle) / 60000.0))
	var graph: Control = shell.panel("editor.graph")
	var view: Variant = graph.get("node_views").get("out")
	params_ui = view.get("params_ui") if view != null else null
	print("FIX 参数界面 %s" % str(params_ui != null))
	if params_ui != null:
		params_ui.call("_write", "canvas_width", 256)
		for i in range(40):
			await process_frame
		var tex: Variant = preview.get("preview_rect").texture
		print("FIX 写画布宽 256 → 文档 %s · 缓存帧尺寸 %s · 屏上 %s" % [
			str(FxGraphDoc.canvas(store.doc)), str(render.cache.frame_size()),
			str((tex as Texture2D).get_size()) if tex != null else "null"])
		var drops := 0
		for entry in render.cache_trace():
			if String((entry as Dictionary).get("kind", "")) == "publish-drop":
				drops += 1
		print("FIX publish-drop %d 条" % drops)
		_save("fix_canvas.png")
		# 再拖一次时间轴：画布变了之后拖动仍要跟手
		store.set_time(0.5)
		for i in range(6):
			await process_frame
		var tex2: Variant = preview.get("preview_rect").texture
		print("FIX 改画布后拖到 0.5s → 帧 %d 屏上 %s" % [render.frame_index(),
			str((tex2 as Texture2D).get_size()) if tex2 != null else "null"])
		# 收尾：改回原尺寸，存盘状态干净
		params_ui.call("_write", "canvas_width", 192)
		for i in range(40):
			await process_frame
		print("FIX 复原 → %s" % str(FxGraphDoc.canvas(store.doc)))
	_save("fix_restore.png")
	_quit()


func _hash(image: Image) -> String:
	if image == null or image.is_empty():
		return "null"
	var data := image.get_data()
	var acc := 0
	for i in range(0, data.size(), 7):
		acc = (acc * 31 + int(data[i])) % 2147483647
	return "%dx%d:%d" % [image.get_width(), image.get_height(), acc]


func _save(name: String) -> void:
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://graph_test")
	image.save_png("user://graph_test/" + name)
	print("截图：", ProjectSettings.globalize_path("user://graph_test/" + name))


func _quit() -> void:
	FxPluginHost.shutdown()
	quit(0)
