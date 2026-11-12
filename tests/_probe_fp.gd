extends SceneTree
## 极简诊断：切渲染后端时帧缓存指纹为什么会换桶。
##   godot --path . --script res://tests/_probe_fp.gd

const PROJECT := "res://examples/demo/示范工程.fxproj"


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	root.add_child(packed.instantiate())
	for i in range(20):
		await process_frame
	var shell: FxShell = null
	for child in root.get_children():
		if child is FxShell:
			shell = child as FxShell
			break
	var render: FxRenderService = shell.service("render") as FxRenderService
	var actions: Object = shell.service("document") as Object
	_dump("启动", render, shell)
	await actions.call("open_path_async", PROJECT)
	for i in range(40):
		await process_frame
	_dump("打开工程", render, shell)
	for i in range(30):
		await process_frame
	_dump("等待 30 帧", render, shell)
	FxSettings.set_value("render.backend", "gpu.standard")
	FxRenderBroker.invalidate()
	_dump("切后端后立刻", render, shell)
	for i in range(30):
		await process_frame
		_dump("切后端 30 帧", render, shell)
	quit(0)


func _dump(label: String, render: FxRenderService, shell: FxShell) -> void:
	var doc: Dictionary = shell.store.doc
	print("FP[%s] cache=%s count=%d missing=%d doc_hash=%s raw_hash=%s nodes=%d rev=%d contentrevision=%d" % [
		label, render.cache.fingerprint(), render.cache.frame_count(), render.cache.missing(),
		str(JSON.stringify(FxFrameCache.content_of(doc)).hash()),
		str(JSON.stringify(doc).hash()),
		(doc.get("nodes", []) as Array).size(), shell.store.revision(),
		shell.store.content_revision()])
