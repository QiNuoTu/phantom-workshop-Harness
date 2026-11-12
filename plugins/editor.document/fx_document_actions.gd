class_name FxDocumentActions
extends Node
## 文档服务：新建 / 打开 / 保存 / 另存为 / 欢迎页 / 自动保存，以及首次启动的示例装载。
##
## 由 editor.document 插件通过 services() 注册。面板与命令只调用这里，
## 不直接碰 FileDialog / FileAccess；换存储格式只需要改这个服务。
##
## 格式：
##   · `.fxproj`       ZIP 工程包，里面是普通 JSON + 可选的素材/插件目录；
##                     版本写在 manifest.json 里，ZIP 本身只当壳。
##   · `.fxgraph`   纯文本（内容就是 JSON，后缀不再缀 `.json`），不附带任何文件，
##                 缺依赖时弹面板列出并允许修复资源；老的 `.fxgraph.json` 仍能打开。
##
## Ctrl+S = 瞬时增量保存：工程包只写 `.delta` 差量日志，不重写大文件；
## JSON 则在内容没变时直接跳过写盘。定时保存落到工程旁边的同名文件夹。

var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService
var current_path: String = ""

var _open_dialog: FileDialog
var _project_dialog: FxProjectSaveDialog = null
var _welcome: FxWelcomeWindow = null
var _dependency_dialog: FxDependencyDialog = null
var _autosave_timer: Timer
## 上一次整包保存时的文档快照：增量保存拿它算差量。
var _baseline: Dictionary = {}

const RECENT_NAME := "recent.cfg"
const SETTING_WELCOME := "project.show_welcome"
const SETTING_AUTOSAVE := "project.autosave_seconds"


static func create(ctx: Dictionary) -> FxDocumentActions:
	var node := FxDocumentActions.new()
	node.setup(ctx)
	return node


func setup(ctx: Dictionary) -> void:
	shell = ctx.get("shell")
	store = ctx.get("store")
	render = ctx.get("render")
	name = "DocumentActions"
	_build_dialogs()


func _build_dialogs() -> void:
	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.use_native_dialog = true
	_open_dialog.add_filter("*.fxproj,*.fxgraph,*.fxgraph.json,*.json", "幻像工坊工程")
	_open_dialog.file_selected.connect(open_path_async)
	add_child(_open_dialog)

	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = false
	_autosave_timer.timeout.connect(_on_autosave)
	add_child(_autosave_timer)
	# setup() 发生在服务实例被挂进场景树之前：这里不能 start()，等 tree_entered。
	tree_entered.connect(func() -> void: _apply_autosave_setting.call_deferred())
	if is_inside_tree():
		_apply_autosave_setting.call_deferred()


# ================= 生命周期 =================

## 首次启动：只有文档为空时才装载示例。
func boot() -> void:
	if store == null or not store.doc.is_empty():
		return
	if render != null:
		render.auto_render = false
	store.attach(FxDemoGraph.build())
	if render != null:
		render.auto_render = true
		render.request_render()
	current_path = ""
	_baseline = store.doc.duplicate(true)
	store.set_selection("blur")
	_status("示例：棋盘 → 关键帧模糊 → 染色 + pixelfx 火焰 → 三层输出")


# ================= 新建 / 打开 =================

func new_document() -> void:
	var fresh := FxGraphDoc.create("未命名")
	FxGraphDoc.set_canvas(fresh, 128, 128)
	FxGraphDoc.set_timeline(fresh, 30, 1.0, true)
	var out := FxGraphDoc.add_node(fresh, "output.final", "", Vector2(420, 180))
	if not out.is_empty():
		fresh["output"] = out["id"]
	current_path = ""
	_baseline = fresh.duplicate(true)
	store.attach(fresh)
	if not out.is_empty():
		store.set_selection(String(out["id"]))
	_status("已新建空白图")


func open_popup() -> void:
	FxUiKit.popup_later(_open_dialog, "popup_centered_ratio", [0.6])


