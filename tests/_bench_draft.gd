extends SceneTree
## 草稿帧成本基准：同一份工程、同一帧，只改「求值画布倍率」。
##
## 这张表要回答的问题是「1/8 画布到底快多少」，所以：
##   · 只测求值，不含发布/贴屏/纹理；
##   · 每个倍率先热身一帧（执行器与端口表缓存要热），再取三跑中位数；
##   · 跑的就是**草稿线程用的那条路**（`base_scale` + 低算子质量）。
##
## 跑法：godot --headless --path . --script res://tests/_bench_draft.gd

const RUNS := 3

var shell: FxShell


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for i in range(10):
		await process_frame
	var store: FxDocumentStore = shell.store
	var actions: Object = shell.service("document")
	actions.call("open_path", "res://examples/demo/示范工程.fxproj")
	for i in range(900):
		await process_frame
		if (store.doc.get("nodes", []) as Array).size() > 50:
			break
	var doc := store.doc.duplicate(true)
	var canvas := FxGraphDoc.canvas(doc)
	print("工程：%d 节点 · 画布 %s" % [
		(doc.get("nodes", []) as Array).size(), str(canvas)])

	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	runner.compile_plan = {}
	for scale in [1.0, 0.5, 0.25, 0.125]:
		var samples: Array[float] = []
		for run in range(RUNS + 1):
			runner.base_scale = scale
			runner.quality = 1 if scale >= 0.999 else 0
			runner.operator_quality = 1.0 if scale >= 0.999 else 0.35
			var t0 := Time.get_ticks_usec()
			var result: Variant = FxRenderBroker.frame(doc, 0.5, {},
				runner, {"playing": false, "exact": false, "signature": 1})
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			if run > 0:
				samples.append(ms)
			var image: Image = null
			if result is Dictionary:
				image = (result as Dictionary).get("image") as Image
			if run == 0:
				print("  热身 %.3f× → %s %.1f ms" % [
					scale, str(image.get_size() if image != null else "null"), ms])
		samples.sort()
		var mid := samples[samples.size() / 2]
		print("画布 %.3f× → 中位 %.1f ms" % [scale, mid])
	FxPluginHost.shutdown()
	quit(0)
