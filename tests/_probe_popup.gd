extends SceneTree
## 图形模式下验证「欢迎页 → 加载工程 / 新建」这条路径不再触发
## `_sub_window_grab_focus: index == -1`。
## 无头模式跑不出来（subwindow 是真实窗口才存在），所以必须带显示跑：
##   godot --path . --script res://tests/_probe_popup.gd

var shell: FxShell


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for _i in range(24):
		await process_frame
	var welcome := _find_welcome(root)
	print("PROBE welcome=", welcome != null)
	if welcome == null:
		print("PROBE 跳过：欢迎页没显示")
		_finish()
		return

	welcome.call("_on_open")
	print("PROBE 已触发加载工程")
	for _i in range(30):
		await process_frame
	print("PROBE 对话框数=", _count_dialogs(root))
	print("PROBE 有文件面板打开=", _any_visible_file_dialog(root))

	_finish()


func _finish() -> void:
	FxPluginHost.shutdown()
	print("PROBE 完成")
	quit(0)


func _find_welcome(node: Node) -> FxWelcomeWindow:
	for child in node.get_children():
		if child is FxWelcomeWindow:
			return child as FxWelcomeWindow
		var found := _find_welcome(child)
		if found != null:
			return found
	return null


func _count_dialogs(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		if child is AcceptDialog or child is FileDialog:
			total += 1
		total += _count_dialogs(child)
	return total


func _any_visible_file_dialog(node: Node) -> bool:
	for child in node.get_children():
		if child is FileDialog and (child as FileDialog).visible:
			return true
		if _any_visible_file_dialog(child):
			return true
	return false