## 同步入口：测试、无界面、以及「已经确定要立刻打开」的路径走这里。
func open_path(path: String) -> void:
	if FxProjectArchive.is_zip_path(path):
		_open_zip(path)
	else:
		_open_json(path)


## 界面入口：读工程/解包素材的过程会上报进度，右下角卡片与状态栏同步显示。
## 与 open_path 的唯一区别是「会 await」——语义完全一致。
func open_path_async(path: String) -> void:
	_begin_progress("打开工程 · %s" % path.get_file())
	if FxProjectArchive.is_zip_path(path):
		await _open_zip_async(path)
		return
	_report_progress(0, 2, path.get_file())
	await FxProjectArchive.next_frame()
	_open_json(path)
	_report_progress(2, 2, path.get_file())
	_finish_progress()


func _open_zip_async(path: String) -> void:
	var status := FxProjectArchive.version_status(path)
	if not String(status.get("error", "")).is_empty():
		_status("工程包读不了：%s" % String(status["error"]))
		_finish_progress()
		return
	if bool(status.get("found", false)) and not bool(status.get("compatible", true)):
		# 版本不匹配要等用户点按钮：交给同步路径处理，进度先收起。
		_finish_progress()
		_open_zip(path)
		return
	await _load_zip_async(path)


func _load_zip_async(path: String) -> void:
	var result: Dictionary = await FxProjectArchive.read_zip_async(path,
		func(done: int, total: int, label: String) -> void:
			_report_progress(done, total, label)
	)
	if not bool(result.get("ok", false)):
		_status(String(result.get("message", "加载失败")))
		_finish_progress()
		return
	_apply_loaded(path, result.get("doc", {}) as Dictionary,
		String(result.get("message", "已加载工程包")))
	_finish_progress()


func _open_zip(path: String) -> void:
	var status := FxProjectArchive.version_status(path)
	if not String(status.get("error", "")).is_empty():
		_status("工程包读不了：%s" % String(status["error"]))
		return
	if bool(status.get("found", false)) and not bool(status.get("compatible", true)):
		var supported: Array = status.get("supported", [])
		var ask := ConfirmationDialog.new()
		FxUiKit.style_window(ask)
		ask.title = "工程版本不匹配"
		ask.dialog_text = "该工程由版本 %s 保存，当前软件支持 %s。仍要尝试加载吗？" % [
			String(status.get("version", "")), ", ".join(PackedStringArray(supported)),
		]
		ask.ok_button_text = "仍然加载"
		ask.cancel_button_text = "取消"
		if shell != null:
			shell.add_child(ask)
			ask.confirmed.connect(func() -> void:
				_load_zip_now(path)
				ask.queue_free()
			)
			ask.canceled.connect(func() -> void: ask.queue_free())
			FxUiKit.popup_later(ask)
		else:
			_load_zip_now(path)
		return
	# 没读到版本号：按约定当成老工程，直接用当前版本打开，不打扰用户。
	_load_zip_now(path)


func _load_zip_now(path: String) -> void:
	var result := FxProjectArchive.read_zip(path)
	if not bool(result.get("ok", false)):
		_status(String(result.get("message", "加载失败")))
		return
	_apply_loaded(path, result.get("doc", {}) as Dictionary,
		String(result.get("message", "已加载工程包")))


## 装载完成后的统一收尾：路径 / 增量基线 / 选中输出 / 最近列表 / 依赖检查。
## 同步与异步两条加载路径共用，保证「怎么读进来」不影响「读进来之后做什么」。
func _apply_loaded(path: String, doc: Dictionary, message: String) -> void:
	if doc.is_empty():
		_status("读不到工程：%s" % path)
		return
	current_path = path
	_baseline = doc.duplicate(true)
	store.attach(doc)
	var output := FxGraphDoc.output_id(store.doc)
	if not output.is_empty():
		store.set_selection(output)
	_add_recent(path)
	_check_dependencies()
	_status("✓ " + message)


