extends SceneTree
## 插件系统 / 参数行 / 纹理粒子导出验收。
## 运行：godot --headless --path . --script res://tests/test_plugins.gd

var failures: Array[String] = []
var out_dir := "user://graph_test"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("== 插件与纹理粒子自测 ==")
	_test_registry()
	_test_native_bridge()
	_test_glow_node()
	_test_recipe_node()
	_test_recipe_ui()
	_test_particle_texture()
	_test_shader_node()
	_test_node_visuals()
	print("----")
	if failures.is_empty():
		print("插件自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


func _test_registry() -> void:
	FxPluginHost.ensure()
	_check(FxRegistry.ready, "插件注册表就绪")
	_check(FxRegistry.plugin_infos.size() >= 8, "加载了 %d 个插件" % FxRegistry.plugin_infos.size())
	_check(FxRegistry.errors.is_empty(), "插件契约校验无错误：%s" % str(FxRegistry.errors))
	var ids: Array[String] = []
	for entry in FxRegistry.exporters:
		ids.append(String(entry.get("id", "")))
	for wanted in ["png.frame", "png.sequence", "png.sheet", "godot.particles"]:
		_check(ids.has(wanted), "导出插件提供 %s" % wanted)
	_check(FxCatalog.has_def("image.glow"), "第三方插件节点 image.glow 进入目录")
	_check(FxOpRegistry.has_op("image.glow"), "第三方插件算子已注册")
	_check(FxWidgetRegistry.has_builder("pixelfx"), "参数控件工厂已注册 pixelfx")


## 假原生算子：只实现窄 ABI 的 fx_exec，用来验证桥（不需要编译器）。
class FakeNativeOp extends RefCounted:
	var calls: int = 0

	func fx_exec(inputs: Dictionary, params: Dictionary, env: Dictionary) -> Dictionary:
		calls += 1
		var gain := float(params.get("gain", 1.0))
		var base := float(inputs.get("value", 0.0))
		return {"value": base * gain, "frame": float(env.get("frame", 0.0))}


## GDExtension 桥：C++ 算子走窄 ABI，图与节点定义完全不知道实现语言。
func _test_native_bridge() -> void:
	var native := FakeNativeOp.new()
	var op := FxNative.bind_object(native, &"test.native.gain")
	_check(op.is_valid(), "原生算子能绑定成执行器认识的 Callable")
	_check(FxNative.thread_safe(), "未声明风险的算子默认线程安全")
	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(64, 32)
	ctx.t = 0.5
	ctx.fps = 30.0
	ctx.quality = 1
	ctx.operator_quality = 0.75
	ctx.options = {"max_blur_radius": 12}
	var def := FxNodeDef.from_dict({"id": "test.native", "op": "test.native.gain"})
	var out: Dictionary = op.call(ctx, {"id": "n1", "type": "test.native"}, def,
		{"value": 4.0}, {"gain": 2.5})
	_check(is_equal_approx(float(out.get("value", 0.0)), 10.0), "原生算子按 ABI 求值")
	_check(is_equal_approx(float(out.get("frame", -1.0)), 15.0), "env 带帧号（0.5s × 30fps）")
	var env := FxNative.env_of(ctx, {"id": "n1", "type": "test.native"}, def)
	_check(int(env.get("abi", 0)) == FxNative.ABI_VERSION, "env 带 ABI 版本")
	_check((env.get("canvas") as Vector2i).x == 64, "env 带画布尺寸")
	_check(is_equal_approx(float(env.get("operator_quality", 0.0)), 0.75), "env 带算子质量系数")
	_check(int((env.get("options") as Dictionary).get("max_blur_radius", 0)) == 12,
		"env 带策略选项")
	_check(String(env.get("op", "")) == "test.native.gain", "env 带算子 id")

	# 非线程安全声明 → 整条渲染链回主线程。
	var stateful := FxNative.bind_object(FakeNativeOp.new(), &"test.native.stateful",
		false, "my.plugin")
	_check(stateful.is_valid(), "非线程安全算子也能绑定")
	_check(not FxNative.thread_safe(), "声明非线程安全后线程闸门关闭")
	_check(FxNative.unsafe_ops().has("test.native.stateful"), "能列出必须跑主线程的算子")
	FxNative.release("other.plugin")
	_check(not FxNative.thread_safe(), "别的插件停用不影响这条标记")
	FxNative.release("my.plugin")
	_check(FxNative.thread_safe(), "停用登记它的插件后线程标记被收回")
	FxNative.reset()
	_check(FxNative.thread_safe(), "重置后恢复线程安全")

	# 缺库 / 缺类如实报错，不抛异常、不影响其它贡献。
	var missing := FxNative.load_library("res://no_such_native.gdextension")
	_check(not bool(missing.get("ok", true)), "缺库时返回失败而不是崩溃")
	_check(not String(missing.get("message", "")).is_empty(), "失败信息可展示给用户")
	_check(not FxNative.bind(&"NoSuchNativeClass", &"test.native.missing").is_valid(),
		"找不到原生类时绑定返回无效 Callable")


func _test_glow_node() -> void:
	var doc := FxGraphDoc.create("glow")
	FxGraphDoc.set_canvas(doc, 64, 64)
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2.ZERO, {"cell": 8})
	FxGraphDoc.add_node(doc, "image.glow", "glow", Vector2(200, 0), {"radius": 3, "amount": 0.5})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(400, 0), {
		"layers": [{"name": "图", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
	})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "src", "image", "glow", "image")
	FxGraphDoc.connect_ports(doc, "glow", "image", "out", "layer_0")
	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	var image: Image = runner.run(doc, 0.0).get("image")
	_check(image is Image and image.get_width() == 64, "插件节点参与整图渲染")
	if image is Image:
		image.save_png(out_dir.path_join("plugin_glow.png"))


