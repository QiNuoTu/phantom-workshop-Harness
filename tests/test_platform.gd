extends SceneTree
## 本轮「微内核 + 声明式配置 + 面板布局 + 多语言 + 批量图像/动画插件」综合自测。
## 运行：godot --headless --path . --script res://tests/test_platform.gd

var failures: Array[String] = []
var shell: FxShell
const LAYOUT := "user://layout.cfg"


func _initialize() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LAYOUT))
	print("== 平台能力自测 ==")
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for i in range(8):
		await process_frame
	if shell == null:
		_check(false, "外壳实例化")
		_quit(1)
		return
	_test_settings()
	await _test_panels()
	await _test_skin_artwork()
	_test_microkernel()
	_test_param_ports()
	_test_output_nodes()
	await _test_timeline_ops()
	await _test_graph_editing()
	await _test_drop_import()
	_test_recipe_dialog()
	_test_menu_dedupe()
	await _test_fx_plugins()
	await _test_gpu_backend()
	_test_i18n()
	print("----")
	if failures.is_empty():
		print("平台能力自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


# ---------- 声明式配置 / 能力代理 / 质量策略 ----------

func _test_settings() -> void:
	_check(FxRegistry.settings.size() >= 13, "设置项为插件贡献（%d 项）" % FxRegistry.settings.size())
	var definition := FxSettings.definition("quality.preset")
	_check(String(definition.get("owner", "")) == "core.quality", "设置项带 owner，停用插件即可撤回")
	_check(String(definition.get("applies", "")) == "runtime", "质量设置只改运行时，不重建界面")
	_check(String(FxSettings.definition("general.locale").get("applies", "")) == "ui",
		"语言设置按字段协调为界面重建")
	_check(FxCapabilities.has("quality.preset"), "能力代理注册了质量预设键")
	_check(FxCapabilities.providers("quality.preset").size() >= 1, "能力键有 provider（可多路复用）")
	FxSettings.set_value("quality.preset", "performance")
	_check(int(FxQualitySettings.override().get("quality", -1)) == 0,
		"设置变化经能力代理广播给质量策略 provider")
	var policy := FxQualityPolicy.resolve({"playing": false, "width": 128, "height": 128})
	_check(int(policy.get("quality", -1)) == 0, "质量预设覆盖播放/暂停质量档")
	_check(not bool(policy.get("output_downscale", true)), "输出链永不降采样是不变量，插件无法覆盖")
	_check(FxQualityPolicy.provider_count() >= 1, "质量策略由插件 provider 提供")
	_check(FxSettings.coerce({"kind": "int", "min": 1, "max": 8}, 99) == 8,
		"设置值按声明夹取")
	_check(not FxRegistry.window("settings.window").is_empty(), "设置中心注册了浮动窗口")
	var opened := shell.run_command("settings.open")
	_check(opened and shell.window_layer.has("settings.window"), "命令可打开设置中心")
	_check(FxRenderBroker.backend_ids().size() >= 2, "渲染后端由插件贡献（%d 个）" % FxRenderBroker.backend_ids().size())
	_check(not FxSettings.definition("render.backend").is_empty(), "后端切换暴露为设置项")
	_check(FxRenderBroker.current_label() != "", "代理能报告当前后端")
	_check(FxUiKit.chrome_style("menu") != null and FxUiKit.chrome_style("dock_bar") != null,
		"菜单条 / 停靠标签条样式由皮肤提供（可换成贴图）")
	_check(FxUiKit.skin().corner_radius <= 4, "默认皮肤是紧凑的 Qt 风格圆角")
	# 画布属性对外公开：读、写、以及「画布信息」节点。
	var doc: Dictionary = shell.get("store").doc
	var before: Vector2i = FxGraphFacade.access().doc_canvas(doc)
	_check(before.x > 0 and before.y > 0, "画布宽高可读（%d×%d）" % [before.x, before.y])
	FxGraphFacade.access().set_doc_canvas(doc, Vector2i(200, 120))
	_check(FxGraphFacade.access().doc_canvas(doc) == Vector2i(200, 120), "画布宽高可写")
	FxGraphFacade.access().set_doc_canvas(doc, before)
	_check(FxCatalog.def("graph.canvas") != null, "画布信息节点已注册")
	# 外部纹理导入：文件 → Image → 节点输出。
	var tex_path := "plugins/skin.maid-atelier/assets/crest.webp"
	var tex := FxTextureLibrary.image(tex_path)
	_check(tex != null and tex.get_width() > 0, "外部纹理可从插件目录读入")
	var frame := FxTextureLibrary.sheet_frame(tex, 2, 2, 1)
	_check(frame != null and frame.get_width() == tex.get_width() / 2, "图集可按行列切片")
	var def := FxCatalog.def("image.texture")
	var op := FxOpRegistry.get_op(StringName(def.op))
	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(48, 48)
	var out: Dictionary = op.call(ctx, {}, def, {}, {"path": tex_path, "fit": "contain"})
	var out_image: Image = out.get("image")
	_check(out_image != null and out_image.get_size() == Vector2i(48, 48), "纹理节点输出图像")
	FxSettings.reset("quality.preset")


# ---------- 面板分离 / 自由布局 / 注入功能 ----------

func _test_panels() -> void:
	var exposed := shell.exposed_panels()
	_check(exposed.size() >= 5, "所有面板（插件与内置）统一暴露（%d 个）" % exposed.size())
	var all_have_features := true
	for entry in exposed:
		if (entry.get("features", []) as Array).is_empty():
			all_have_features = false
	_check(all_have_features, "每个面板都能消费通配注入功能")
	_check(FxPanelBroker.panel_ids().size() == exposed.size(), "面板代理与注册表一致")
	var features := FxPanelBroker.all_features()
	_check(features.size() >= 2, "插件注入了面板功能（%d 项）" % features.size())
	var feature_labels: Array[String] = []
	for item in features:
		feature_labels.append(String((item as Dictionary).get("label", "")))
	_check(feature_labels.has("插件中心…"), "面板菜单里有插件中心入口")
	_check(feature_labels.has("轮换质量预设"), "面板菜单里能轮换质量预设")
	var target := String(exposed[0].get("id", ""))
	_check(not target.is_empty(), "面板 id 可取")
	var original: Control = shell.panel(target)
	shell.detach_panel(target)
	await process_frame
	_check(shell.is_panel_detached(target), "面板可分离为浮动窗口")
	_check(shell.window_layer.has("panel:" + target), "分离后进入窗口层")
	_check(shell.panel(target) == original, "分离不重建面板实例（画布状态保留）")
	_check(original.visible, "分离后的面板可见")
	var floating: FxPluginWindow = shell.window_layer.window("panel:" + target)
	_check(floating != null and floating.geometry().size.x >= 320.0, "浮动窗口可自由定位/缩放")
	shell.redock_panel(target)
	await process_frame
	_check(not shell.is_panel_detached(target), "可重新停靠")
	_check(shell.panel(target) == original, "重新停靠后仍是同一个 Control")
	_check(not FxRegistry.window("plugin.hub.window").is_empty(), "插件中心有独立浮动窗口")
	_check(not FxRegistry.panel("plugin.hub").is_empty(), "插件中心有独立面板")
	_check(FxRegistry.plugin_info("fx.vfx").get("icon", "") != "", "插件清单可声明图标")
	_check(not FxRegistry.settings_of("core.quality").is_empty(), "插件自己的设置项可被插件中心查询")
	shell.run_command("plugins.hub.open")
	_check(shell.window_layer.has("plugin.hub.window"), "插件中心窗口可打开")
	var hub_window: FxPluginWindow = shell.window_layer.window("plugin.hub.window")
	var hub = hub_window.get("content")
	_check(hub is FxPluginHub, "插件中心窗口内容就是插件中心面板")
	var handles := 0
	for child in hub_window.get_children():
		if child is Control and (child as Control).mouse_default_cursor_shape != Control.CURSOR_ARROW:
			handles += 1
	_check(handles >= 8, "浮动窗口有八向缩放边条（%d 条）" % handles)
	hub_window.toggle_maximize()
	_check(hub_window.is_maximized(), "双击标题 / 按钮可最大化窗口")
	hub_window.toggle_maximize()
	_check(not hub_window.is_maximized(), "再次切换可还原")
	hub.size = Vector2(400, 620)
	hub.call("_on_resized")
	_check(bool(hub.get("_narrow")), "窄面板自动退化为单栏")
	hub.call("select", "skin.maid-atelier")
	_check(bool(hub.get("_show_detail")), "窄面板选中插件后进入详情")
	_check(not (hub.get("_side") as Control).visible, "窄面板详情态隐藏列表")
	hub.size = Vector2(900, 620)
	hub.call("_on_resized")
	_check(not bool(hub.get("_narrow")), "变宽后恢复左右分栏")
	_check((hub.get("_side") as Control).visible and (hub.get("_detail") as Control).visible,
		"宽面板同时显示详情与列表")
	shell.close_window("plugin.hub.window")



# ---------- 皮肤贴图（外部资源根） ----------

func _test_skin_artwork() -> void:
	shell.apply_skin("maid-atelier")
	await process_frame
	var skin := FxUiKit.skin()
	_check(skin.has_textures(), "工作台当前皮肤已加载外部贴图包")
	_check(skin.texture_layout().size() >= 8, "贴图布局在工作台生效")
	_check(skin.glass_alpha < 1.0, "玻璃面板开启，贴图能透出")
	_check(is_instance_valid(shell.get("_overlay") as Control), "前景装饰层已挂载")
	_check(is_instance_valid(shell.get("_decoration") as Control), "背景装饰层已挂载")
	shell.apply_skin("default")
	await process_frame
	_check(not FxUiKit.skin().has_textures(), "切回默认皮肤后不加载贴图")


# ---------- 微内核 ----------

func _test_microkernel() -> void:
	_check(not DirAccess.dir_exists_absolute("res://scripts/graph/core"), "graph/core 已从微内核移除")
	_check(FileAccess.file_exists("res://plugins/core.graph/fx_catalog.gd"), "图领域词汇归属 core.graph 组件")
	_check(FileAccess.file_exists("res://plugins/core.render/fx_render_service.gd"), "渲染服务归属 core.render 组件")
	_check(FxPluginHost.is_active("core.graph") and FxPluginHost.is_active("core.render"),
		"两个核心组件按依赖顺序激活")
	_check(shell.render != null and shell.render.store == shell.store,
		"外壳从 services 表取得渲染服务并完成装配")
	_check(shell.services.has("render"), "render 是插件贡献的 service 而非外壳硬编码")
	_check((FxPluginHost.diagnostics().get("missing", []) as Array).is_empty(),
		"微内核拆分后没有缺失的供给键")
	_check(FxPluginHost.dependency_report().get("active", []).size() >= 30,
		"依赖图无环且组件全部激活")


# ---------- 批量图像 / 特效 / 动画插件 ----------

## GPU 渲染服务器（第一阶段）：设备探测、后端切换、无 GPU 时安全回落。
func _test_gpu_backend() -> void:
	print("== GPU 渲染服务器 ==")
	var info := FxGpuDevice.info()
	_check(info.has("available") and info.has("name"), "设备探测返回适配器信息")
	_check((FxGpuBackend.new() as FxRenderBackend).thread_safe() == true,
		"GPU 后端求帧可上工作线程（GPU 资源只在 postprocess 里碰）")
	var probe_image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	probe_image.fill(Color(0.5, 0.25, 0.75, 1.0))
	_check((FxGpuBackend.new() as FxRenderBackend).postprocess(probe_image, {}) == probe_image,
		"无图形设备时 GPU 发布通道原样返回，不黑屏")
	_check(FxRenderBroker.backend_ids().has("gpu.standard"), "渲染代理里注册了 GPU 后端")
	_check(FxGpuDevice.state_text().begins_with("GPU"), "设备状态能拼成一句话（%s）" % FxGpuDevice.state_text())
	# Phase 1：GPU 算子覆盖是条件式的，无头/CPU 后端下必须等同 CPU 实现。
	_check(not FxGpuOps.active(), "无头环境 GPU 算子自行停用（回落 CPU）")
	_check(not FxGpuCompute.available(), "无头环境没有可用的 compute 设备")
	_check(FxOpRegistry.get_op(&"image.blur") == FxGpuOps.blur,
		"render.gpu 覆盖了 image.blur（依赖 image 插件，加载顺序保证后者先注册）")
	_check(FxOpRegistry.get_op(&"image.mix") == FxGpuOps.mix, "render.gpu 覆盖了 image.mix")
	FxPluginHost.set_enabled("render.gpu", false)
	_check(FxOpRegistry.get_op(&"image.blur") != FxGpuOps.blur, "停用 GPU 插件后 blur 恢复 CPU 实现")
	FxPluginHost.set_enabled("render.gpu", true)
	_check(FxOpRegistry.get_op(&"image.blur") == FxGpuOps.blur, "重新启用后 GPU 算子自动恢复")
	var previous := String(FxSettings.value("render.backend"))
	FxSettings.set_value("render.backend", "gpu.standard")
	FxRenderBroker.invalidate()
	var render: FxRenderService = shell.service("render")
	render.request_render()
	# 等的是「新后端画的这一帧」：last_image 可能还是切之前那张。
	for i in range(240):
		await process_frame
		if String(render.last_stats().get("backend", "")) == "gpu.standard":
			break
	_check(render.last_image() != null, "切到 GPU 后端仍然出图")
	var stats: Dictionary = render.last_stats()
	_check(String(stats.get("backend", "")) == "gpu.standard", "统计里报告 GPU 后端（%s）" % String(stats.get("backend", "")))
	_check(String(stats.get("gpu", "")).begins_with("GPU"), "统计里带设备状态（%s）" % String(stats.get("gpu", "")))
	if not FxGpuDevice.available():
		_check(bool(stats.get("gpu_used", true)) == false, "无图形设备时不吃 GPU 通道，保持 CPU 结果")
	_check(FxRenderApi.clear_cache() >= 0, "GPU 后端下清理缓存也安全")
	FxSettings.set_value("render.backend", previous)
	FxRenderBroker.invalidate()
	render.request_render()
	for i in range(60):
		await process_frame


func _test_fx_plugins() -> void:
	var ids: Array[String] = ["fx.generators", "fx.color", "fx.distort", "fx.vfx",
		"fx.composite", "anim.curves", "anim.motion"]
	for pid in ids:
		_check(FxPluginHost.is_active(pid), "插件 %s 激活" % pid)
	_check(FxCatalog.all().size() >= 60, "节点总数 ≥ 60（%d）" % FxCatalog.all().size())
	_check(FxOpRegistry.ids().size() >= 60, "算子总数 ≥ 60（%d）" % FxOpRegistry.ids().size())
	_check(FxRegistry.time_ops.has("anim.ease") and FxRegistry.time_ops.has("image.flame"),
		"时间相关算子已声明，跨帧缓存会关闭")
	var tested := 0
	var bad: Array[String] = []
	for def in FxCatalog.all():
		var op_id := String(def.op)
		if not (op_id.begins_with("image.") or op_id.begins_with("anim.")):
			continue
		var callable := FxOpRegistry.get_op(StringName(op_id))
		if not callable.is_valid():
			bad.append(op_id + " 无算子")
			continue
		var params: Dictionary = {}
		for p in def.params:
			params[String(p.get("id", ""))] = p.get("default")
		var ctx := FxEvalContext.new()
		ctx.canvas = Vector2i(32, 32)
		ctx.t = 0.37
		ctx.operator_quality = 1.0
		var inputs: Dictionary = {}
		for port in def.inputs:
			var key := String(port.get("id", ""))
			if String(port.get("type", "")) == "image":
				inputs[key] = FxImageUtil.new_canvas(Vector2i(32, 32), Color(0.3, 0.5, 0.9, 0.9))
			elif String(port.get("type", "")) == "vec2":
				inputs[key] = Vector2(0.5, 0.5)
			else:
				inputs[key] = 0.5
		var result: Variant = callable.call(ctx, {}, def, inputs, params)
		if not result is Dictionary:
			bad.append(op_id + " 返回值非法")
			continue
		var expected := "image"
		if not def.outputs.is_empty():
			expected = String(def.outputs[0].get("id", "image"))
		if not (result as Dictionary).has(expected):
			bad.append(op_id + " 缺输出 " + expected)
			continue
		tested += 1
	_check(bad.is_empty(), "全部 %d 个图像/动画算子可独立执行（%s）" % [tested, str(bad)])
	# 动画节点必须真的随时间变化。
	var anim_ctx := FxEvalContext.new()
	anim_ctx.canvas = Vector2i(32, 32)
	var anim_def := FxCatalog.def("anim.oscillator")
	var anim_op := FxOpRegistry.get_op(&"anim.oscillator")
	var anim_params: Dictionary = {}
	for p2 in anim_def.params:
		anim_params[String(p2.get("id", ""))] = p2.get("default")
	anim_ctx.t = 0.0
	var v0: float = float((anim_op.call(anim_ctx, {}, anim_def, {}, anim_params) as Dictionary)["value"])
	anim_ctx.t = 0.25
	var v1: float = float((anim_op.call(anim_ctx, {}, anim_def, {}, anim_params) as Dictionary)["value"])
	_check(not is_equal_approx(v0, v1), "动画算子随时间变化")
	# 稀疏绘制套件。
	var blobs: Array[Dictionary] = [{"x": 16.0, "y": 16.0, "radius": 6.0,
		"color": Color.WHITE, "strength": 1.0}]
	var painted := FxPixelKitBlobs.paint(Vector2i(32, 32), Color(0, 0, 0, 0), blobs)
	_check(painted.get_pixel(16, 16).a > 0.2, "稀疏绘制套件只遍历包围盒且能出图")
	# 停用单个插件：只撤回它自己的节点/算子，其它插件不动。
	var before := FxCatalog.all().size()
	FxPluginHost.set_enabled("fx.color", false)
	await process_frame
	_check(not FxPluginHost.is_active("fx.color"), "停用 fx.color 后组件失活")
	_check(FxCatalog.all().size() == before - 5, "只撤回本插件的 5 个节点")
	_check(FxPluginHost.is_active("fx.generators"), "其它图像插件不受影响")
	FxPluginHost.set_enabled("fx.color", true)
	await process_frame
	_check(FxPluginHost.is_active("fx.color") and FxCatalog.all().size() == before,
		"重新启用后贡献完整恢复")


# ---------- 多语言 ----------

# ---------- 参数端口通用化 ----------

func _test_param_ports() -> void:
	# 每个参数默认都有输入端口：数值、字符串、枚举、颜色、纹理路径都算。
	var text_def := FxCatalog.def("image.text")
	var text_ports: Array = FxCatalog.ports(text_def, {}).get("inputs", [])
	var ids: Dictionary = {}
	for p in text_ports:
		ids[String((p as Dictionary).get("id", ""))] = true
	_check(ids.has("text") and ids.has("font") and ids.has("align"),
		"文字节点的文本 / 字体 / 对齐都能连线")
	var pix_def := FxCatalog.def("image.pixelfx")
	var pix_ids: Dictionary = {}
	for p in FxCatalog.ports(pix_def, {}).get("inputs", []):
		pix_ids[String((p as Dictionary).get("id", ""))] = true
	_check(pix_ids.has("asset") and pix_ids.has("fps") and pix_ids.has("palette"),
		"素材库节点的素材 / 帧率 / 调色都能连线")
	# 结构性参数（页数、层数）不长端口：它们决定端口表本身。
	var seq_def := FxCatalog.def("flow.sequence")
	var seq_ids: Dictionary = {}
	for p in FxCatalog.ports(seq_def, FxCatalog.default_params(seq_def)).get("inputs", []):
		seq_ids[String((p as Dictionary).get("id", ""))] = true
	_check(not seq_ids.has("steps"), "结构性参数（序列出口数）不生成端口")
	_check(FxCatalog.param_port_type({"kind": "layers"}) == &"",
		"图层数组不生成端口")

	# 连线后真的会覆盖参数：条纹频率被数值节点的 2 覆盖，画面应当变化。
	var plain := _stripes_doc(false)
	var bound := _stripes_doc(true)
	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	var a: Image = runner.run(plain, 0.0).get("image")
	var b: Image = runner.run(bound, 0.0).get("image")
	_check(a != null and b != null and a.get_data() != b.get_data(),
		"参数端口连线后执行器按端口覆盖参数")


func _stripes_doc(with_edge: bool) -> Dictionary:
	var doc := FxGraphDoc.create("ports")
	FxGraphDoc.set_canvas(doc, 32, 32)
	FxGraphDoc.add_node(doc, "image.stripes", "src", Vector2.ZERO, {})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(300, 0), {})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "src", "image", "out", "background")
	if with_edge:
		FxGraphDoc.add_node(doc, "math.number", "num", Vector2(0, 200), {"a": 2.0})
		FxGraphDoc.connect_ports(doc, "num", "number", "src", "frequency")
	return doc