func _open_json(path: String) -> void:
	var doc := FxProjectArchive.load_json(path)
	if doc.is_empty():
		_status("读不到工程：%s" % path)
		return
	# 增量日志比主文件新时补上差量（Ctrl+S 的瞬时保存留下的）。
	var delta := FxProjectArchive.read_delta(path)
	if not FxProjectArchive.delta_empty(delta):
		doc = FxProjectArchive.apply_delta(doc, delta)
	current_path = path
	_baseline = doc.duplicate(true)
	store.attach(doc)
	var output := FxGraphDoc.output_id(store.doc)
	if not output.is_empty():
		store.set_selection(output)
	_add_recent(path)
	_check_dependencies()
	_status("已打开 %s" % path.get_file())


## 加载后检查依赖。
##
## 只有在**插件**真的缺失时才弹面板打断用户 —— 插件在运行期装不上，必须让用户知道。
## 只缺素材时不打扰：状态栏提示一条，「文件 → 依赖检查…」随时可以打开同一张面板修复。
## （导出路径这类「要写到哪」的参数不算依赖，见 FxProjectArchive.scan_dependencies。）
func _check_dependencies() -> void:
	var deps := FxProjectArchive.scan_dependencies(store.doc)
	var missing_assets: Array = deps.get("missing_assets", [])
	var missing_plugins: Array = deps.get("missing_plugins", [])
	if missing_plugins.is_empty():
		if not missing_assets.is_empty():
			_status("⚠ %d 个素材找不到 · 文件 → 依赖检查… 可修复" % missing_assets.size())
		return
	show_dependency_dialog()
	if not missing_assets.is_empty():
		_status("⚠ 缺 %d 个插件、%d 个素材" % [missing_plugins.size(), missing_assets.size()])


## 手动打开依赖面板（命令与菜单都走这里）。
func show_dependency_dialog() -> void:
	if shell == null or store == null or store.doc.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		return
	if _dependency_dialog != null and is_instance_valid(_dependency_dialog):
		_dependency_dialog.queue_free()
	_dependency_dialog = FxDependencyDialog.create(store.doc, store, shell)
	shell.add_child(_dependency_dialog)
	# 等 viewport 登记完子窗口再弹，避免 _sub_window_grab_focus: index == -1
	FxUiKit.popup_later(_dependency_dialog)


static func cmd_deps(ctx: Dictionary) -> void:
	var actions: Variant = ctx.get("document")
	if actions != null and actions.has_method("show_dependency_dialog"):
		actions.call("show_dependency_dialog")


# ================= 进度上报 =================
#
# 基座只提供一块「标题 + 进度条 + 一行小字」的画布（shell.begin_progress 等），
# 这里负责把「打开/保存到第几步了」翻译成它认识的三件事。

func _begin_progress(title: String) -> void:
	if shell != null and shell.has_method("begin_progress"):
		shell.call("begin_progress", title)


func _report_progress(done: int, total: int, label: String) -> void:
	if shell != null and shell.has_method("set_progress"):
		shell.call("set_progress", done, total, label)


func _finish_progress() -> void:
	if shell != null and shell.has_method("end_progress"):
		shell.call("end_progress")


# ================= 保存 =================
#
# 语义（三条路径）：
#   · 工程还没保存过 → Ctrl+S / Ctrl+Shift+S 都弹保存面板；
#   · 已保存 + Ctrl+S → 静默增量：工程包只写 `.delta`，JSON 内容没变就跳过；
#   · 已保存 + Ctrl+Shift+S → 另存为（额外保存一份），默认给副本文件名。

## Ctrl+S。
func save() -> void:
	# 正在子图标签里（双击子图节点进来的）：Ctrl+S 存的是**那张子图**，
	# 不能把它的内容写进工程包。用 has_method 软探测，没装蓝图插件时自然跳过。
	if _save_active_subgraph():
		return
	if current_path.is_empty():
		save_as_popup()
		return
	if FxProjectArchive.is_zip_path(current_path):
		_quick_save_zip()
	else:
		_quick_save_json()


