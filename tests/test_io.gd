extends SceneTree
## 启动回调 / 保存加载 / 各类导出（菜单与节点两套）/ 子图嵌套 / 打包解包 的验收。
## 运行：godot --headless --path . --script res://tests/test_io.gd

var failures: Array[String] = []
var shell: FxShell
var boot_events: Array[Dictionary] = []
const ROOT := "user://io_test"


func _initialize() -> void:
	print("== 启动与输入输出自测 ==")
	_wipe()
	# 订阅要在外壳 _ready 之前：启动事件就是这么被外部（控制台/日志/诊断）消费的。
	FxBoot.listen(func(event: Dictionary) -> void: boot_events.append(event))
	var packed: PackedScene = load("res://scenes/main.tscn")
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for i in range(6):
		await process_frame
	_test_boot_report()
	_test_doc_roundtrip()
	_test_export_menu()
	_test_export_nodes()
	_test_subgraph()
	_test_subgraph_ports()
	_test_examples()
	_test_image_object()
	await _test_threaded_render()
	await _test_pack_unpack()
	print("----")
	if failures.is_empty():
		print("启动与输入输出自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


# ---------- 启动报告 ----------

func _test_boot_report() -> void:
	_check(not FxBoot.active(), "启动结束后不再处于 active 状态")
	var progress := FxBoot.progress()
	_check(int(progress.get("done", 0)) >= 20, "启动推进了足够多的步骤（%d）" % int(progress.get("done", 0)))
	_check(int(progress.get("total", 0)) > 0, "启动有总步数（%d）" % int(progress.get("total", 0)))
	_check(progress.has("ratio") and progress.has("elapsed_ms"), "进度快照带比例与耗时")

	var plugin_steps := 0
	var node_steps := 0
	for event in boot_events:
		if String(event.get("kind", "")) != "step":
			continue
		var current := String(event.get("current", ""))
		if current.begins_with("插件 "):
			plugin_steps += 1
		elif current.begins_with("节点定义 "):
			node_steps += 1
	_check(plugin_steps >= 30, "逐个插件汇报进度（%d 个）" % plugin_steps)
	_check(node_steps >= 10, "逐个节点定义文件汇报进度（%d 个）" % node_steps)
	var finished := false
	for event2 in boot_events:
		if String(event2.get("kind", "")) == "finish":
			finished = true
	_check(finished, "启动结束会发 finish 事件")
	_check(not FxBoot.summary().is_empty(), "启动汇总是可读文本（%s）" % FxBoot.summary())

	var log_path := ProjectSettings.globalize_path(FxBoot.log_path())
	_check(FileAccess.file_exists(FxBoot.log_path()), "启动日志已落盘（%s）" % log_path)
	var text := FileAccess.get_file_as_string(FxBoot.log_path())
	_check(text.contains("插件 core.graph"), "日志里能看到当前加载项")
	_check(text.contains("启动完成"), "日志里有完成汇总")


# ---------- 保存 / 加载 ----------

func _test_doc_roundtrip() -> void:
	var doc := FxGraphDoc.create("往返")
	FxGraphDoc.set_canvas(doc, 48, 32)
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2(10, 20), {"cell": 8})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(300, 20), {})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "src", "image", "out", "layer_0")
	var path := ROOT + "/roundtrip.fxgraph"
	var err := FxGraphDoc.save(doc, path)
	_check(err == OK, "文档保存成功")
	var loaded := FxGraphDoc.load_json(path)
	_check((loaded.get("nodes", []) as Array).size() == 2, "读回来节点数一致")
	_check(String(loaded.get("output", "")) == "out", "输出节点被保存")
	_check(FxGraphDoc.canvas(loaded) == Vector2i(48, 32), "画布尺寸被保存")
	_check((loaded.get("edges", []) as Array).size() == 1, "连线被保存")
	# 通过能力契约读（蓝图打包/解包走的是这条路）
	var via_access := FxGraphFacade.access().doc_load(path)
	_check((via_access.get("nodes", []) as Array).size() == 2, "经代理也能读文档")
	# 反序列化后的图仍能渲染
	var runner := FxGraphRunner.new()
	var image: Image = runner.run(loaded, 0.0).get("image")
	_check(image != null and image.get_width() == 48, "读回来的图能渲染")


# ---------- 导出：菜单那一套 ----------