# ---------- 输出端口 / 输出预览节点 ----------

func _test_output_nodes() -> void:
	var final_def := FxCatalog.def("output.final")
	_check(final_def.outputs.size() == 1, "最终输出节点有图像输出口")
	var preview_def := FxCatalog.def("output.preview")
	_check(preview_def != null and preview_def.evaluate_always,
		"输出预览节点是每帧求值的汇点")
	var doc := FxGraphDoc.create("preview")
	FxGraphDoc.set_canvas(doc, 24, 24)
	FxGraphDoc.add_node(doc, "image.solid", "src", Vector2.ZERO, {})
	FxGraphDoc.add_node(doc, "output.preview", "prev", Vector2(200, 0), {})
	FxGraphDoc.connect_ports(doc, "src", "image", "prev", "image")
	var runner := FxGraphRunner.new()
	runner.capture_previews = true
	runner.preview_nodes.clear()
	var result := runner.run(doc, 0.0)
	var previews: Dictionary = result.get("previews", {})
	_check(previews.has("prev"), "旁支的输出预览节点也会被求值并出预览")
	var timeline := FxCatalog.def("graph.timeline")
	_check(timeline != null and timeline.outputs.size() >= 6,
		"时间轴信息节点暴露帧率 / 帧数 / 时间 / 帧序号")
	var canvas_node := FxCatalog.def("graph.canvas")
	_check(canvas_node != null, "画布信息节点存在")