## 蓝图面板正在看的文档如果是「子图标签」，把保存交给它；返回是否已处理。
func _save_active_subgraph() -> bool:
	var graph_editor := _graph_editor()
	if graph_editor == null:
		return false
	if String(graph_editor.call("active_document_path")).is_empty():
		return false
	graph_editor.call("save_active_tab")
	return true


func _graph_editor() -> Object:
	if shell == null:
		return null
	var panel: Variant = shell.panel("editor.graph")
	if panel == null or not (panel is Object):
		return null
	var editor := panel as Object
	if not editor.has_method("save_active_tab") or not editor.has_method("active_document_path"):
		return null
	return editor


## 相对上次整包保存，文档是否有改动。
func has_unsaved_changes() -> bool:
	if store == null:
		return false
	return JSON.stringify(_baseline) != JSON.stringify(store.doc)


func save_state_text() -> String:
	var graph_editor := _graph_editor()
	if graph_editor != null:
		var sub := String(graph_editor.call("active_document_path"))
		if not sub.is_empty():
			var dirty := bool(graph_editor.call("active_tab_dirty"))
			return ("%s · 有改动" % sub.get_file()) if dirty else ("%s · 已保存" % sub.get_file())
	if current_path.is_empty():
		return "未保存"
	var file := current_path.get_file()
	return ("%s · 有改动" % file) if has_unsaved_changes() else ("%s · 已保存" % file)


func _quick_save_zip() -> void:
	var delta := FxProjectArchive.make_delta(_baseline, store.doc)
	if FxProjectArchive.delta_empty(delta):
		_status("已保存 %s · 没有新改动" % current_path.get_file())
		return
	var err := FxProjectArchive.write_delta(current_path, delta)
	if err != OK:
		_status("增量保存失败：%s" % error_string(err))
		return
	_baseline = store.doc.duplicate(true)
	var changed: int = (delta.get("changed_nodes", []) as Array).size() \
		+ (delta.get("removed_nodes", []) as Array).size()
	_status("✓ 已增量保存 %d 处改动 · %s · %s"
		% [changed, current_path.get_file(), _clock()])


func _quick_save_json() -> void:
	if not has_unsaved_changes():
		_status("已保存 %s · 没有新改动" % current_path.get_file())
		return
	var err := FxProjectArchive.save_json(store.doc, current_path)
	if err != OK:
		_status("保存失败：%s" % error_string(err))
		return
	_baseline = store.doc.duplicate(true)
	FxProjectArchive.clear_delta(current_path)
	_status("✓ 已保存 %s · %s" % [current_path.get_file(), _clock()])


static func _clock() -> String:
	return Time.get_time_string_from_system()


## 保存面板：未保存过的工程叫「保存」，已保存过的叫「另存为」并预填副本名。
func save_as_popup() -> void:
	if shell == null:
		return
	if _project_dialog != null and is_instance_valid(_project_dialog):
		_project_dialog.queue_free()
	var copying := not current_path.is_empty()
	_project_dialog = FxProjectSaveDialog.create(store.doc, _default_file_name(),
		Callable(self, "_on_project_save"), {
			"mode": "copy" if copying else "save",
			"current_path": current_path,
		})
	shell.add_child(_project_dialog)
	FxUiKit.popup_later(_project_dialog)


func _on_project_save(payload: Dictionary) -> void:
	var dialog_progress: Callable = payload.get("progress", Callable()) as Callable
	var dialog_done: Callable = payload.get("done", Callable()) as Callable
	_begin_progress("保存工程 · %s" % String(payload.get("path", "")).get_file())
	# 面板里的进度条与右下角浮层共享同一份上报：面板可能被挡住，浮层始终可见。
	var progress := func(done: int, total: int, label: String) -> void:
		_report_progress(done, total, label)
		if dialog_progress.is_valid():
			dialog_progress.call(done, total, label)
	var finished := func(ok: bool, message: String) -> void:
		_finish_progress()
		if dialog_done.is_valid():
			dialog_done.call(ok, message)
	save_full_async(String(payload.get("path", "")), bool(payload.get("as_zip", true)),
		payload.get("options", {}) as Dictionary, progress, finished)