func _test_export_menu() -> void:
	var doc := FxGraphDoc.create("导出")
	FxGraphDoc.set_canvas(doc, 32, 32)
	FxGraphDoc.set_timeline(doc, 12, 0.25, true)
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2.ZERO, {"cell": 4})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(240, 0), {})
	doc["output"] = "out"
	FxGraphDoc.connect_ports(doc, "src", "image", "out", "layer_0")

	var frame_path := ROOT + "/frame.png"
	var frame_result := FxExportService.save_frame(doc, frame_path, 0.0)
	_check(bool(frame_result.get("ok", false)), "导出当前帧 PNG")
	_check(_png_size(frame_path) == Vector2i(32, 32), "当前帧尺寸正确（%s）" % str(_png_size(frame_path)))

	var seq_dir := ROOT + "/sequence"
	var seq_result := FxExportService.save_sequence(doc, seq_dir)
	var seq_files: Array = seq_result.get("files", [])
	_check(bool(seq_result.get("ok", false)) and seq_files.size() == 3, "导出 PNG 序列（3 帧）")
	_check(FileAccess.file_exists(String(seq_files[0])), "序列文件确实写出来了")

	var sheet_path := ROOT + "/sheet.png"
	var sheet_result := FxExportService.save_sheet(doc, sheet_path)
	_check(bool(sheet_result.get("ok", false)), "导出精灵表 PNG")
	_check(_png_size(sheet_path).x >= 64, "精灵表按 2 列拼图（%s）" % str(_png_size(sheet_path)))
	var json_path := sheet_path.get_basename() + ".json"
	_check(FileAccess.file_exists(json_path), "精灵表同时写出帧元数据 JSON")
	var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	_check(payload is Dictionary, "元数据是合法 JSON")
	if payload is Dictionary:
		var meta: Dictionary = (payload as Dictionary).get("meta", {})
		_check(int((meta.get("pixelfx", {}) as Dictionary).get("frames", 0)) == 3, "元数据帧数为 3")
		_check((meta.get("size", {}) as Dictionary).has("w"), "元数据带图片尺寸")

	var scene_path := ROOT + "/emitter.tscn"
	var godot_result := FxParticleExport.export(doc, scene_path, {"source": "sheet"})
	_check(bool(godot_result.get("ok", false)), "导出 Godot 粒子场景")
	_check(FileAccess.file_exists(scene_path), "场景文件存在")
	_check(FileAccess.file_exists(scene_path.get_basename() + "_tex.res"), "贴图资源存在")
	var scene_text := FileAccess.get_file_as_string(scene_path)
	_check(scene_text.contains("GPUParticles2D"), "场景里有 GPUParticles2D")


# ---------- 导出：节点那一套 ----------

func _test_export_nodes() -> void:
	FxOpsExport.reset_limits()
	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(16, 16)
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 0, 0, 1))
	var target := ROOT + "/node_image.png"
	var node := {"id": "n1", "type": "io.export_image"}
	var params := {"path": target, "run": false}
	var idle := FxOpsExport.export_image(ctx, node, null, {"image": image}, params)
	_check(not bool(idle.get("ok", false)) and not FileAccess.file_exists(target),
		"run 关闭时不碰磁盘")
	params["run"] = true
	var wrote := FxOpsExport.export_image(ctx, node, null, {"image": image}, params)
	_check(bool(wrote.get("ok", false)), "run 打开后写盘成功")
	_check(_png_size(target) == Vector2i(16, 16), "节点导出的图像尺寸正确")
	var again := FxOpsExport.export_image(ctx, node, null, {"image": image}, params)
	_check(not bool(again.get("ok", false)), "节流：同一节点同一路径不会每帧重写")
	FxOpsExport.reset_limits()

	# 保存工程节点
	var doc := FxGraphDoc.create("节点保存")
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2.ZERO, {})
	ctx.doc = doc
	var save_path := ROOT + "/node_save.fxgraph"
	var saved := FxOpsExport.save_doc(ctx, {"id": "n2"}, null, {},
		{"path": save_path, "run": true})
	_check(bool(saved.get("ok", false)) and FileAccess.file_exists(save_path), "保存工程节点写出文档")
	_check(int(value_of(saved.get("count"))) == 1, "保存节点回报节点数")

	# 精灵表 / 粒子节点：需要一张有输出节点的文档
	var export_doc := FxGraphDoc.create("节点导出")
	FxGraphDoc.set_canvas(export_doc, 16, 16)
	FxGraphDoc.set_timeline(export_doc, 10, 0.2, true)
	FxGraphDoc.add_node(export_doc, "image.checker", "c", Vector2.ZERO, {"cell": 4})
	FxGraphDoc.add_node(export_doc, "output.final", "oo", Vector2(200, 0), {})
	export_doc["output"] = "oo"
	FxGraphDoc.connect_ports(export_doc, "c", "image", "oo", "layer_0")
	ctx.doc = export_doc
	FxOpsExport.reset_limits()
	var sheet_path := ROOT + "/node_sheet.png"
	var sheet := FxOpsExport.export_sheet(ctx, {"id": "n3"}, null, {},
		{"path": sheet_path, "run": true})
	_check(bool(sheet.get("ok", false)) and FileAccess.file_exists(sheet_path), "导出精灵表节点写了 PNG")
	_check(FileAccess.file_exists(sheet_path.get_basename() + ".json"), "导出精灵表节点写了 JSON")

	FxOpsExport.reset_limits()
	var scene_path := ROOT + "/node_emitter.tscn"
	var godot := FxOpsExport.export_godot(ctx, {"id": "n4"}, null, {},
		{"path": scene_path, "run": true, "source": "sheet"})
	_check(bool(godot.get("ok", false)) and FileAccess.file_exists(scene_path), "导出 Godot 节点写了场景")
	FxOpsExport.reset_limits()