# ---------- 轨道：复制 / 粘贴 / 帧率 ----------

func _test_timeline_ops() -> void:
	var store: FxDocumentStore = shell.get("store")
	store.attach(FxGraphDoc.create("timeline"))
	FxGraphDoc.set_canvas(store.doc, 32, 32)
	FxGraphDoc.add_node(store.doc, "image.blur", "b1", Vector2.ZERO, {
		"radius": {"track": [[0.0, 1.0], [0.5, 4.0]], "interp": "linear"},
	})
	store.notify(["doc"])
	await process_frame

	var panel := FxTimelinePanel.new()
	panel.shell = shell
	root.add_child(panel)
	panel.setup(store)
	await process_frame
	_check(panel.find_track("b1", "radius") >= 0, "轨道面板能看到关键帧")

	panel._select_all_keys()
	panel._copy_keys()
	_check(panel._clipboard.size() == 2, "复制选中关键帧（%d）" % panel._clipboard.size())
	store.set_time(0.75)
	panel._paste_keys()
	await process_frame
	var raw: Variant = FxCatalog.value_at(store.doc["nodes"][0].get("params", {}), "radius")
	var keys: Array = (raw as Dictionary).get("track", []) if raw is Dictionary else []
	_check(keys.size() == 4, "粘贴后轨道有 4 帧（%d）" % keys.size())
	var has_75 := false
	for entry in keys:
		if entry is Array and absf(float((entry as Array)[0]) - 0.75) < 0.001:
			has_75 = true
	_check(has_75, "粘贴落位在播放头")

	# 帧率 / 帧数直接写文档时间轴
	store.set_timeline(24, 48.0 / 24.0, true)
	await process_frame
	var timeline := FxGraphDoc.timeline(store.doc)
	_check(int(timeline.get("fps", 0)) == 24, "帧率可写（24）")
	_check(absf(float(timeline.get("duration", 0.0)) - 2.0) < 0.001, "帧数换算成时长（2s）")
	panel.queue_free()