## 整包保存 / 另存为（同步）：写完整工程包或纯文本，并重置增量基线。
func save_full(path: String, as_zip: bool, options: Dictionary = {}) -> void:
	var result := _write_full(path, as_zip, options)
	_apply_saved(result)


## 带进度的异步版本：每写一个条目让出一帧，面板上的进度条真的会走。
## 结束无论成败都会回调 finished(ok, message)，面板据此关闭或显示错误。
func save_full_async(path: String, as_zip: bool, options: Dictionary,
		progress: Callable = Callable(), finished: Callable = Callable()) -> void:
	var final_path := FxProjectArchive.normalize_path(path, as_zip)
	if final_path.is_empty():
		var empty := {"ok": false, "message": "路径为空，未保存"}
		_apply_saved(empty)
		if finished.is_valid():
			finished.call(false, String(empty["message"]))
		return
	var result: Dictionary
	if as_zip:
		result = await FxProjectArchive.save_zip_async(store.doc, final_path, options, progress)
	else:
		if progress.is_valid():
			progress.call(0, 1, final_path.get_file())
			await FxProjectArchive.next_frame()
		result = _write_full(final_path, false, options)
		if progress.is_valid():
			progress.call(1, 1, final_path.get_file())
	var ok := _apply_saved(result)
	if finished.is_valid():
		finished.call(ok, String(result.get("message", "")))


func _write_full(path: String, as_zip: bool, options: Dictionary) -> Dictionary:
	if path.strip_edges().is_empty():
		return {"ok": false, "message": "路径为空，未保存"}
	var final_path := FxProjectArchive.normalize_path(path, as_zip)
	if as_zip:
		return FxProjectArchive.save_zip(store.doc, final_path, options)
	var err := FxProjectArchive.save_json(store.doc, final_path)
	return {"ok": err == OK, "path": final_path,
		"message": "已保存 %s" % final_path.get_file() if err == OK else error_string(err)}


## 落盘成功后的统一收尾：记住路径 / 重置增量基线 / 写最近列表 / 状态栏提示。
func _apply_saved(result: Dictionary) -> bool:
	if not bool(result.get("ok", false)):
		_status(String(result.get("message", "保存失败")))
		return false
	var saved := String(result.get("path", ""))
	if not saved.is_empty():
		current_path = saved
	_baseline = store.doc.duplicate(true)
	FxProjectArchive.clear_delta(current_path)
	_add_recent(current_path)
	_status("✓ %s · %s" % [String(result.get("message", "已保存")), _clock()])
	return true


## 旧入口保留：面板里直接给路径时按扩展名决定格式。
func save_to(path: String) -> void:
	save_full(path, FxProjectArchive.is_zip_path(path))


func _default_file_name() -> String:
	var name := String(FxGraphDoc.meta_value(store.doc, "name", "untitled"))
	for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", " "]:
		name = name.replace(ch, "_")
	# 已保存过的工程走「另存为」：给副本名并落在同一个目录，
	# 这样 Ctrl+Shift+S 回车就是「额外保存一份」，不会默默覆盖原工程。
	var copying := not current_path.is_empty()
	if copying:
		name += "_副本"
	var as_zip := not copying or FxProjectArchive.is_zip_path(current_path)
	var file := name + (".fxproj" if as_zip else ".fxgraph")
	if copying:
		var dir := current_path.get_base_dir()
		if not dir.is_empty():
			return dir.path_join(file)
	return file


# ================= 最近打开 / 欢迎页 / 自动保存 =================