# ---------- 子图（工程嵌套） ----------

func _test_subgraph() -> void:
	var inner := FxGraphDoc.create("内部")
	FxGraphDoc.set_canvas(inner, 8, 8)
	FxGraphDoc.set_timeline(inner, 10, 1.0, true)
	FxGraphDoc.add_node(inner, "image.checker", "s", Vector2.ZERO, {"cell": 2})
	FxGraphDoc.add_node(inner, "output.final", "o", Vector2(200, 0), {})
	inner["output"] = "o"
	FxGraphDoc.connect_ports(inner, "s", "image", "o", "layer_0")
	var inner_path := ROOT + "/inner.fxgraph"
	FxGraphDoc.save(inner, inner_path)

	var ctx := FxEvalContext.new()
	ctx.canvas = Vector2i(16, 16)
	var out := FxOpsSubgraph.render(ctx, {}, null, {}, {"path": inner_path, "fit": "contain"})
	var image: Variant = out.get("image")
	_check(image is Image, "子图输出图像")
	if image is Image:
		_check((image as Image).get_width() == 16, "子图画面落到外层画布（%d）" % (image as Image).get_width())
	_check(absf(float(out.get("duration", 0.0)) - 1.0) < 0.001, "子图输出时长")
	_check(int(out.get("frames", 0)) == 10, "子图输出总帧数")
	_check((out.get("canvas", Vector2.ZERO) as Vector2) == Vector2(8, 8), "子图输出自己的画布尺寸")

	# 文件读不到 → 不崩，返回空画面
	ctx.warnings.clear()
	var missing := FxOpsSubgraph.render(ctx, {}, null, {}, {"path": ROOT + "/nope.fxgraph"})
	_check(missing.get("image") is Image and not ctx.warnings.is_empty(), "子图缺失时给空画面并报警")

	# 循环引用：自己嵌自己
	var loop_doc := FxGraphDoc.create("自嵌")
	FxGraphDoc.add_node(loop_doc, "graph.subgraph", "sub", Vector2.ZERO, {})
	var loop_path := ROOT + "/loop.fxgraph"
	FxGraphDoc.save(loop_doc, loop_path)
	var loop_doc2 := FxGraphDoc.load_json(loop_path)
	loop_doc2["nodes"][0]["params"]["path"] = loop_path
	loop_doc2["output"] = "sub"
	FxGraphDoc.save(loop_doc2, loop_path)
	FxOpsSubgraph.clear_cache()
	ctx.warnings.clear()
	var loop_out := FxOpsSubgraph.render(ctx, {}, null, {}, {"path": loop_path})
	_check(loop_out.get("image") is Image, "循环引用不挂死，仍返回画面")
	var warned_cycle := false
	for item in ctx.warnings:
		if String(item).contains("循环引用"):
			warned_cycle = true
	_check(warned_cycle, "循环引用会被明确报出来")


# ---------- 子图边界端口 ----------