# ---------- 蓝图：折叠 / 图层打帧 / 尺寸 / 复制粘贴 ----------

func _visible_children(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if child is Control and (child as Control).visible:
			count += 1
	return count


func _test_graph_editing() -> void:
	var store: FxDocumentStore = shell.get("store")
	store.attach(FxGraphDoc.create("editing"))
	FxGraphDoc.set_canvas(store.doc, 32, 32)
	store.add_node("image.blur", "b1", Vector2.ZERO, {})
	store.add_node("output.final", "out", Vector2(320, 0), {})
	store.set_output("out")
	for i in range(3):
		await process_frame
	var editor: FxGraphEditor = shell.call("panel", "editor.graph")
	_check(editor != null, "蓝图面板可用")
	if editor == null:
		return
	var view: FxGraphNodeView = editor.node_views.get("b1")
	_check(view != null, "节点视图已创建")
	if view == null:
		return

	# 加载后默认收起预览；展开再折叠，检查只少预览这一行且高度跟着收
	_check(view.collapsed and not view._preview.visible, "加载后预览默认收起")
	_check(view.size.y < 200.0, "默认收起的节点已经压矮（%.0f）" % view.size.y)
	view.call("set_collapsed", false)
	view.call("_refit_size")
	await process_frame
	await process_frame
	var rows_before := _visible_children(view)
	var height_before := view.size.y
	view.call("_toggle_collapse")
	_check(view.collapsed and not view._preview.visible, "折叠后预览不可见")
	_check(_visible_children(view) == rows_before - 1, "折叠只少了预览这一行（%d → %d）" %
		[rows_before, _visible_children(view)])
	_check(view.params_ui != null and view.params_ui.placed_rows.size() > 0,
		"参数行全部保留，端口不受影响")
	for i in range(2):
		await process_frame
	_check(view.size.y < height_before - 40.0, "折叠后节点高度收回去（%.0f → %.0f）" %
		[height_before, view.size.y])
	view.call("_toggle_collapse")
	await process_frame
	await process_frame
	_check(_visible_children(view) == rows_before, "再点一次恢复预览")
	_check(view.size.y > height_before - 60.0, "展开后高度长回来（%.0f）" % view.size.y)

	# 拖右下角改尺寸
	_check(view.resizable, "带预览的节点可拖右下角改尺寸")
	view.call("_on_resize_request", Vector2(420, 320))
	_check(view.size.y >= 300.0, "拖拽后节点变高（%.0f）" % view.size.y)
	_check(editor._node_sizes.has("b1"), "节点尺寸被记住，重建后恢复")

	# 参数控件要读「当前」文档对象：撤销/外部替换后不能抱着旧快照不放
	var original := FxGraphFacade.access().doc_node(store.doc, "b1")
	var replacement := original.duplicate(true)
	(replacement.get("params", {}) as Dictionary)["radius"] = 7.0
	var all_nodes: Array = store.doc.get("nodes", [])
	for i in range(all_nodes.size()):
		if String((all_nodes[i] as Dictionary).get("id", "")) == "b1":
			all_nodes[i] = replacement
			break
	editor.call("_refresh_param_views", ["node:b1"])
	_check(float(view.params_ui.call("_display_value", "radius")) == 7.0,
		"参数控件读到替换后的当前数据（不是旧快照）")
	_check(view.node_data == replacement, "节点视图的数据引用同步更新")

	# 输出节点的图层可以打关键帧
	var out_view: FxGraphNodeView = editor.node_views.get("out")
	_check(out_view != null and out_view.params_ui != null, "输出节点有图层参数行")
	if out_view != null and out_view.params_ui != null:
		out_view.params_ui.call("_toggle_layer_track", 0)
		await process_frame
		var node_data := FxGraphDoc.node(store.doc, "out")
		var layers: Array = (node_data.get("params", {}) as Dictionary).get("layers", [])
		var layer: Dictionary = layers[0] if layers.size() > 0 else {}
		_check(layer.get("opacity") is Dictionary and (layer.get("opacity") as Dictionary).has("track"),
			"图层透明度可以打关键帧")
		_check(layer.get("offset") is Dictionary and (layer.get("offset") as Dictionary).has("track"),
			"图层位移可以打关键帧")
		_check(layer.get("visible") is Dictionary, "图层显隐可以打关键帧")
		out_view.params_ui.call("_toggle_layer_track", 0)
		await process_frame
		node_data = FxGraphDoc.node(store.doc, "out")
		layers = (node_data.get("params", {}) as Dictionary).get("layers", [])
		layer = layers[0] if layers.size() > 0 else {}
		_check(not (layer.get("opacity") is Dictionary), "同位置再点一次删掉该帧，回到静态值")

	# 批量复制 / 粘贴 / 剪切：包是自描述 JSON，带内部连线，可贴到别的图或外部文本
	store.connect_ports("b1", "image", "out", "layer_0")
	await process_frame
	var before_count: int = (store.doc.get("nodes", []) as Array).size()
	var before_edges: int = (store.doc.get("edges", []) as Array).size()
	editor.call("_select_many", ["b1", "out"])
	await process_frame
	var payload: Dictionary = editor.build_clip_payload(["b1", "out"])
	_check((payload.get("nodes", []) as Array).size() == 2, "剪贴板包里有 2 个节点")
	_check((payload.get("edges", []) as Array).size() == 1, "包内保留两个节点之间的连线")
	_check(String(payload.get("schema", "")) == "phantom.graph.clipboard", "包带格式标记（外部可识别）")
	var roundtrip := FxGraphEditor.parse_clip_text(JSON.stringify(payload, "  "))
	_check((roundtrip.get("nodes", []) as Array).size() == 2, "包能原样解析回来（贴到外部再贴回来）")
	_check(FxGraphEditor.parse_clip_text("随便一段话").is_empty(), "不是蓝图包的文本被忽略")

	editor.call("_copy_selection")
	await process_frame
	editor.call("_paste_clipboard")
	for i in range(4):
		await process_frame
	_check((store.doc.get("nodes", []) as Array).size() == before_count + 2, "粘贴一次新增 2 个节点")
	_check((store.doc.get("edges", []) as Array).size() == before_edges + 1, "内部连线一起被粘贴")
	var pasted := FxGraphDoc.node(store.doc, store.selected_id)
	_check(not pasted.is_empty() and String(pasted.get("type", "")) == "image.blur",
		"粘贴保留节点类型并自动选中新节点")
	_check(not String(pasted.get("id", "")).is_empty() and String(pasted.get("id", "")) != "b1",
		"粘贴用的是新 id")
	var new_edge_ok := false
	for item in store.doc.get("edges", []):
		var edge: Dictionary = item
		if String(edge.get("from", "")) != "b1" and String(edge.get("from_port", "")) == "image":
			new_edge_ok = true
	_check(new_edge_ok, "连线指向新节点而不是原节点")
	# 粘贴后必须是「新的一批」被选中：不能退回上一次那批里的第一个，也不能两批一起亮。
	var selected_now: Dictionary = editor.get("_selection")
	_check(selected_now.size() == 2, "粘贴后整批 2 个节点都被选中（实际 %d）" % selected_now.size())
	_check(not selected_now.has("b1") and not selected_now.has("out"),
		"粘贴后旧的源节点不再处于选中态")
	var stray := 0
	for key in editor.node_views.keys():
		var v: FxGraphNodeView = editor.node_views[key]
		if v.selected and not selected_now.has(String(key)):
			stray += 1
	_check(stray == 0, "视图里没有残留的旧选中（%d 个）" % stray)
	_check(selected_now.has(store.selected_id), "主选中项属于新粘贴的这一批")

	# 剪切：多选一起删
	editor.call("_select_many", ["b1", "out"])
	await process_frame
	editor.call("_cut_selection")
	for i in range(4):
		await process_frame
	_check(FxGraphDoc.node(store.doc, "b1").is_empty() and FxGraphDoc.node(store.doc, "out").is_empty(),
		"剪切一次移除全部选中节点")


# ---------- 拖拽导入 / 精灵表 ----------

func _test_drop_import() -> void:
	_check(FxDropBroker.entries().size() > 0, "拖拽导入有 provider")
	_check(FxDropBroker.provider_ids().has("editor.dropimport.image"), "provider 是拖拽导入插件")
	_check(FxDropBroker.can_handle(["a.png"]), "PNG 能被接住")
	_check(not FxDropBroker.can_handle(["a.txt"]), "非图片文件不会被误拦")
	_check(FxDropImport.is_supported("x.WEBP"), "扩展名判大小写无关")

	# 造一张 64×32 的两帧精灵表
	var sheet := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(1, 0, 0, 1))
	var sheet_path := "user://drop_sheet.png"
	var err := sheet.save_png(sheet_path)
	_check(err == OK, "测试用的精灵表写盘成功")
	if err != OK:
		return
	_check(FxDropImport.guess_grid(sheet_path) == Vector2i(2, 1), "64×32 的图被猜成 2×1 帧")

	var store: FxDocumentStore = shell.get("store")
	store.attach(FxGraphDoc.create("drop"))
	store.add_node("output.final", "out", Vector2(480, 0), {})
	await process_frame
	var result := FxDropImport.handle({
		"files": [sheet_path], "position": Vector2(120, 80), "store": store, "shell": shell,
	})
	_check(int(result.get("count", 0)) == 1, "拖入图片落成一个节点")
	var dropped: Dictionary = {}
	for item in store.doc.get("nodes", []):
		if String((item as Dictionary).get("type", "")) == "image.texture":
			dropped = item
	_check(not dropped.is_empty(), "默认建的是纹理节点")
	_check(String((dropped.get("params", {}) as Dictionary).get("path", "")) == sheet_path,
		"节点记住拖入的文件路径")
	var sheet_node := FxDropImport._make_node(store, sheet_path, Vector2(300, 200), true)
	var sheet_params: Dictionary = sheet_node.get("params", {})
	_check(String(sheet_params.get("mode", "")) == "grid" and int(sheet_params.get("columns", 0)) == 2,
		"Shift 拖入建的是 2×1 精灵表节点")
	var editor: FxGraphEditor = shell.panel("editor.graph")
	await process_frame
	_check(editor != null and editor.get_window().files_dropped.is_connected(
		Callable(editor, "_on_files_dropped")), "画布已接上系统文件拖放")

	# 精灵表节点：网格切法与输出参数
	var grid := FxTextureLibrary.grid_of(Vector2i(64, 32), "grid", 2, 1, Vector2i.ZERO, 0, 0)
	_check(int(grid.get("count", 0)) == 2 and (grid.get("cell", Vector2i.ZERO) as Vector2i) == Vector2i(32, 32),
		"按 2×1 切：2 帧、单元 32×32")
	var by_size := FxTextureLibrary.grid_of(Vector2i(64, 32), "size", 4, 1, Vector2i(32, 32), 0, 0)
	_check(int(by_size.get("cols", 0)) == 2 and int(by_size.get("rows", 0)) == 1,
		"按单元尺寸切时列行由图片算出（2×1）")
	var padded := FxTextureLibrary.grid_of(Vector2i(70, 66), "grid", 2, 2, Vector2i.ZERO, 1, 2)
	_check((padded.get("cell", Vector2i.ZERO) as Vector2i) == Vector2i(33, 31),
		"留白与间隔会从单元里扣掉（33×31）")

	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(64, 32)
	ctx.t = 0.0
	var params := {"path": sheet_path, "mode": "grid", "columns": 2, "rows": 1, "frame": 1,
		"fps": 0.0, "loop": true, "fit": "native", "scale": 1.0, "offset": [0, 0], "alpha": 1.0}
	var out := FxOpsTexture.sheet(ctx, {}, null, {}, params)
	_check(int(out.get("count", 0)) == 2, "精灵表输出总帧数（2）")
	_check(int(out.get("index", -1)) == 1, "精灵表输出当前帧号（1）")
	_check((out.get("cell", Vector2.ZERO) as Vector2) == Vector2(32, 32), "精灵表输出单元尺寸")
	_check(int(out.get("cols", 0)) == 2 and int(out.get("rows", 0)) == 1, "精灵表输出列行数")
	_check(out.get("image") is Image, "精灵表输出图像")

	# fps > 0 时按时间推进帧号
	ctx.t = 0.15
	var timed := FxOpsTexture.sheet(ctx, {}, null, {}, {
		"path": sheet_path, "mode": "grid", "columns": 2, "rows": 1, "frame": 0,
		"fps": 10.0, "loop": true, "fit": "native", "scale": 1.0, "offset": [0, 0], "alpha": 1.0,
	})
	_check(int(timed.get("index", -1)) == 1, "10fps 下 0.15s 播到第 1 帧")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(sheet_path))


