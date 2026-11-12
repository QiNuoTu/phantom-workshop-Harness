extends SceneTree
## 探针 10：真实外壳里走一遍「欢迎页确定 / 另存为面板取消 / 缺依赖面板」，
## 确认没有 `_sub_window_grab_focus: index == -1`。带显示跑。

var shell: FxShell


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for _i in range(24):
		await process_frame
	var actions: Variant = shell.service("document")
	print("PROBE actions=", actions != null)

	# 1) 欢迎页：确定键（一次性对话框，直接销毁）
	var welcome := _find_welcome(root)
	if welcome != null:
		print("PROBE 欢迎页确定")
		welcome.call("_on_open") == null
		welcome.confirmed.emit()
		for _i in range(10):
			await process_frame
		print("PROBE 欢迎页已释放=", not is_instance_valid(welcome))

	# 2) 另存为面板：弹出后按取消
	if actions != null:
		actions.call("save_as_popup")
		for _i in range(10):
			await process_frame
		var panel := _find_dialog(root, "FxProjectSaveDialog")
		print("PROBE 另存为面板=", panel != null)
		if panel != null:
			(panel as AcceptDialog).canceled.emit()
			for _i in range(10):
				await process_frame
			print("PROBE 另存为面板已释放=", not is_instance_valid(panel))

	# 3) 再弹一次，直接确定（走保存逻辑，写 user:// 或 exe 旁 userdata）
	if actions != null:
		actions.call("save_as_popup")
		for _i in range(10):
			await process_frame
		var panel2 := _find_dialog(root, "FxProjectSaveDialog")
		if panel2 != null:
			(panel2 as AcceptDialog).confirmed.emit()
			for _i in range(10):
				await process_frame
			print("PROBE 另存为确定后释放=", not is_instance_valid(panel2))

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


func _find_dialog(node: Node, class_name_hint: String) -> Node:
	for child in node.get_children():
		if child.get_script() != null and String(child.get_script().get_global_name()) == class_name_hint:
			return child
		var found := _find_dialog(child, class_name_hint)
		if found != null:
			return found
	return null