## 子图内部的「子图输入 / 子图输出」节点，要能把值带进带出，
## 并在外层子图节点上长成对应类型的端口。
func _test_subgraph_ports() -> void:
	var inner := FxGraphDoc.create("带边界的子图")
	FxGraphDoc.set_canvas(inner, 8, 8)
	FxGraphDoc.set_timeline(inner, 10, 1.0, true)
	FxGraphDoc.add_node(inner, "graph.input", "gin", Vector2.ZERO, {"name": "亮度", "type": "number"})
	FxGraphDoc.add_node(inner, "image.checker", "chk", Vector2(0, 220), {"cell": 2})
	FxGraphDoc.add_node(inner, "image.levels", "lv", Vector2(240, 220), {})
	FxGraphDoc.add_node(inner, "graph.output", "gout", Vector2(520, 0), {"name": "读数", "type": "number"})
	FxGraphDoc.add_node(inner, "graph.output", "gimg", Vector2(520, 220), {"name": "画面", "type": "image"})
	FxGraphDoc.add_node(inner, "output.final", "o", Vector2(780, 220), {})
	inner["output"] = "o"
	FxGraphDoc.connect_ports(inner, "gin", "value", "lv", "brightness")
	FxGraphDoc.connect_ports(inner, "gin", "value", "gout", "value")
	FxGraphDoc.connect_ports(inner, "chk", "image", "lv", "image")
	FxGraphDoc.connect_ports(inner, "lv", "image", "gimg", "value")
	FxGraphDoc.connect_ports(inner, "lv", "image", "o", "layer_0")
	var inner_path := ROOT + "/inner_ports.fxgraph"
	FxGraphDoc.save(inner, inner_path)
	FxOpsSubgraph.clear_cache()

	# 边界节点自己的端口：输入节点一个出口，输出节点一个入口。
	var in_ports := FxCatalog.ports("graph.input", {"name": "亮度", "type": "number"})
	_check(_port_exists(in_ports.get("outputs", []), "value"), "子图输入节点有 value 出口")
	var out_ports := FxCatalog.ports("graph.output", {"name": "读数", "type": "number"})
	_check(_port_exists(out_ports.get("inputs", []), "value"), "子图输出节点有 value 入口")

	# 外层子图节点：端口跟着子工程走。
	var parent_ports := FxCatalog.ports("graph.subgraph", {"path": inner_path})
	var labels := {}
	var input_types := {}
	for item in parent_ports.get("inputs", []):
		var spec: Dictionary = item
		input_types[String(spec.get("id", ""))] = String(spec.get("type", ""))
		labels[String(spec.get("id", ""))] = String(spec.get("label", ""))
	_check(input_types.get("gin", "") == "number", "子图节点长出声明的输入口")
	_check(String(labels.get("gin", "")) == "亮度", "输入口用的是端口名")
	var output_types := {}
	for item in parent_ports.get("outputs", []):
		var spec2: Dictionary = item
		output_types[String(spec2.get("id", ""))] = String(spec2.get("type", ""))
	_check(output_types.get("gout", "") == "number", "子图节点长出数值输出口")
	_check(output_types.get("gimg", "") == "image", "子图节点长出图像输出口")
	_check(output_types.has("image"), "原有的图像输出没有被顶掉")

	# 跑一遍外层：0.4 送进去，子图把它原样交回来，另外再交一张图。
	var parent := FxGraphDoc.create("外层")
	FxGraphDoc.set_canvas(parent, 16, 16)
	FxGraphDoc.set_timeline(parent, 10, 1.0, true)
	FxGraphDoc.add_node(parent, "math.number", "n", Vector2.ZERO, {"op": "add", "a": 0.4, "b": 0.0})
	FxGraphDoc.add_node(parent, "graph.subgraph", "sub", Vector2(240, 0), {"path": inner_path})
	parent["output"] = "sub"
	_check(FxGraphDoc.connect_ports(parent, "n", "number", "sub", "gin") == FxGraphDoc.LINK_OK,
		"外层可以连到声明的输入口")
	var runner := FxGraphRunner.new()
	var frame := runner.run(parent, 0.0)
	_check(frame.get("image") is Image, "带边界的子图仍然出图")
	var sub_out: Dictionary = runner.ctx.outputs.get("sub", {})
	_check(absf(float(sub_out.get("gout", -1.0)) - 0.4) < 0.001, "输入穿过子图又交回外层（%s）"
		% str(sub_out.get("gout")))
	_check(sub_out.get("gimg") is Image, "子图交回一张图像")
	FxOpsSubgraph.clear_cache()


# ---------- 随包示例工程 ----------
## examples/ 里的工程要能直接打开就用：类型、参数名、端口一个都不能过时。
## 这类漂移不会报错，只会让效果悄悄变默认值，所以拿测试盯住。