# ---------- 配方面板：坏 JSON 不清空 ----------

func _test_recipe_dialog() -> void:
	var dialog := FxRecipeDialog.new()
	root.add_child(dialog)
	dialog.setup('{"name":"测试","width":64,"height":64,"layers":[{"type":"flash"}]}')
	_check(dialog._parsed_ok, "合法配方解析成功")
	dialog._text.text = '{"name": "测试", "layers": ['
	dialog._on_text_changed()
	_check(not dialog._parsed_ok, "半截 JSON 被判定为未成形")
	_check(String((dialog._recipe as Dictionary).get("name", "")) == "测试",
		"解析失败保留上一次有效配方，不把表单清空")
	_check(dialog._parse_error.contains("行"), "错误信息带行号（%s）" % dialog._parse_error)
	dialog._text.text = '{"name":"改好了","width":32,"height":32,"layers":[{"type":"cycle"}]}'
	dialog._on_text_changed()
	_check(dialog._parsed_ok and String(dialog._recipe.get("name", "")) == "改好了",
		"修好 JSON 后恢复解析")
	dialog.queue_free()


# ---------- 菜单去重 ----------

func _test_menu_dedupe() -> void:
	var hub_items := 0
	for item in FxPluginHost.menu_item_entries():
		var entry: Dictionary = item
		if String(entry.get("menu", "")) == "plugins" \
				and String(entry.get("command", "")) == "plugins.hub.open":
			hub_items += 1
	_check(hub_items == 1, "插件菜单里只有一条插件中心入口（%d）" % hub_items)
	var settings_items := 0
	for item in FxPluginHost.menu_item_entries():
		var entry: Dictionary = item
		if String(entry.get("menu", "")) == "edit" \
				and String(entry.get("command", "")) == "settings.open":
			settings_items += 1
	_check(settings_items == 1, "编辑菜单里只有一条设置入口（%d）" % settings_items)