func _test_recipe_node() -> void:
	_check(FxCatalog.has_def("image.recipe"), "VfxEngine 配方节点进入目录")
	_check(FxWidgetRegistry.has_builder("recipe"), "配方参数控件已由插件注册")
	var doc := FxGraphDoc.create("recipe")
	FxGraphDoc.set_canvas(doc, 128, 128)
	FxGraphDoc.set_timeline(doc, 30, 1.0, true)
	FxGraphDoc.add_node(doc, "image.recipe", "fx", Vector2.ZERO, {})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(300, 0), {
		"layers": [{"name": "特效", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
	})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "fx", "image", "out", "layer_0")
	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	var image: Image = runner.run(doc, 0.35).get("image")
	_check(image is Image and image.get_size() == Vector2i(128, 128), "配方渲染到画布尺寸")
	_check(image is Image and _opaque(image) > 80, "配方画面非空（%d 像素）" % _opaque(image))
	if image is Image:
		image.save_png(out_dir.path_join("recipe_fire.png"))
	_check(runner.ctx.time_dependent.has("fx"), "配方节点被标记为时间相关（关闭跨帧缓存）")

	runner.quality = 0
	var preview: Image = runner.run(doc, 0.35).get("image")
	_check(preview is Image and preview.get_size() == Vector2i(128, 128), "预览质量下仍输出画布尺寸")
	runner.quality = 1

	var node := FxGraphDoc.node(doc, "fx")
	for preset_id in ["energy", "impact"]:
		node["params"]["recipe"] = FxRecipePresets.json_of(preset_id)
		var preset_image: Image = runner.run(doc, 0.4).get("image")
		_check(preset_image is Image and _opaque(preset_image) > 20,
			"预设 %s 可渲染（%d 像素）" % [preset_id, _opaque(preset_image)])

	node["params"]["recipe"] = "{ not json"
	var broken: Image = runner.run(doc, 0.35).get("image")
	_check(broken is Image and _opaque(broken) == 0, "非法 JSON 不崩溃，输出空画布")


func _opaque(image: Image) -> int:
	if image == null:
		return 0
	var count := 0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a > 0.2:
				count += 1
	return count


func _test_recipe_ui() -> void:
	var ctx := {
		"param": {"id": "recipe", "kind": "recipe", "label": "配方"},
		"get": func() -> Variant: return "",
		"set": func(_value: Variant) -> void: pass,
		"dialog": Callable(),
		"host": null,
	}
	var built := FxWidgetRegistry.build("recipe", ctx)
	_check(built.get("control") is Control, "配方参数控件能构建")