func _test_examples() -> void:
	var dirs: Array[String] = ["res://examples", "res://examples/demo"]
	var checked := 0
	for dir in dirs:
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
			continue
		for file in DirAccess.get_files_at(dir):
			if not file.ends_with(".fxgraph"):
				continue
			var doc := FxGraphDoc.load_json(dir + "/" + file)
			_check(not doc.is_empty(), "%s 能读进来" % file)
			if doc.is_empty():
				continue
			checked += 1
			_check(_example_problems(doc).is_empty(), "%s 节点/参数/端口都对得上（%s）"
				% [file, ", ".join(_example_problems(doc))])
			if String(doc.get("output", "")).is_empty():
				# 子图文件可以没有输出节点，它靠子图输出端口对外交货。
				var has_boundary := false
				for item in doc.get("nodes", []):
					if String((item as Dictionary).get("type", "")) == "graph.output":
						has_boundary = true
				_check(has_boundary, "%s 指定了输出节点或有子图输出口" % file)
			else:
				_check(not String(doc.get("output", "")).is_empty(), "%s 指定了输出节点" % file)
	_check(checked >= 5, "示例工程数量（%d）" % checked)

	# 示范工程包：要能解包回同一份图，素材也要跟着走。
	var proj := "res://examples/demo/示范工程.fxproj"
	if FileAccess.file_exists(proj):
		var loaded := FxProjectArchive.read_zip(proj)
		_check(bool(loaded.get("ok", false)), "示范工程包能打开")
		var packed_doc: Dictionary = loaded.get("doc", {})
		_check((packed_doc.get("nodes", []) as Array).size() > 50, "示范工程包里带着整张图（%d 节点）"
			% (packed_doc.get("nodes", []) as Array).size())
		_check((loaded.get("extracted_assets", []) as Array).size() >= 2, "示范工程包带着外部素材")


