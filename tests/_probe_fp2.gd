extends SceneTree
## 极轻量无头诊断（不开窗口、不渲染、不预渲染）：
##   1. 帧指纹函数本身是否确定（同一份文档连续算两次必须相同）；
##   2. 打开工程后文档内容是否还在变（内容哈希逐帧打印）。
##   godot --headless --path . --script res://tests/_probe_fp2.gd

const PROJECT := "res://examples/demo/示范工程.fxproj"


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
	var actions: Object = shell.service("document") as Object
	await actions.call("open_path_async", PROJECT)
	for i in range(12):
		await process_frame
	var doc: Dictionary = shell.store.doc
	var a := FxFrameCache.fingerprint_of(doc, 30, 2.0)
	var b := FxFrameCache.fingerprint_of(doc, 30, 2.0)
	print("FP2_STABLE a=%s b=%s same=%s" % [a, b, str(a == b)])
	# 连续 120 帧观察内容哈希是否漂移（位置/尺寸已被剔除，只应该是不变）。
	var seen: Array[int] = []
	var buckets: Array[String] = []
	var render: FxRenderService = shell.service("render") as FxRenderService
	for i in range(120):
		await process_frame
		var h := JSON.stringify(FxFrameCache.content_of(shell.store.doc)).hash()
		if seen.is_empty() or seen[seen.size() - 1] != h:
			seen.append(h)
		var fp := render.cache.fingerprint()
		if buckets.is_empty() or buckets[buckets.size() - 1] != fp:
			buckets.append(fp)
	print("FP2_DRIFT frames=120 distinct=%d hashes=%s rev=%d content=%d" % [
		seen.size(), str(seen), shell.store.revision(), shell.store.content_revision()])
	print("FP2_BUCKETS %s  doc_hash=%d" % [str(buckets), seen[seen.size() - 1]])
	quit(0)