func recent_files() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(FxProjectArchive.config_path(RECENT_NAME)) != OK:
		return []
	var out: Array = cfg.get_value("recent", "files", [])
	return out if out is Array else []


func _add_recent(path: String) -> void:
	var entries: Array = []
	for item in recent_files():
		if String((item as Dictionary).get("path", "")) != path:
			entries.append(item)
	entries.push_front({
		"path": path, "at": Time.get_datetime_string_from_system(false, true),
	})
	while entries.size() > 12:
		entries.pop_back()
	var cfg := ConfigFile.new()
	cfg.set_value("recent", "files", entries)
	cfg.save(FxProjectArchive.config_path(RECENT_NAME))


func show_welcome_enabled() -> bool:
	return bool(FxSettings.typed_value(SETTING_WELCOME, true))


func set_show_welcome(value: bool) -> void:
	FxSettings.set_value(SETTING_WELCOME, value)


func show_welcome() -> void:
	if not show_welcome_enabled() or DisplayServer.get_name() == "headless":
		return
	if shell == null:
		return
	if _welcome != null and is_instance_valid(_welcome):
		_welcome.queue_free()
	_welcome = FxWelcomeWindow.create(self)
	shell.add_child(_welcome)
	FxUiKit.popup_later(_welcome)


func _apply_autosave_setting() -> void:
	if _autosave_timer == null or not _autosave_timer.is_inside_tree():
		return
	var seconds := int(FxSettings.typed_value(SETTING_AUTOSAVE, 60))
	if seconds <= 0:
		_autosave_timer.stop()
		return
	_autosave_timer.wait_time = float(seconds)
	_autosave_timer.start()


func _on_autosave() -> void:
	_apply_autosave_setting()
	if current_path.is_empty() or store == null:
		return
	var result := FxProjectArchive.write_autosave(current_path, store.doc)
	if bool(result.get("ok", false)):
		_status("定时保存：%s" % String(result.get("path", "")).get_file())


func _status(message: String) -> void:
	if shell != null:
		shell.status(message)
	_refresh_save_hint()


## 状态栏右端常驻的「当前文件 · 已保存 / 有改动」。
func _refresh_save_hint() -> void:
	if shell == null or not shell.has_method("set_status_hint"):
		return
	shell.set_status_hint(save_state_text(),
		not current_path.is_empty() and not has_unsaved_changes())


# ================= 命令入口（静态，供插件注册） =================

static func _actions(ctx: Dictionary) -> FxDocumentActions:
	var value: Variant = ctx["services"].get("document")
	return value as FxDocumentActions


static func cmd_new(ctx: Dictionary) -> void:
	var actions := _actions(ctx)
	if actions != null:
		actions.new_document()


static func cmd_open(ctx: Dictionary) -> void:
	var actions := _actions(ctx)
	if actions != null:
		actions.open_popup()


static func cmd_save(ctx: Dictionary) -> void:
	var actions := _actions(ctx)
	if actions != null:
		actions.save()


static func cmd_save_as(ctx: Dictionary) -> void:
	var actions := _actions(ctx)
	if actions != null:
		actions.save_as_popup()


static func cmd_welcome(ctx: Dictionary) -> void:
	var actions := _actions(ctx)
	if actions != null:
		actions.show_welcome()


static func cmd_undo(ctx: Dictionary) -> void:
	var store: FxDocumentStore = ctx.get("store")
	if store != null:
		store.undo()


static func cmd_redo(ctx: Dictionary) -> void:
	var store: FxDocumentStore = ctx.get("store")
	if store != null:
		store.redo()


static func cmd_delete_selected(ctx: Dictionary) -> void:
	var store: FxDocumentStore = ctx.get("store")
	if store == null or store.selected_id.is_empty():
		return
	var node_id := store.selected_id
	store.remove_node(node_id)
	if ctx["shell"] != null:
		ctx["shell"].status("已删除 %s" % node_id)


static func cmd_quit(_ctx: Dictionary) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.quit()