func _example_problems(doc: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	var types := {}
	for item in doc.get("nodes", []):
		var node: Dictionary = item
		var type_id := String(node.get("type", ""))
		types[String(node.get("id", ""))] = type_id
		var def := FxCatalog.def(type_id)
		if def == null:
			problems.append("未知类型 " + type_id)
			continue
		var allowed := {}
		for param in def.params:
			allowed[String(param.get("id", ""))] = true
		for raw_key in (node.get("params", {}) as Dictionary).keys():
			if not allowed.has(String(raw_key)):
				problems.append("%s 未知参数 %s" % [type_id, raw_key])
		# 子图节点的文件必须真的能解析出来，否则双击下钻会打不开。
		if type_id == "graph.subgraph":
			var sub_path := String((node.get("params", {}) as Dictionary).get("path", ""))
			if not sub_path.is_empty() and FxOpsSubgraph.resolve_path(sub_path).is_empty():
				problems.append("子图文件找不到 " + sub_path)
	# 端口按节点的**实际**端口表算：图层、序列、子图边界都是动态长出来的。
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		var from_node := FxGraphDoc.node(doc, String(edge.get("from", "")))
		var to_node := FxGraphDoc.node(doc, String(edge.get("to", "")))
		if from_node.is_empty() or to_node.is_empty():
			problems.append("边指向不存在的节点")
			continue
		var from_ports := FxCatalog.ports(String(from_node.get("type", "")),
			from_node.get("params", {}))
		var to_ports := FxCatalog.ports(String(to_node.get("type", "")),
			to_node.get("params", {}))
		if not _port_exists(from_ports.get("outputs", []), String(edge.get("from_port", ""))):
			problems.append("%s 没有输出口 %s" % [from_node.get("type"), edge.get("from_port")])
		if not _port_exists(to_ports.get("inputs", []), String(edge.get("to_port", ""))):
			problems.append("%s 没有输入口 %s" % [to_node.get("type"), edge.get("to_port")])
	return problems


func _port_exists(ports: Array, id: String) -> bool:
	for port in ports:
		if String((port as Dictionary).get("id", "")) == id:
			return true
	# 最终输出节点的图层端口按图层数量动态生成（layer_<序号>），不写在静态定义里。
	return id.begins_with("layer_")


# ---------- 图像值对象 ----------

func _test_image_object() -> void:
	var image := Image.create_empty(4, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 0, 0, 1))
	var object := FxImageObject.wrap(image)
	_check(object.width == 4 and object.height == 2, "图像对象带可读的宽高属性")
	_check(object.pixel_count == 8, "图像对象给出像素数")
	_check(object.pixel_data().size() == 32, "图像对象能读到 RGBA 字节数据")
	_check(object.pixel_at(2, 1).is_equal_approx(Color(1, 0, 0, 1)), "能按坐标读像素颜色")
	_check(FxImageObject.unwrap(object) == image, "对象拆包拿回原图")
	_check(object.describe().contains("4×2"), "对象有可读描述")

	_check(FxPortType.can_connect(FxPortType.IMAGE_OBJECT, FxPortType.IMAGE), "对象 → 图像端口可连")
	_check(FxPortType.can_connect(FxPortType.IMAGE, FxPortType.IMAGE_OBJECT), "图像 → 对象端口可连")
	var unwrapped: Variant = FxPortType.cast_value(object, FxPortType.IMAGE_OBJECT, FxPortType.IMAGE)
	_check(unwrapped is Image and (unwrapped as Image).get_width() == 4, "连线时自动拆包")
	var wrapped: Variant = FxPortType.cast_value(image, FxPortType.IMAGE, FxPortType.IMAGE_OBJECT)
	_check(wrapped is FxImageObject, "连线时自动打包")
	_check(FxPortType.id_of(FxPortType.IMAGE) == 2, "新增类型没有打乱旧类型号")

	# 真实执行器：棋盘 → 图像对象 → 最终输出（对象输出直接喂给老图像输入）
	var doc := FxGraphDoc.create("对象图")
	FxGraphDoc.set_canvas(doc, 16, 16)
	FxGraphDoc.add_node(doc, "image.checker", "src", Vector2.ZERO, {"cell": 4})
	FxGraphDoc.add_node(doc, "image.object", "obj", Vector2(200, 0), {})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(400, 0), {})
	doc["output"] = "out"
	_check(FxGraphDoc.connect_ports(doc, "src", "image", "obj", "image") == FxGraphDoc.LINK_OK,
		"普通图像能接进对象节点")
	_check(FxGraphDoc.connect_ports(doc, "obj", "object", "out", "layer_0") == FxGraphDoc.LINK_OK,
		"对象输出能接进最终输出的图层输入")
	var runner := FxGraphRunner.new()
	var result := runner.run(doc, 0.0)
	var rendered: Image = result.get("image")
	_check(rendered != null and rendered.get_width() == 16, "对象链路能渲染出画面")
	_check((result.get("warnings", []) as Array).is_empty(), "对象链路无求值警告")

	# 任意已有 image 输出都能直接接到对象输入（连线时自动打包），不用改老节点
	var direct := FxGraphDoc.create("直接读对象")
	FxGraphDoc.set_canvas(direct, 16, 16)
	FxGraphDoc.add_node(direct, "image.checker", "src", Vector2.ZERO, {"cell": 4})
	FxGraphDoc.add_node(direct, "image.info", "info", Vector2(200, 0), {})
	FxGraphDoc.add_node(direct, "output.final", "out", Vector2(400, 0), {})
	direct["output"] = "out"
	_check(FxGraphDoc.connect_ports(direct, "src", "image", "info", "object") == FxGraphDoc.LINK_OK,
		"普通图像输出可直接接到对象输入")
	_check(FxGraphDoc.connect_ports(direct, "info", "image", "out", "layer_0") == FxGraphDoc.LINK_OK,
		"对象节点拆包后的图像能接到输出")
	var direct_result := FxGraphRunner.new().run(direct, 0.0)
	var direct_image: Image = direct_result.get("image")
	_check(direct_image != null and direct_image.get_width() == 16, "老图像输出经对象节点仍可渲染")

	var eval_ctx := FxEvalContext.new()
	eval_ctx.canvas = Vector2i(4, 2)
	var packed := FxOpsImageObject.pack(eval_ctx, {}, null, {"image": image}, {})
	_check((packed.get("object") as FxImageObject).width == 4, "包装算子输出对象")
	_check(float(packed.get("data_size")) == 32.0, "包装算子输出字节数")
	var picked := FxOpsImageObject.pixel(eval_ctx, {}, null, {"object": object}, {"x": 3, "y": 1})
	_check((picked.get("color") as Color).r > 0.9, "取像素算子读到颜色")


# ---------- 后台线程求帧 ----------

