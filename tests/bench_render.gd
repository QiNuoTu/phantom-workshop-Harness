extends SceneTree
## 渲染基准：连续跑若干帧，输出每帧耗时与首个耗时分段。
## 运行：godot --headless --path . --script res://tests/bench_render.gd

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var editor: Control = packed.instantiate()
	root.add_child(editor)
	_run.call_deferred(editor)


func _run(editor: Control) -> void:
	for i in range(4):
		await process_frame
	var doc: Dictionary = editor.get("doc")
	var runner: FxGraphRunner = editor.get("runner")
	# 单节点耗时：定位瓶颈
	var probe := FxGraphRunner.new()
	probe.capture_previews = false
	for id in ["src", "blur", "tint", "fx", "out"]:
		var t0 := Time.get_ticks_usec()
		for k in range(6):
			probe.evaluate_node(doc, id, 0.5)
		var ms := float(Time.get_ticks_usec() - t0) / 6000.0
		print("  %-6s %.2f ms" % [id, ms])

	runner.quality = 0
	runner.capture_previews = true
	var t_all := Time.get_ticks_usec()
	for i in range(10):
		runner.run(doc, float(i) / 30.0)
	var ms_frame := float(Time.get_ticks_usec() - t_all) / 10000.0
	print("播放预览（含节点预览） %.2f ms/帧" % ms_frame)

	runner.capture_previews = false
	t_all = Time.get_ticks_usec()
	var last: Dictionary = {}
	for i in range(10):
		last = runner.run(doc, float(i) / 30.0)
	var ms_no_preview := float(Time.get_ticks_usec() - t_all) / 10000.0
	print("播放预览（无节点预览） %.2f ms/帧  cache_hits=%d" % [ms_no_preview, int((last.get("stats", {}) as Dictionary).get("cache_hits", 0))])

	runner.quality = 1
	runner.capture_previews = false
	t_all = Time.get_ticks_usec()
	for i in range(5):
		last = runner.run(doc, float(i) / 30.0)
	print("精确渲染（暂停/导出） %.2f ms/帧" % (float(Time.get_ticks_usec() - t_all) / 5000.0))
	var timings: Dictionary = (last.get("stats", {}) as Dictionary).get("timings", {})
	var keys: Array = timings.keys()
	keys.sort()
	for key in keys:
		print("    %-6s %.2f ms" % [key, float(timings[key])])
	_quit(0)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
