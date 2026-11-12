extends SceneTree
## 探针 7：验收 one_shot —— 确定 / 取消 / Esc / 关闭按钮 都不能再报
## `_sub_window_grab_focus: index == -1`。带显示跑。

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _case("确定键", func(dlg: AcceptDialog) -> void:
		dlg.get_ok_button().pressed.emit()
	)
	await _case("关闭请求", func(dlg: AcceptDialog) -> void:
		dlg.close_requested.emit()
	)
	await _case("Esc", func(dlg: AcceptDialog) -> void:
		var ev := InputEventAction.new()
		ev.action = "ui_cancel"
		ev.pressed = true
		dlg.window_input.emit(ev)
	)
	await _case("WM 关闭通知", func(dlg: AcceptDialog) -> void:
		dlg.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	)
	await _file_case()
	print("PROBE 完成")
	quit(0)


func _case(label: String, action: Callable) -> void:
	print("---- ", label)
	var dlg := AcceptDialog.new()
	dlg.title = label
	dlg.dialog_text = "probe"
	FxUiKit.style_window(dlg)          # 内部会调 one_shot
	root.add_child(dlg)
	await _wait(4)
	FxUiKit.popup_later(dlg, "popup_centered")
	await _wait(8)
	print("    显示=", dlg.visible)
	action.call(dlg)
	await _wait(8)
	print("    释放后还在树里=", is_instance_valid(dlg) and dlg.is_inside_tree())


func _file_case() -> void:
	print("---- FileDialog 取消")
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	FxUiKit.style_window(fd)
	root.add_child(fd)
	await _wait(4)
	FxUiKit.popup_later(fd, "popup_centered_ratio", [0.5])
	await _wait(10)
	print("    显示=", fd.visible, " 原生=", fd.use_native_dialog)
	fd.get_cancel_button().pressed.emit()
	await _wait(10)
	print("    释放后还在树里=", is_instance_valid(fd) and fd.is_inside_tree())


func _wait(n: int) -> void:
	for _i in range(n):
		await process_frame