func _test_particle_texture() -> void:
	# 造一张 2×2 帧的测试图集（32×32，每帧 16×16）。
	var sheet := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for i in range(4):
		var color := Color(1, 0.2, 0.2, 1) if i % 2 == 0 else Color(0.2, 0.6, 1, 1)
		sheet.fill_rect(Rect2i((i % 2) * 16, (i / 2) * 16, 16, 16), color)
	var png_path := out_dir.path_join("texture_sheet.png")
	sheet.save_png(png_path)
	_check(FileAccess.file_exists(png_path), "生成测试纹理")

	var doc := FxGraphDoc.create("粒子")
	FxGraphDoc.set_canvas(doc, 32, 32)
	FxGraphDoc.add_node(doc, "image.solid", "s", Vector2.ZERO)
	doc["output"] = "s"
	var scene_path := out_dir.path_join("texture_emitter.tscn")
	var result := FxParticleExport.export(doc, scene_path, {
		"source": "texture", "texture": png_path,
		"columns": 2, "rows": 2, "amount": 8,
		"emission_shape": "sphere", "emission_radius": 10.0,
		"spread": 25.0, "lifetime": 0.8, "scale_min": 0.5, "scale_max": 1.5,
	})
	_check(bool(result.get("ok", false)), "纹理粒子导出成功：%s" % String(result.get("message", "")))
	_check(FileAccess.file_exists(scene_path), "纹理粒子场景写入")
	if not FileAccess.file_exists(scene_path):
		return
	var text := FileAccess.get_file_as_string(scene_path)
	_check(text.contains("shader_parameter/columns = 2.0") and text.contains("shader_parameter/rows = 2.0"), "纹理帧网格 2×2 写入着色器")
	_check(text.contains("amount = 8"), "粒子数量写入")
	_check(text.contains("emission_shape = 1"), "球形发射写入")
	_check(text.contains("emission_sphere_radius = 10.0"), "发射半径写入")
	var shader_path := scene_path.get_basename() + "_flipbook.gdshader"
	_check(FileAccess.file_exists(shader_path), "写出翻转书着色器")
	if FileAccess.file_exists(shader_path):
		var shader_text := FileAccess.get_file_as_string(shader_path)
		_check(shader_text.contains("shader_type canvas_item") and shader_text.contains("uniform float columns"), "着色器包含帧网格参数")
	var packed: Resource = load(scene_path)
	_check(packed is PackedScene, "纹理粒子场景可被 Godot 解析")
	if packed is PackedScene:
		var node := (packed as PackedScene).instantiate()
		_check(node is GPUParticles2D, "根节点是 GPUParticles2D")
		if node is GPUParticles2D:
			_check((node as GPUParticles2D).amount == 8, "实例化后 amount=8")
			_check((node as GPUParticles2D).texture != null, "实例化后贴图已绑定")
			var mat := (node as GPUParticles2D).material as ShaderMaterial
			_check(mat != null, "实例化后挂了 ShaderMaterial")
			if mat != null:
				_check(is_equal_approx(float(mat.get_shader_parameter("columns")), 2.0), "着色器参数 columns=2")
		if node != null:
			node.free()


## 着色器节点：节点定义（gpu 标记 / 参数）、代码来源、uniform 解析、
## 无头环境的安全回退。真渲染另外有图形探针 tests/_probe_shader*.gd。
func _test_shader_node() -> void:
	var def := FxCatalog.def("shader.image")
	_check(def != null, "着色器节点已注册")
	if def == null:
		return
	_check(def.gpu, "着色器节点声明为 GPU（必须回主线程）")
	_check(def.params.size() >= 4, "着色器节点有 路径/内联/uniform/启用 四个参数")
	_check(def.input_port("image").get("required", true) == false, "输入图可选（纯生成式着色器也能用）")

	var inline := FxOpsShader.resolve_code({"code": "shader_type canvas_item;", "path": "missing.gdshader"})
	_check(inline.contains("shader_type"), "内联代码优先于文件路径")
	_check(FxOpsShader.resolve_code({"path": "res://no_such_shader.gdshader"}).is_empty(),
		"文件不存在时返回空代码（节点按原样输出）")
	var sample := "user://shader_probe.gdshader"
	var file := FileAccess.open(sample, FileAccess.WRITE)
	if file != null:
		file.store_string("shader_type canvas_item;\nvoid fragment(){ COLOR = vec4(1.0); }")
		file.close()
		_check(FxOpsShader.resolve_code({"path": sample}).contains("COLOR"), "能从 .gdshader 读到代码")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sample))

	var json_parsed := FxOpsShader.parse_uniforms("{\"strength\": 0.5, \"tint\": \"#ff8800\"}")
	_check(is_equal_approx(float(json_parsed.get("strength", 0.0)), 0.5), "uniform 支持整段 JSON")
	var lines := FxOpsShader.parse_uniforms("strength = 0.25\ntint: #00ff00\n// 注释会被忽略\ncount = 3")
	_check(is_equal_approx(float(lines.get("strength", 0.0)), 0.25), "uniform 支持 名称 = 值")
	_check(String(lines.get("tint", "")) == "#00ff00", "uniform 的十六进制颜色按字符串保留")
	_check(not lines.has("// 注释会被忽略"), "uniform 忽略注释行")
	_check(is_equal_approx(float(lines.get("count", 0.0)), 3.0), "uniform 的数字会被解析成数值")

	# 无头没有渲染器：算子必须原样输出，不能崩、不能返回空图。
	var src := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	src.fill(Color(0.2, 0.4, 0.6, 1.0))
	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(16, 16)
	var out: Dictionary = FxOpsShader.run(ctx, {}, def, {"image": src},
		{"code": "shader_type canvas_item;", "uniforms": "", "enabled": true})
	var image: Image = out.get("image")
	_check(image != null and image.get_size() == Vector2i(16, 16), "无头环境下着色器节点仍有输出")
	_check(image != null and is_equal_approx(image.get_pixel(4, 4).r, 0.2),
		"无头环境按原样输出（不产出坏帧）")
	var passthrough: Dictionary = FxOpsShader.run(ctx, {}, def, {"image": src},
		{"code": "shader_type canvas_item;", "uniforms": "", "enabled": false})
	_check(is_equal_approx((passthrough.get("image") as Image).get_pixel(4, 4).b, 0.6),
		"关闭开关后原样输出")
	_check(FxShaderRuntime.on_main_thread(), "主线程检测可用")
	_check(not FxShaderRuntime.available(), "无头环境如实报告「不能离屏渲染」")