func _test_i18n() -> void:
	_check(FxRegistry.locales.size() >= 3, "语言包是插件贡献（%d 个）" % FxRegistry.locales.size())
	_check(FxI18n.locale_ids().has("en_US") and FxI18n.locale_ids().has("ja_JP"),
		"英文 / 日文语言包可用")
	_check(FxI18n.text("不存在的文案") == "不存在的文案", "未翻译词条回落到原文")
	FxSettings.set_value("general.locale", "en_US")
	_check(FxI18n.locale == "en_US", "设置驱动语言切换")
	_check(FxI18n.text("窗口") == "Window", "英文词条生效")
	_check(FxI18n.text("文件") == "File", "菜单标题走统一翻译点")
	_check(FxI18n.text("深海女仆工坊") == "Deep Sea Atelier",
		"插件自己的词条从它自己的 locales/ 目录读出")
	_check(FileAccess.file_exists("res://plugins/skin.maid-atelier/locales/en_US.json"),
		"插件译文随插件目录存放")
	var core_entries: Dictionary = {}
	for entry in FxRegistry.locales:
		if String(entry.get("locale", "")) == "en_US" and String(entry.get("owner", "")) == "core.i18n":
			for key in (entry.get("entries", {}) as Dictionary).keys():
				core_entries[String(key)] = true
	_check(not core_entries.has("深海女仆工坊"), "core.i18n 不含其它插件的词条")
	_check(core_entries.has("窗口"), "core.i18n 只负责外壳文案")
	FxSettings.set_value("general.locale", "ja_JP")
	_check(FxI18n.text("窗口") == "ウィンドウ", "日文词条生效")
	_check(FxI18n.text("不存在的文案") == "不存在的文案", "缺失词条回落到原文")
	_check(FxI18n.text("共 {n} 项", {"n": 3}) == "共 3 项", "变量占位符可替换")
	FxSettings.set_value("general.locale", "zh_CN")
	_check(FxI18n.text("窗口") == "窗口", "切回源语言")
	_check(FxI18n.coverage() == 0, "源语言包为空，零翻译开销")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	FxSettings.set_value("general.locale", "zh_CN")
	FxSettings.reset("quality.preset")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(LAYOUT))
	FxPluginHost.shutdown()
	quit(code)
