extends SceneTree
## 混合/模糊微基准，用来判断哪条实现路径真的更快。
## 运行：godot --headless --path . --script res://tests/bench_blend.gd


func _initialize() -> void:
	var size := Vector2i(128, 128)
	var base := FxImageUtil.new_canvas(size, Color(0.1, 0.1, 0.1, 1.0))
	var top := FxImageUtil.new_canvas(size, Color(0.8, 0.2, 0.4, 0.7))

	var t0 := Time.get_ticks_usec()
	for i in range(100):
		var dst: Image = base.duplicate()
		FxImageUtil.blend_image(dst, top, Vector2.ZERO, "normal", 1.0)
	print("blend normal α1   %.3f ms" % (float(Time.get_ticks_usec() - t0) / 100000.0))

	t0 = Time.get_ticks_usec()
	for i in range(100):
		var dst2: Image = base.duplicate()
		FxImageUtil.blend_image(dst2, top, Vector2.ZERO, "normal", 0.35)
	print("blend normal α.35 %.3f ms" % (float(Time.get_ticks_usec() - t0) / 100000.0))

	t0 = Time.get_ticks_usec()
	for i in range(100):
		var dst3: Image = base.duplicate()
		FxImageUtil.blend_image(dst3, top, Vector2.ZERO, "add", 1.0)
	print("blend add         %.3f ms" % (float(Time.get_ticks_usec() - t0) / 100000.0))

	t0 = Time.get_ticks_usec()
	for i in range(50):
		FxOpsImage._box_blur(top, 4)
	print("blur r4           %.3f ms" % (float(Time.get_ticks_usec() - t0) / 50000.0))

	var params := {"brightness": 0.0, "contrast": 1.0, "gamma": 1.0}
	t0 = Time.get_ticks_usec()
	for i in range(50):
		FxOpsImage.levels(null, {}, null, {"image": top}, params)
	print("levels            %.3f ms" % (float(Time.get_ticks_usec() - t0) / 50000.0))

	t0 = Time.get_ticks_usec()
	for i in range(50):
		FxOpsImage.tint(null, {}, null, {"image": top}, {"color": "#7dffb0", "amount": 0.22})
	print("tint              %.3f ms" % (float(Time.get_ticks_usec() - t0) / 50000.0))

	t0 = Time.get_ticks_usec()
	for i in range(50):
		FxOpsImage.invert(null, {}, null, {"image": top}, {})
	print("invert            %.3f ms" % (float(Time.get_ticks_usec() - t0) / 50000.0))
	_quit(0)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