## 求帧在工作线程上：界面线程不等待，结果通过互斥量交回。
## 画质不变：输出仍是画布全分辨率，逐节点预览与参数照旧。
func _test_threaded_render() -> void:
	var service: Variant = shell.service("render")
	_check(service != null, "外壳装配了渲染服务")
	if service == null:
		return
	_check(bool(service.call("is_threaded")), "标准后端默认走后台线程（thread_safe）")
	var frames: Array = []
	var got_preview := [false]
	service.connect("rendered", func(_image: Image, _stats: Dictionary) -> void: frames.append(1))
	service.connect("node_previewed", func(_id: String, _img: Image) -> void: got_preview[0] = true)
	service.call("request_render")
	for i in range(300):
		if not frames.is_empty():
			break
		await process_frame
	_check(not frames.is_empty(), "工作线程把帧交回主线程并广播 rendered")
	var image: Image = service.call("last_image")
	_check(image != null and image.get_width() == FxGraphDoc.canvas(shell.store.doc).x,
		"线程求出的帧是全分辨率（没有降采样）")
	var params: Dictionary = service.call("last_node_params")
	_check(not params.is_empty(), "线程路径同样回传每节点解析后的参数")
	_check(got_preview[0], "节点预览也在工作线程算好后回到界面")
	# 关掉线程 → 回落主线程同步求帧，行为一致
	FxSettings.set_value("render.threaded", false)
	service.call("_configure_threading")
	_check(not bool(service.call("is_threaded")), "关闭设置后回到主线程同步渲染")
	FxSettings.set_value("render.threaded", true)
	service.call("_configure_threading")
	await process_frame

	# 图里出现 GPU 节点（着色器）→ 仍然留在工作线程。
	# 离屏渲染由 FxShaderRuntime 的「主线程 GPU 泵」桥接，工作线程排队等结果，
	# 不再把整帧 600ms 的求值拖回 UI 线程。
	var store: FxDocumentStore = shell.get("store")
	var doc := FxGraphDoc.create("着色器线程")
	FxGraphDoc.set_canvas(doc, 32, 32)
	FxGraphDoc.add_node(doc, "shader.image", "sh", Vector2.ZERO,
		{"code": "shader_type canvas_item;"})
	var out := FxGraphDoc.add_node(doc, "output.final", "out", Vector2(300, 0), {})
	doc["output"] = String(out.get("id", "out"))
	FxGraphDoc.connect_ports(doc, "sh", "image", "out", "layer_0")
	store.attach(doc)
	for i in range(4):
		await process_frame
	_check(bool(service.call("is_threaded")), "含 GPU 节点仍可后台求值（走 GPU 泵桥）")
	_check(bool(service.call("_graph_needs_main_thread")), "能识别出图里有 GPU 节点")
	_check(FxRenderGate.has_main_thread_pump(), "着色器插件注册了主线程泵（基座不认识设备类型）")
	# 换回普通图 → 线程重新打开
	var plain := FxGraphDoc.create("普通图")
	FxGraphDoc.set_canvas(plain, 32, 32)
	var out2 := FxGraphDoc.add_node(plain, "output.final", "out", Vector2.ZERO, {})
	plain["output"] = String(out2.get("id", "out"))
	store.attach(plain)
	for i in range(4):
		await process_frame
	_check(bool(service.call("is_threaded")), "移除 GPU 节点后恢复后台线程")


# ---------- 打包 / 解包 ----------

