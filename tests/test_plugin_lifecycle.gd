extends SceneTree
## 插件生命周期 / 时空可组合性验收（论文 §3 / §4 / §5.2.1）。
##
## 验证：
##   · 贡献是声明式账本，每次登记都有逆操作；
##   · 停用只撤回该插件自己的贡献，不影响其他插件；
##   · inject / provide 形成反应式依赖图，提供者消失时依赖者自动停用；
##   · 依赖环和缺失提供者可以从声明静态检出，相关插件保持 INACTIVE 而不报错崩溃；
##   · 重新启用后整条链恢复到同一状态（reconciliation 的合流性）。
##
## 运行：godot --headless --path . --script res://tests/test_plugin_lifecycle.gd

var failures: Array[String] = []
var root_dir := "user://lifecycle_plugins"
var root_undo: Callable = Callable()


func _initialize() -> void:
	print("== 插件生命周期 / 可组合性自测 ==")
	_make_plugins()
	root_undo = FxPluginHost.add_scan_root(root_dir, "测试", true)
	FxPluginHost.reload_all()
	_run_tests()
	print("----")
	if failures.is_empty():
		print("插件生命周期自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _make_plugins() -> void:
	DirAccess.make_dir_recursive_absolute(root_dir)
	_make("life.a", [], {"test.a": "1.0"}, 910)
	_make("life.b", ["test.a"], {"test.b": "1.0"}, 911)
	_make("life.c", ["test.b"], {}, 912)
	_make("life.d", ["test.e"], {"test.d": "1.0"}, 913)
	_make("life.e", ["test.d"], {"test.e": "1.0"}, 914)
	_make("life.orphan", ["test.nowhere"], {}, 915)


func _make(id: String, inject: Array, provide: Dictionary, order: int) -> void:
	var dir := root_dir.path_join(id)
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest := {
		"id": id, "name": id, "version": "1.0", "script": "plugin.gd",
		"inject": inject, "provide": provide,
	}
	var j := FileAccess.open(dir.path_join("plugin.json"), FileAccess.WRITE)
	j.store_string(JSON.stringify(manifest, "\t"))
	j.close()
	var source := "extends FxPlugin\n\n" \
		+ "func menus() -> Array[Dictionary]:\n" \
		+ "\treturn [{\"id\": \"" + id + "\", \"title\": \"" + id + "\", \"order\": " + str(order) + "}]\n\n" \
		+ "func commands() -> Array[Dictionary]:\n" \
		+ "\treturn [{\"id\": \"" + id + ".hello\", \"label\": \"hi\", \"handler\": Callable(self, \"hello\")}]\n\n" \
		+ "func hello(_ctx: Dictionary) -> void:\n\tpass\n"
	var s := FileAccess.open(dir.path_join("plugin.gd"), FileAccess.WRITE)
	s.store_string(source)
	s.close()


func _run_tests() -> void:
	_test_resource_roots()
	var report := FxPluginHost.diagnostics()
	_check(FxRegistry.ready, "账本就绪")
	_check(FxPluginHost.is_active("life.a"), "A 无依赖，直接 ACTIVE")
	_check(FxPluginHost.is_active("life.b"), "B 等 A 提供 test.a 后 ACTIVE")
	_check(FxPluginHost.is_active("life.c"), "C 等 B 提供 test.b 后 ACTIVE（级联激活）")
	_check(not FxPluginHost.is_active("life.d") and not FxPluginHost.is_active("life.e"),
		"D/E 互相依赖成环，两者都保持 INACTIVE")
	_check(not FxPluginHost.is_active("life.orphan"), "缺少提供者的插件保持 INACTIVE 且不崩溃")
	_check((report.get("cycles", []) as Array).size() >= 1, "依赖环可从声明静态检出（%d 个）" % (report.get("cycles", []) as Array).size())
	var missing_keys: Array = []
	for item in report.get("missing", []):
		missing_keys.append(String((item as Dictionary).get("key", "")))
	_check(missing_keys.has("test.nowhere"), "缺失依赖被记录：%s" % str(missing_keys))

	# ---- 账本的可逆性 ----
	var before_menus := FxRegistry.menus.size()
	var before_owners := FxRegistry.owners().size()
	var inv := FxRegistry.add("test.transient", "menu", {"id": "transient", "title": "临时", "order": 999})
	_check(FxRegistry.menus.size() == before_menus + 1, "登记贡献立即反映到派生表")
	inv.call()
	_check(FxRegistry.menus.size() == before_menus, "逆操作只撤回这一条贡献")
	_check(FxRegistry.owners().size() == before_owners, "账本恢复原状")

	# ---- 停用 A：级联撤回，其它插件不受影响 ----
	var base_commands := FxRegistry.commands.size()
	var base_builtin := FxRegistry.ops.size()
	_check(FxRegistry.has_owner("life.a"), "A 的贡献在账本里")
	FxPluginHost.set_enabled("life.a", false)
	_check(FxRegistry.has_owner("life.a") == false, "停用 A 后它的贡献全部撤回")
	_check(not FxPluginHost.is_active("life.b"), "A 消失 → B 失去 test.a 自动停用")
	_check(not FxPluginHost.is_active("life.c"), "B 停用 → C 失去 test.b 自动停用（级联）")
	_check(FxRegistry.commands.size() == base_commands - 3, "A/B/C 三条命令一起撤回")
	_check(FxRegistry.ops.size() == base_builtin, "基座其它插件的算子一字未动")
	_check(FxCatalog.has_def("image.glow"), "停用测试插件不影响内置插件节点")

	# ---- 重新启用 A：整条链回到同一状态 ----
	FxPluginHost.set_enabled("life.a", true)
	_check(FxPluginHost.is_active("life.a"), "A 重新 ACTIVE")
	_check(FxPluginHost.is_active("life.b") and FxPluginHost.is_active("life.c"), "B/C 自动重新激活")
	_check(FxRegistry.commands.size() == base_commands, "贡献数量回到起点（合流）")
	_check(FxRegistry.has_owner("life.c"), "C 的贡献重新登记")

	# ---- 单独停用一个叶子插件 ----
	FxPluginHost.set_enabled("life.c", false)
	_check(FxRegistry.has_owner("life.c") == false, "停用叶子插件只撤回自己")
	_check(FxPluginHost.is_active("life.a") and FxPluginHost.is_active("life.b"),
		"提供者不受消费者停用影响")
	FxPluginHost.set_enabled("life.c", true)


func _test_resource_roots() -> void:
	_check(FxResourceRoot.resolve("project.godot") != "", "资源根能解析 res:// 下的原始文件")
	var roots := FxResourceRoot.candidate_roots("plugins/core.asset/assets/handcrafted")
	_check(roots.size() >= 3, "至少覆盖 res:// / exe 同级 / user:// 三个根（实际 %d）" % roots.size())
	_check(FxResourceRoot.existing_roots("plugins/core.asset/assets/handcrafted").size() >= 1, "素材根真实存在")
	var undo_root := FxResourceRoot.register_root("user://__probe_root")
	_check(FxResourceRoot.candidate_roots("x").has("user://__probe_root/x"), "插件可注册自己的素材根")
	undo_root.call()
	_check(not FxResourceRoot.candidate_roots("x").has("user://__probe_root/x"), "注册根返回可逆的逆操作")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	# 清掉测试写进 user://plugins.cfg 的开关，避免污染正式工程。
	FxPluginHost.set_enabled("life.a", true)
	FxPluginHost.set_enabled("life.c", true)
	FxPluginHost.shutdown()
	FxPluginHost.clear_scan_roots()
	_remove_dir(root_dir)
	var cfg := ConfigFile.new()
	cfg.load("user://plugins.cfg")
	for id in ["life.a", "life.b", "life.c", "life.d", "life.e", "life.orphan"]:
		var list: Array = []
		for item in cfg.get_value("plugins", "disabled", []):
			list.append(String(item))
		list.erase(id)
		cfg.set_value("plugins", "disabled", list)
	cfg.save("user://plugins.cfg")
	quit(code)


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		var full := path.path_join(name)
		if dir.current_is_dir():
			_remove_dir(full)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
