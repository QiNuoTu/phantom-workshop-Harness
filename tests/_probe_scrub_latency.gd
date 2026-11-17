extends SceneTree
## 拖动时间轴的响应延迟：从 set_time 到「屏幕上是这一帧的精确图」隔了多少帧。
##
##   godot --headless --path . --script res://tests/_probe_scrub_latency.gd
##
## 判定基准是**缓存里那一格**的像素哈希 —— 不是「画面变了」，因为
## 「变了」也可能是上一帧的图晚到。这是唯一能区分「跟手」和「慢半拍」的口径。

const PROJECT := "res://examples/demo/示范工程.fxproj"

var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService
var last := ""


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	root.add_child(packed.instantiate())
	_run.call_deferred()


func _run() -> void:
	for i in range(20):
		await process_frame
	for child in root.get_children():
		if child is FxShell:
			shell = child as FxShell
			break
	store = shell.get("store") as FxDocumentStore
	render = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	render.clear_cache()
	await actions.call("open_path_async", PROJECT)
	for i in range(400):
		await process_frame
		var st := render.cache_stats()
		if int(st.get("ready", 0)) >= int(st.get("total", 1)) and int(st.get("total", 0)) > 0:
			break
	print("LAT 缓存就绪 %d/%d" % [
		int(render.cache_stats().get("ready", 0)), int(render.cache_stats().get("total", 0))])

	for t in [0.5, 1.0, 1.5, 0.3, 1.2]:
		# 基准图：同一份文档、同一时刻的精确帧（导出用的那条路径），
		# 与「缓存里那一格」等价，但缓存空着时也能拿到。
		var target := _hash(render.render_once(float(t)))
		store.set_time(float(t))
		var index := render.frame_index()
		var frames := 0
		var t0 := Time.get_ticks_msec()
		var got := ""
		while frames < 240:
			await process_frame
			frames += 1
			got = _hash(render.last_image())
			if got == target:
				break
		print("LAT t=%.2f 帧=%d 等待=%d 帧 / %d ms 命中=%s" % [
			float(t), index, frames, Time.get_ticks_msec() - t0, str(got == target)])
	FxPluginHost.shutdown()
	quit(0)


func _hash(image: Image) -> String:
	if image == null or image.is_empty():
		return "null"
	var data := image.get_data()
	var acc := 0
	for i in range(0, data.size(), 7):
		acc = (acc * 31 + int(data[i])) % 2147483647
	return "%dx%d:%d" % [image.get_width(), image.get_height(), acc]