func _test_pack_unpack() -> void:
	var store: FxDocumentStore = shell.get("store")
	var doc := FxGraphDoc.create("打包源")
	FxGraphDoc.set_canvas(doc, 32, 32)
	store.attach(doc)
	store.add_node("image.checker", "src", Vector2(0, 0), {"cell": 4})
	store.add_node("image.blur", "b1", Vector2(220, 0), {"radius": 2.0})
	store.add_node("output.final", "out", Vector2(460, 0), {})
	store.set_output("out")
	store.connect_ports("src", "image", "b1", "image")
	store.connect_ports("b1", "image", "out", "layer_0")
	for i in range(3):
		await process_frame
	var editor: FxGraphEditor = shell.panel("editor.graph")
	_check(editor != null, "蓝图面板可用")
	if editor == null:
		return

	editor.call("_select_many", ["src", "b1"])
	await process_frame
	editor.call("_pack_selection")
	for i in range(4):
		await process_frame
	var types := _node_types(store.doc)
	_check(types.size() == 2 and types.has("graph.subgraph") and types.has("output.final"),
		"打包后只剩子图节点与输出（%s）" % str(types))
	var sub_id := ""
	for item in store.doc.get("nodes", []):
		if String((item as Dictionary).get("type", "")) == "graph.subgraph":
			sub_id = String((item as Dictionary).get("id", ""))
	_check(not sub_id.is_empty(), "子图节点已插入")
	var sub_path := ""
	if not sub_id.is_empty():
		sub_path = String((FxGraphDoc.node(store.doc, sub_id).get("params", {}) as Dictionary).get("path", ""))
	_check(not sub_path.is_empty() and FileAccess.file_exists(sub_path), "子图文件已写出（%s）" % sub_path)
	var sub_doc := FxGraphDoc.load_json(sub_path)
	var sub_plain := 0
	var sub_has_output_port := false
	for item in sub_doc.get("nodes", []):
		var st := String((item as Dictionary).get("type", ""))
		if st == "graph.output":
			sub_has_output_port = true
		elif st != "graph.input":
			sub_plain += 1
	_check(sub_plain == 2, "子图里有被选中的两个节点")
	_check(sub_has_output_port, "对外出口换成了子图输出节点")
	_check((sub_doc.get("edges", []) as Array).size() == 2, "子图保留内部连线，并接上输出口")
	_check(String(sub_doc.get("output", "")) == "b1", "子图输出是被打包链的出图节点")
	var rewired := false
	for item2 in store.doc.get("edges", []):
		var edge: Dictionary = item2
		if String(edge.get("from", "")) == sub_id and String(edge.get("to", "")) == "out":
			rewired = true
	_check(rewired, "外部连线接到子图输出")

	# 渲染:子图节点真的能出图
	var runner := FxGraphRunner.new()
	var image: Image = runner.run(store.doc, 0.0).get("image")
	_check(image != null, "含子图的图能渲染出画面")

	# 解包：恢复成两个节点
	editor.call("_select_many", [sub_id])
	await process_frame
	editor.call("_unpack_selection")
	for i in range(4):
		await process_frame
	var after := _node_types(store.doc)
	_check(after.size() == 3 and after.has("image.checker"), "解包后节点回来了（%s）" % str(after))
	var edge_back := false
	for item3 in store.doc.get("edges", []):
		var edge2: Dictionary = item3
		if String(edge2.get("to", "")) == "out" and String(edge2.get("from", "")) != "b1":
			edge_back = true
	_check(edge_back, "解包后下游重新接到展开出来的节点")

	# 再打包一次，这次选区两侧都连着外面：边界节点要自动生成、连线不能丢。
	var blur_id := ""
	for item4 in store.doc.get("nodes", []):
		if String((item4 as Dictionary).get("type", "")) == "image.blur":
			blur_id = String((item4 as Dictionary).get("id", ""))
	editor.call("_select_many", [blur_id])
	await process_frame
	editor.call("_pack_selection")
	for i in range(4):
		await process_frame
	var sub2 := ""
	for item4 in store.doc.get("nodes", []):
		if String((item4 as Dictionary).get("type", "")) == "graph.subgraph":
			sub2 = String((item4 as Dictionary).get("id", ""))
	_check(not sub2.is_empty(), "带外部连线的选区也能打包")
	if not sub2.is_empty():
		var path2 := String((FxGraphDoc.node(store.doc, sub2).get("params", {}) as Dictionary).get("path", ""))
		var sub2_doc := FxGraphDoc.load_json(path2)
		var input_port := ""
		for item5 in sub2_doc.get("nodes", []):
			var n5: Dictionary = item5
			if String(n5.get("type", "")) == "graph.input":
				input_port = String(n5.get("id", ""))
		_check(not input_port.is_empty(), "子图自动生成了输入节点")
		var wired := false
		for item6 in store.doc.get("edges", []):
			var e6: Dictionary = item6
			if String(e6.get("to", "")) == sub2 and String(e6.get("to_port", "")) == input_port:
				wired = true
		_check(wired, "父图原来的输入连线接到了子图输入口")
		var img2: Variant = FxGraphRunner.new().run(store.doc, 0.0).get("image")
		_check(img2 is Image, "带边界端口的子图在真实图里能出图")

	# 撤销：打包/解包都是单步
	_check(store.can_undo(), "打包解包留下了撤销点")


# ================= 工具 =================

func _node_types(doc: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for item in doc.get("nodes", []):
		out.append(String((item as Dictionary).get("type", "")))
	return out


func value_of(raw: Variant) -> float:
	if raw is float or raw is int:
		return float(raw)
	return 0.0


func _png_size(path: String) -> Vector2i:
	if not FileAccess.file_exists(path):
		return Vector2i.ZERO
	var image := Image.load_from_file(path)
	return image.get_size() if image != null else Vector2i.ZERO


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
	FxOpsSubgraph.clear_cache()
	FxPluginHost.shutdown()
	quit(code)
