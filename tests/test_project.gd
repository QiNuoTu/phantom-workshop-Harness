extends SceneTree
## 工程包（.fxproj / 纯文本 JSON）、版本兼容、依赖检查、增量保存、定时保存、欢迎页组件验收。
## 运行：godot --headless --path . --script res://tests/test_project.gd

var failures: Array[String] = []
var shell: FxShell
const ROOT := "user://project_test"


func _initialize() -> void:
	print("== 工程包与保存策略自测 ==")
	_wipe()
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for i in range(8):
		await process_frame
	_test_paths()
	_test_zip_roundtrip()
	_test_version()
	_test_dependencies()
	await _test_save_progress()
	_test_delta()
	_test_autosave()
	await _test_actions()
	_test_dialogs()
	print("----")
	if failures.is_empty():
		print("工程包与保存策略自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _test_paths() -> void:
	_check(FxProjectArchive.normalize_path("abc", true) == "abc.fxproj", "路径补 .fxproj 扩展名")
	_check(FxProjectArchive.normalize_path("abc.fxgraph", true) == "abc.fxproj", "JSON → 工程包路径")
	_check(FxProjectArchive.normalize_path("abc.fxproj", false) == "abc.fxgraph", "工程包 → JSON 路径")
	_check(FxProjectArchive.normalize_path("abc.fxgraph", false) == "abc.fxgraph", "同格式不重复加后缀")
	_check(FxProjectArchive.is_zip_path("A.FXPROJ"), "扩展名大小写无关")


func _test_zip_roundtrip() -> void:
	var png := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	png.fill(Color(1, 0, 0, 1))
	var asset_path := ROOT + "/tex.png"
	png.save_png(asset_path)

	var doc := _sample_doc(asset_path)
	var path := ROOT + "/demo.fxproj"
	var result := FxProjectArchive.save_zip(doc, path, {
		"include_assets": true, "include_plugins": false,
	})
	_check(bool(result.get("ok", false)), "保存 .fxproj 工程包")
	_check(FileAccess.file_exists(path), "ZIP 文件确实写出")
	var manifest: Dictionary = result.get("manifest", {})
	_check((manifest.get("assets", []) as Array).size() == 1, "清单记录了打包的素材")
	_check(String(manifest.get("host_version", "")) == FxProjectArchive.HOST_VERSION, "宿主版本写进 manifest.json")

	var reader := ZIPReader.new()
	var err := reader.open(path)
	_check(err == OK, "ZIP 是标准可读压缩包")
	if err == OK:
		var files: Array = []
		for name in reader.get_files():
			files.append(String(name))
		_check(files.has(FxProjectArchive.ENTRY_DOC), "包里有图文档")
		_check(files.has(FxProjectArchive.ENTRY_MANIFEST), "包里有清单")
		var has_asset := false
		for name2 in files:
			if String(name2).begins_with("assets/"):
				has_asset = true
		_check(has_asset, "包里有素材文件（ZIP 只是壳，里面全是普通文件）")
		var plain := true
		for name3 in files:
			var entry := String(name3)
			if not (entry == FxProjectArchive.ENTRY_DOC or entry == FxProjectArchive.ENTRY_MANIFEST \
					or entry.begins_with("assets/") or entry.begins_with("plugins/")):
				plain = false
		_check(plain, "包里只有普通文件与目录，没有额外二进制结构（%d 项）" % files.size())
		reader.close()

	var loaded := FxProjectArchive.read_zip(path)
	_check(bool(loaded.get("ok", false)), "读回工程包")
	var out_doc: Dictionary = loaded.get("doc", {})
	_check((out_doc.get("nodes", []) as Array).size() == 2, "图文档节点数一致")
	var extracted: Array = loaded.get("extracted_assets", [])
	_check(extracted.size() == 1, "素材被解到用户目录")
	if extracted.size() == 1:
		var rebound := String((FxGraphDoc.node(out_doc, "tex").get("params", {}) as Dictionary).get("path", ""))
		_check(rebound == String(extracted[0]) and FileAccess.file_exists(rebound), "文档里的路径改指向解出来的素材")


func _test_version() -> void:
	var doc := FxGraphDoc.create("版本")
	var good := ROOT + "/version_ok.fxproj"
	FxProjectArchive.save_zip(doc, good, {})
	var status := FxProjectArchive.version_status(good)
	_check(bool(status.get("found", false)) and bool(status.get("compatible", true)), "当前版本：找到且兼容")
	_check(String(status.get("source", "")) == FxProjectArchive.ENTRY_MANIFEST, "版本来源是 manifest.json")

	var older := ROOT + "/version_old.fxproj"
	FxProjectArchive.save_zip(doc, older, {"omit_version": true})
	var old_status := FxProjectArchive.version_status(older)
	_check(not bool(old_status.get("found", true)) and bool(old_status.get("compatible", false)),
		"读不到版本号 → 按当前版本打开，不询问")

	var future := ROOT + "/version_new.fxproj"
	FxProjectArchive.save_zip(doc, future, {"version": "9.9"})
	var new_status := FxProjectArchive.version_status(future)
	_check(bool(new_status.get("found", false)) and not bool(new_status.get("compatible", true)),
		"版本不匹配被检出")
	_check((new_status.get("supported", []) as Array).has(FxProjectArchive.HOST_VERSION),
		"告知支持版本")


func _test_dependencies() -> void:
	var doc := _sample_doc(ROOT + "/missing.png")
	var deps := FxProjectArchive.scan_dependencies(doc)
	_check((deps.get("assets", []) as Array).size() == 1, "扫描到路径类参数")
	_check((deps.get("missing_assets", []) as Array).size() == 1, "缺失资源被列出")
	var plugins: Array = deps.get("plugins", [])
	_check(not plugins.is_empty(), "扫描到提供节点的插件（%d 个）" % plugins.size())
	var all_installed := true
	for item in plugins:
		if not bool((item as Dictionary).get("installed", false)):
			all_installed = false
	_check(all_installed, "当前环境的插件都算已安装")
	var fixed := FxProjectArchive.repair_asset(doc, "tex", "path", ROOT + "/fixed.png")
	_check(fixed and String((FxGraphDoc.node(doc, "tex").get("params", {}) as Dictionary).get("path", "")) == ROOT + "/fixed.png",
		"手动修复资源会回写参数")


func _test_delta() -> void:
	var base := _sample_doc(ROOT + "/tex.png")
	var changed := base.duplicate(true)
	(FxGraphDoc.node(changed, "tex").get("params", {}) as Dictionary)["alpha"] = 0.4
	FxGraphDoc.add_node(changed, "image.blur", "b", Vector2(200, 0), {"radius": 2.0})
	var delta := FxProjectArchive.make_delta(base, changed)
	_check(not FxProjectArchive.delta_empty(delta), "有改动时差量非空")
	_check((delta.get("changed_nodes", []) as Array).size() == 2, "差量只带改动的节点（%d）" %
		int((delta.get("changed_nodes", []) as Array).size()))
	var rebuilt := FxProjectArchive.apply_delta(base, delta)
	_check((rebuilt.get("nodes", []) as Array).size() == 3, "差量能还原成当前文档")
	_check(FxProjectArchive.delta_empty(FxProjectArchive.make_delta(changed, changed)), "无改动时差量为空")

	var path := ROOT + "/delta_demo.fxgraph"
	_check(FxProjectArchive.write_delta(path, delta) == OK, "差量写到 .delta")
	_check(FileAccess.file_exists(FxProjectArchive.delta_path(path)), "增量文件落在工程旁边")
	_check(not FxProjectArchive.delta_empty(FxProjectArchive.read_delta(path)), "差量能读回")
	FxProjectArchive.clear_delta(path)
	_check(not FileAccess.file_exists(FxProjectArchive.delta_path(path)), "整包保存后清除差量")


func _test_autosave() -> void:
	var path := ROOT + "/autosave_demo.fxproj"
	var dir := FxProjectArchive.autosave_dir(path)
	_check(dir == ROOT + "/autosave_demo", "自动保存目录与工程同名")
	var filename := FxProjectArchive.autosave_path(path).get_file()
	_check(filename.begins_with("autosave_demo_") and filename.ends_with(".fxgraph"),
		"自动保存文件名带时间戳（%s）" % filename)
	var result := FxProjectArchive.write_autosave(path, _sample_doc(ROOT + "/tex.png"))
	_check(bool(result.get("ok", false)) and FileAccess.file_exists(String(result.get("path", ""))),
		"定时保存写出快照")
	_check(DirAccess.dir_exists_absolute(dir), "同名文件夹已建立")


func _test_actions() -> void:
	var actions: FxDocumentActions = shell.service("document") as FxDocumentActions
	# services 表里是实例，往上找一层
	if actions == null:
		for key in ["document"]:
			var candidate: Variant = shell.get(key)
			if candidate is FxDocumentActions:
				actions = candidate
	_check(actions != null, "文档服务可用")
	if actions == null:
		return
	actions.new_document()
	var json_path := ROOT + "/actions.fxgraph"
	actions.save_full(json_path, false, {})
	_check(FileAccess.file_exists(json_path), "整包保存：纯文本 JSON")
	_check((actions.recent_files() as Array).size() >= 1, "保存后进入最近打开")

	var before := FileAccess.get_file_as_string(json_path)
	actions.save()
	_check(FileAccess.get_file_as_string(json_path) == before, "Ctrl+S 无改动时跳过写盘")
	actions.store.apply_param(String(FxGraphDoc.output_id(actions.store.doc)), "background", "#112233")
	actions.save()
	_check(FileAccess.get_file_as_string(json_path) != before, "Ctrl+S 有改动时才写盘")

	var zip_path := ROOT + "/actions.fxproj"
	actions.save_full(zip_path, true, {"include_assets": false, "include_plugins": false})
	_check(FileAccess.file_exists(zip_path), "整包保存：ZIP 工程包")
	var zip_before := FileAccess.get_file_as_bytes(zip_path)
	actions.save()
	_check(not FileAccess.file_exists(zip_path + ".delta"), "工程包无改动时 Ctrl+S 也跳过写盘")
	actions.store.apply_param(String(FxGraphDoc.output_id(actions.store.doc)), "background", "#445566")
	actions.save()
	_check(FileAccess.file_exists(zip_path + ".delta"), "Ctrl+S 只写 .delta 差量")
	_check(FileAccess.get_file_as_bytes(zip_path) == zip_before, "工程包本体没有被重写")
	actions.open_path(json_path)
	_check(actions.current_path == json_path, "加载纯文本工程")
	actions.open_path(zip_path)
	_check(actions.current_path == zip_path, "加载 ZIP 工程包")
	_check(actions.show_welcome_enabled() is bool, "欢迎页开关可读")
	actions.set_show_welcome(false)
	_check(not actions.show_welcome_enabled(), "欢迎页开关可写并持久化")
	actions.set_show_welcome(true)


## 保存进度回调 / 分步写盘 / 保存状态文案。
func _test_save_progress() -> void:
	var png := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	png.fill(Color(0, 1, 0, 1))
	var asset_path := ROOT + "/prog.png"
	png.save_png(asset_path)
	var doc := _sample_doc(asset_path)

	# 规划与写盘分离：条目顺序是 文档 → 素材 → 清单，清单最后写。
	var plan := FxProjectArchive.plan_zip(doc, {
		"path": ROOT + "/plan.fxproj", "include_assets": true, "include_plugins": false})
	_check(bool(plan.get("ok", false)), "工程包可以先规划出待写条目")
	var entries: Array = plan.get("entries", [])
	_check(entries.size() >= 3, "规划结果包含 文档/素材/清单（%d 条）" % entries.size())
	_check(String((entries[0] as Dictionary).get("name", "")) == FxProjectArchive.ENTRY_DOC,
		"第一条是图文档")
	_check(String((entries[entries.size() - 1] as Dictionary).get("name", ""))
		== FxProjectArchive.ENTRY_MANIFEST, "最后一条是清单（素材列表已填好）")

	var steps: Array = []
	var path := ROOT + "/progress.fxproj"
	var result: Dictionary = await FxProjectArchive.save_zip_async(doc, path, {
		"include_assets": true, "include_plugins": false,
	}, func(done: int, total: int, label: String) -> void:
		steps.append([done, total, label])
	)
	_check(bool(result.get("ok", false)), "异步保存能写完工程包")
	_check(steps.size() == entries.size(), "每个条目都回调一次进度（%d/%d）"
		% [steps.size(), entries.size()])
	_check(steps.size() > 0 and int(steps[steps.size() - 1][0]) == steps.size(),
		"进度是递增的 done 计数")
	_check(FileAccess.file_exists(path), "异步保存真的落盘")

	# 保存状态文案：新建的文档没有路径，保存过一次之后带文件名。
	var actions := _document_actions()
	if actions != null:
		actions.new_document()
		_check(actions.save_state_text() == "未保存", "未保存的文档状态文案是「未保存」")
		_check(not actions.has_unsaved_changes() or actions.current_path.is_empty(),
			"新建文档没有未保存改动（基线就是它自己）")
		actions.save_full(ROOT + "/state.fxproj", true,
			{"include_assets": false, "include_plugins": false})
		_check(actions.save_state_text().contains("已保存"), "保存后状态文案带「已保存」")
		_check(not actions.has_unsaved_changes(), "保存后没有未保存改动")
		actions.store.apply_param(String(FxGraphDoc.output_id(actions.store.doc)), "background", "#123456")
		_check(actions.has_unsaved_changes(), "改过参数后能识别出「有改动」")
		_check(actions.save_state_text().contains("有改动"), "状态文案反映未保存改动")
		# 已保存过的工程再走「另存为」：默认给副本名，不覆盖原文件。
		var copy_name: String = actions._default_file_name()
		_check(copy_name.contains("_副本"), "已保存工程另存为时默认给副本名")
		_check(copy_name.ends_with(".fxproj"), "副本沿用工程包格式")


func _document_actions() -> FxDocumentActions:
	for child in root.get_children():
		var found := _scan_actions(child)
		if found != null:
			return found
	return null


func _scan_actions(node: Node) -> FxDocumentActions:
	if node is FxDocumentActions:
		return node
	for child in node.get_children():
		var found := _scan_actions(child)
		if found != null:
			return found
	return null


func _test_dialogs() -> void:
	var doc := FxGraphDoc.create("面板")
	var dlg := FxProjectSaveDialog.create(doc, "demo.fxproj", Callable())
	_check(dlg != null and dlg.get_child_count() > 0, "保存面板能实例化（格式/路径/勾选）")
	dlg.queue_free()
	var dep := FxDependencyDialog.create(doc, null, null)
	_check(dep != null and dep.get_child_count() > 0, "缺依赖面板能实例化")
	dep.queue_free()
	var welcome := FxWelcomeWindow.create(null)
	_check(welcome != null and welcome.get_child_count() > 0, "欢迎页能实例化（最近/新建/加载）")
	welcome.queue_free()


# ================= 工具 =================

func _sample_doc(asset_path: String) -> Dictionary:
	var doc := FxGraphDoc.create("工程包样例")
	FxGraphDoc.set_canvas(doc, 32, 32)
	FxGraphDoc.add_node(doc, "image.texture", "tex", Vector2.ZERO, {"path": asset_path})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(240, 0), {})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "tex", "image", "out", "layer_0")
	return doc


func _wipe() -> void:
	if not DirAccess.dir_exists_absolute(ROOT):
		DirAccess.make_dir_recursive_absolute(ROOT)
		return
	for name in DirAccess.get_directories_at(ROOT):
		_remove_dir(ROOT.path_join(String(name)))
	for file_name in DirAccess.get_files_at(ROOT):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join(String(file_name))))


func _remove_dir(path: String) -> void:
	for name in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(String(name)))
	for file_name in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(String(file_name))))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		print("  FAIL ", label)


func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