## 节点/插件的「视觉表示」：图标纹理、动图切帧、渲染样张与三级回退。
func _test_node_visuals() -> void:
	# 归属：节点定义能报出提供它的插件（面板显示「归属」就靠这个）
	var blur := FxCatalog.def("image.blur")
	_check(blur != null and blur.owner_plugin == "core.image", "节点定义带插件归属（core.image）")
	_check(blur != null and blur.source_file.begins_with("res://plugins/core.image/"),
		"节点定义记着自己来自哪个 JSON")
	_check(blur != null and blur.icon.is_empty(), "没写图标的节点如实为空（走样张回退）")

	# 精灵表切帧：cols=0 时按正方形帧自动推列数
	var grid := FxVisualIcon.frames({"cols": 0, "rows": 1, "fps": 10}, Vector2i(256, 64))
	_check(int(grid.get("cols")) == 4 and int(grid.get("count")) == 4, "动图列数按帧高自动推算")
	_check(bool(grid.get("animated")), "多帧时标记为动图")
	var still := FxVisualIcon.frames({}, Vector2i(64, 64))
	_check(not bool(still.get("animated")) and int(still.get("count")) == 1, "没有动图参数就是静帧")
	var rect := FxVisualIcon.frame_rect(5, {"cols": 4, "rows": 2}, Vector2i(256, 128))
	_check(is_equal_approx(rect.position.x, 64.0) and is_equal_approx(rect.position.y, 64.0),
		"第 5 帧落在第二行第一列")
	_check(FxVisualIcon.is_image_path("assets/blur.png") and not FxVisualIcon.is_image_path("◐"),
		"能区分字形与图片路径")
	_check(FxVisualIcon.category_color("图像/处理") == FxVisualIcon.category_color("图像/处理"),
		"同一分类的配色稳定")
	_check(FxVisualIcon.category_glyph("动画/曲线") != FxVisualIcon.category_glyph("图像/处理"),
		"不同分类有不同字形")

	# 渲染样张：图像节点能出图，纯数值节点老实返回 null
	var made := FxNodePreview.render("image.blur", Vector2i(64, 40))
	_check(made != null and made.get_size() == Vector2i(64, 40), "图像节点能渲染出样张")
	if made != null:
		_check(made.get_pixel(32, 20).a > 0.0, "样张不是全透明")
	_check(FxNodePreview.render("math.number", Vector2i(64, 40)) == null,
		"纯数值节点不出样张（上层回退字形）")
	_check(FxNodePreview.can_render("output.final") and not FxNodePreview.can_render("logic.bool"),
		"can_render 按输出端口类型判断")
	var doc := FxNodePreview.build_doc("image.mix", Vector2i(64, 40))
	_check((doc.get("nodes", []) as Array).size() == 4, "样张文档 = 源链 3 节点 + 目标节点")
	# 源链 2 条（棋盘 / 圆盘 → 混合）+ 目标节点每个图像输入各 1 条（image.mix 有两个）
	_check((doc.get("edges", []) as Array).size() == 4, "样张文档内部连线齐备")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


## 无头脚本退出前必须卸载插件注册表。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
