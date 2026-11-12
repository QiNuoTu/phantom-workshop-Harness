extends SceneTree
## 架构解耦自测：图能力代理 / 可更换渲染器 / 节点弹窗插件 / 皮肤贴图。
## 纯 headless，不实例化工作台，因此可以自由停用核心组件再恢复。
## 运行：godot --headless --path . --script res://tests/test_architecture.gd

var failures: Array[String] = []
const GRAPH_DIR := "res://plugins/editor.graph"


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	FxSettings.ensure()
	print("== 架构解耦自测 ==")
	_test_graph_decoupling()
	_test_render_backends()
	_test_node_picker()
	_test_skin_textures()
	_test_package_contract()
	print("----")
	if failures.is_empty():
		print("架构解耦自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


# ---------- 1. 蓝图与解释器核心解耦 ----------

func _test_graph_decoupling() -> void:
	_check(FxGraphFacade.has_provider(), "图能力代理有实现 provider")
	_check(FxGraphFacade.provider_ids().has("core.graph"), "core.graph 贡献了图能力实现")
	var access := FxGraphFacade.access()
	_check(access.catalog_all().size() >= 60, "代理能读到完整节点目录（%d）" % access.catalog_all().size())
	_check(access.catalog_def("image.blur") != null, "代理能按 id 取节点定义")
	_check(access.port_can_connect(access.port_image(), access.port_image()), "端口兼容表经代理可用")
	var manifest := _plugin_manifest("editor.graph")
	var inject: Array = manifest.get("inject", [])
	_check(not inject.has("kernel.graph"), "蓝图清单不再 inject 解释器核心")
	_check(inject.has("graph.facade"), "蓝图只注入基座提供的图能力代理键")
	_check(_source_has_no(GRAPH_DIR, ["FxCatalog", "FxPortType", "FxGraphDoc",
			"FxGraphRunner", "FxRenderService"]), "蓝图源码零解释器核心符号（静态检查）")
	_check(FileAccess.file_exists("res://scripts/graph/kernel/fx_node_def.gd"),
		"节点定义是微内核里的纯数据契约")
	# 目录整理：基座目录里不该再出现图领域实现。
	_check(_source_has_no("res://scripts/graph/kernel", ["FxCatalog", "FxGraphDoc", "FxOpsSubgraph"]),
		"微内核源码零图领域符号（文档语义经 FxGraphAccess 提供）")
	_check(_source_has_no("res://scripts/graph/plugins", ["FxCatalog", "FxGraphDoc"]),
		"插件宿主经代理刷新目录，不直接认识图容器")
	var shell_source := FileAccess.get_file_as_string("res://scripts/graph/ui/fx_shell.gd")
	_check(not shell_source.contains("FxCatalog.") and not shell_source.contains("FxGraphDoc."),
		"外壳不直接调用图容器（一律走 FxGraphFacade）")
	_check(FileAccess.file_exists("res://plugins/core.graph/fx_visual_icon.gd"),
		"节点/插件图标解析住在 core.graph，而不是基座 services")
	# 停用 core.graph：代理撤回实现，但契约仍可安全调用（消费者不会被重建）。
	FxPluginHost.set_enabled("core.graph", false)
	FxGraphFacade.invalidate()
	var empty_access := FxGraphFacade.access()
	_check(empty_access.catalog_all().is_empty(), "核心停用后代理回落到安全空实现")
	_check(empty_access.catalog_def("image.blur") == null, "空实现取定义返回 null 而不是崩")
	_check(empty_access.doc_timeline({}).get("duration", 0.0) == 1.0, "空实现给出安全时间轴")
	FxPluginHost.set_enabled("core.graph", true)
	FxGraphFacade.invalidate()
	FxCatalog.apply_registry()
	_check(FxGraphFacade.access().catalog_all().size() >= 60, "重新启用后图能力完整恢复")


# ---------- 2. 渲染器可更换 ----------

func _test_render_backends() -> void:
	var ids := FxRenderBroker.backend_ids()
	_check(ids.has("cpu.standard") and ids.has("cpu.economy"),
		"两个插件各贡献一个渲染后端（%s）" % str(ids))
	_check(FxRegistry.render_backends.size() >= 2, "后端在可逆账本里注册")
	var owner_standard := ""
	var owner_economy := ""
	for entry in FxRegistry.render_backends:
		if String(entry.get("id", "")) == "cpu.standard":
			owner_standard = String(entry.get("owner", ""))
		elif String(entry.get("id", "")) == "cpu.economy":
			owner_economy = String(entry.get("owner", ""))
	_check(owner_standard == "core.render" and owner_economy == "render.lite",
		"两个后端归属不同插件，可独立停用")
	_check(FxSettings.definition("render.backend").get("owner", "") == "core.render",
		"后端切换是声明式设置项")
	var doc := FxGraphDoc.create("probe")
	FxGraphDoc.add_node(doc, "image.solid")
	FxGraphDoc.set_canvas(doc, 24, 24)
	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	var seen: Array[String] = []
	for backend_id in ids:
		FxSettings.set_value("render.backend", backend_id)
		var result := FxRenderBroker.frame(doc, 0.2,
			FxQualityPolicy.resolve({"playing": false}), runner,
			{"playing": false, "exact": false})
		var stats: Dictionary = result.get("stats", {})
		seen.append(String(stats.get("backend", "")))
	_check(seen == ids, "切换设置后求帧确实走不同后端（%s）" % str(seen))
	# 精确帧不允许经济后端跳帧复用。
	FxSettings.set_value("render.backend", "cpu.economy")
	var exact := FxRenderBroker.frame(doc, 0.2,
		FxQualityPolicy.resolve({"playing": true}), runner,
		{"playing": true, "exact": true})
	_check(not bool((exact.get("stats", {}) as Dictionary).get("skipped", true)),
		"精确帧不跳帧，导出结果不受后端影响")
	# 停用第二个后端：自动回落第一个，不崩。
	FxPluginHost.set_enabled("render.lite", false)
	FxRenderBroker.invalidate()
	FxSettings.set_value("render.backend", "cpu.economy")
	_check(String((FxRenderBroker.frame(doc, 0.2,
			FxQualityPolicy.resolve({"playing": false}), runner,
			{"playing": false, "exact": false}).get("stats", {}) as Dictionary).get("backend", "")) == "cpu.standard",
		"后端插件停用后自动回落到默认实现")
	FxPluginHost.set_enabled("render.lite", true)
	FxSettings.reset("render.backend")
	FxRenderBroker.invalidate()


# ---------- 3. 节点创建弹窗独立插件 ----------

func _test_node_picker() -> void:
	_check(FxNodePickerBroker.has_provider(), "节点选择器代理有 provider")
	_check(FxNodePickerBroker.provider_ids().has("editor.node-picker"),
		"弹窗由独立插件 editor.node-picker 贡献")
	_check(FileAccess.file_exists("res://plugins/editor.node-picker/fx_node_create_dialog.gd"),
		"弹窗实现已移出蓝图插件")
	var picker := FxNodePickerBroker.create(root)
	_check(picker != null and picker is FxNodePicker, "代理返回契约类型")
	_check(String(picker.get_script().resource_path).contains("editor.node-picker"),
		"代理返回的是独立插件里的弹窗实现，不是蓝图内置类")
	# 列表内容属于插件实现细节（在 test_editor_ui 的工作台场景里验证）；
	# 这里只验证插件实现类能安全构造并挂载。
	var probe := FxNodePickerBroker.create(root)
	root.add_child(probe)
	_check(is_instance_valid(probe), "弹窗可入树不崩")
	probe.queue_free()
	picker.queue_free()
	_check(_source_has_no(GRAPH_DIR, ["FxNodeCreateDialog"]),
		"蓝图源码不再硬编码弹窗类（静态检查）")
	FxPluginHost.set_enabled("editor.node-picker", false)
	var fallback := FxNodePickerBroker.create(root)
	_check(fallback != null and fallback is FxNodePicker, "停用插件后代理返回契约空实现")
	_check(fallback.filtered_types().is_empty() and not fallback.port_filter_active(),
		"空实现不会崩，只是不提供候选")
	fallback.queue_free()
	FxPluginHost.set_enabled("editor.node-picker", true)
	_check(FxNodePickerBroker.has_provider(), "重新启用后弹窗贡献恢复")


# ---------- 4. 皮肤贴图与素材映射 ----------

func _test_skin_textures() -> void:
	# 素材归属：所有插件依赖的文件都在插件自己的目录里，项目根不再有 assets/。
	_check(not DirAccess.dir_exists_absolute("res://assets"), "项目根没有 assets/ 目录")
	# 没有「内置插件」这一说：所有插件都走同一条加载路径，实例都由 runtime_plugin 保活。
	var all_equal := true
	for info in FxRegistry.plugin_infos:
		var pid := String(info.get("id", ""))
		var kept := false
		for entry in FxRegistry.ledger:
			if String(entry.get("owner", "")) == pid and String(entry.get("kind", "")) == "runtime_plugin":
				kept = true
				break
		if not kept:
			all_equal = false
			break
	_check(all_equal, "所有插件一视同仁（都保留插件实例）")
	var editor_roots: Array = FxPluginHost.roots()
	_check(editor_roots.size() == 1, "开发期只有一个插件根（%d）" % editor_roots.size())
	_check(DirAccess.dir_exists_absolute("res://plugins/core.asset/assets/handcrafted"),
		"pixelfx 素材在 core.asset 插件目录内")
	_check(DirAccess.dir_exists_absolute("res://plugins/core.text/assets/fonts"),
		"字体在 core.text 插件目录内")
	var entry := _skin_entry("maid-atelier")
	var root := String(entry.get("texture_root", ""))
	var manifest: Dictionary = entry.get("textures", {})
	_check(root == "plugins/skin.maid-atelier/assets", "皮肤声明了外部贴图资源根")
	_check(manifest.size() >= 12, "贴图映射表覆盖 12 个语义素材")
	_check(FxSkinTextureLibrary.available(root, manifest) == manifest.size(),
		"全部贴图都能从资源根解析到（%d/%d）" % [
			FxSkinTextureLibrary.available(root, manifest), manifest.size()])
	var loaded := FxSkinTextureLibrary.load_set(root, manifest)
	_check(loaded.size() == manifest.size(), "WebP/PNG 贴图全部成功加载为 Texture2D")
	_check(FileAccess.file_exists("res://plugins/skin.maid-atelier/assets/preview.webp"),
		"用户指定的 preview.webp 效果图已映射进资源包")
	_check(FileAccess.file_exists("res://plugins/skin.maid-atelier/assets/NOTICE.md")
		and FileAccess.file_exists("res://plugins/skin.maid-atelier/assets/LICENSE-ARTWORK.txt"),
		"完整署名链与 CC BY-NC-SA 许可正文随包提供")
	_check(FileAccess.file_exists("res://plugins/skin.maid-atelier/assets/.gdignore"),
		"贴图目录带 .gdignore，不会打进 PCK（外部可卸载资源）")
	var skin := FxMaidAtelierSkin.new()
	skin.apply_options({"variant": "dark"})
	skin.set_textures(loaded)
	_check(skin.has_textures() and skin.texture("palace_dark") is Texture2D,
		"皮肤拿到暗色宫殿背景贴图")
	_check(skin.texture("maid_left") is Texture2D and skin.texture("maid_right") is Texture2D,
		"双女仆立绘贴图就位")
	_check(skin.texture("top_lace") is Texture2D and skin.texture("crest") is Texture2D,
		"蕾丝与纹章贴图就位")
	_check(skin.texture_layout().size() >= 8, "贴图布局是声明式数据（%d 层）" % skin.texture_layout().size())
	_check(skin.glass_alpha < 1.0, "玻璃透明度开启，贴图能透过面板显现")
	_check(skin.build_decoration() is FxSkinTextureLayer, "背景装饰层使用通用贴图渲染器")
	_check(skin.build_overlay() is FxSkinTextureLayer, "前景装饰层使用通用贴图渲染器")
	# 删掉贴图包（模拟）：自动回落几何装饰。
	skin.set_textures({})
	_check(skin.glass_alpha == 1.0, "无贴图时面板恢复不透明")
	_check(skin.build_overlay() == null, "无贴图时不挂前景装饰")
	_check(skin.build_decoration() != null, "无贴图时回落到自绘几何花边")


func _test_package_contract() -> void:
	var source := FileAccess.get_file_as_string("res://tools/package_windows.gd")
	_check(source.contains("skin.maid-atelier/assets"), "打包脚本会搬运皮肤贴图到便携目录")
	_check(source.contains("CC BY-NC-SA"), "打包说明写明非商业许可与署名要求")


# ---------- helpers ----------

func _skin_entry(skin_id: String) -> Dictionary:
	for item in FxPluginHost.skin_entries():
		var entry: Dictionary = item
		if String(entry.get("id", "")) == skin_id:
			return entry
	return {}


func _plugin_manifest(plugin_id: String) -> Dictionary:
	var path := "res://plugins/%s/plugin.json" % plugin_id
	if not FileAccess.file_exists(path):
		return {}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return raw if raw is Dictionary else {}


func _source_has_no(dir_path: String, forbidden: Array) -> bool:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if name.ends_with(".gd"):
			var source := FileAccess.get_file_as_string(dir_path.path_join(name))
			# 注释里出现类名不算耦合；只检查代码行。
			for line in source.split("\n"):
				var code := line.strip_edges()
				if code.begins_with("#"):
					continue
				for symbol in forbidden:
					if code.contains(String(symbol)):
						return false
		name = dir.get_next()
	dir.list_dir_end()
	return true


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	FxSettings.reset("render.backend")
	FxPluginHost.shutdown()
	quit(code)
