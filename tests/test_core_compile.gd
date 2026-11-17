extends SceneTree
## IR 编译与结构剪枝：把「用户第 3 点」钉成可复算的断言。
##
##   · DAG 拓扑序、Live/Dead 判活、汇点一律保留（含导出副作用节点）
##   · 编译期常量折叠真的省掉一次算子调用，且结果与原求值一致
##   · 两条路径（有计划 / 无计划）最终图像逐像素相同、数值读数相同
##   · 计划与文档失配时自动关闭剪枝；插件停用 = 空计划 = 原行为
##   · 端口类型不匹配 / 环能被报出来，且归属插件层
##   · 103 节点示范工程实测 |Reachable(output)| 并打印
##
## 运行：
##   godot --headless --path . --script res://tests/test_core_compile.gd

var failures: Array[String] = []


func _initialize() -> void:
	print("== IR 编译 / 结构剪枝测试 ==")
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	var doc := _build_doc()

	# ---- 1. 计划结构 ----
	var plan := FxIRCompiler.compile(doc, ["m"])
	var s: Dictionary = plan.get("stats", {})
	_check(int(s.get("total", 0)) == 5, "编译覆盖 5 个节点")
	_check(int(s.get("edges", 0)) == 1, "识别出 1 条有效连线")
	_check(int(s.get("cycles", 0)) == 0, "无环图能完成拓扑排序")
	_check(int(s.get("type_errors", 0)) == 0, "合法连线不报类型错误")
	var order: Array = plan.get("order", [])
	_check(order.size() == 5 and order.find("src") < order.find("sink"),
		"拓扑序保证 src 在 sink 之前（依赖在前）")

	# ---- 2. Live / Dead ----
	var live: Dictionary = plan.get("live", {})
	var dead: Array = plan.get("dead", [])
	_check(live.has("src") and live.has("m") and live.has("sink"),
		"输出链 / 预览根 / 汇点都在 Live 里")
	_check(dead.size() == 2 and dead.has("d1") and dead.has("d2"),
		"两个纯数据旁支被判为可剪节点")
	_check(int(s.get("reachable_output", 0)) == 1, "输出链规模 = 1（示范用的单节点链）")
	var sinks: Array = plan.get("sinks", [])
	_check(sinks.has("sink"), "evaluate_always 汇点进入计划，一个都不剪")

	# ---- 3. 常量折叠 ----
	var constants: Dictionary = plan.get("constants", {})
	_check(int(s.get("foldable", 0)) >= 1 and constants.has("m"),
		"无入边、无关键帧的纯数值节点被编译期折叠")
	if constants.has("m"):
		var folded: Dictionary = constants["m"]
		_check(absf(float(folded.get("number", -999.0)) - 5.0) < 0.0001,
			"折叠结果正确：2 + 3 = 5")
		_check(not _has_object_value(folded),
			"折叠只收标量类输出，绝不预算图像")

	# ---- 4. 两条路径一致：有/无计划的图像与数值逐字相同 ----
	var plain := FxGraphRunner.new()
	plain.capture_previews = true
	plain.preview_roots = ["m"]
	var r_plain := plain.run(doc, 0.0)
	var ired := FxGraphRunner.new()
	ired.capture_previews = true
	ired.preview_roots = ["m"]
	ired.compile_plan = plan
	var r_ir := ired.run(doc, 0.0)
	var img_plain: Variant = r_plain.get("image")
	var img_ir: Variant = r_ir.get("image")
	_check(img_plain is Image and img_ir is Image, "两条路径都产出最终图像")
	if img_plain is Image and img_ir is Image:
		_check((img_plain as Image).get_data() == (img_ir as Image).get_data(),
			"剪枝后最终图像逐像素一致（预览 / 最终渲染不分叉）")
	var v_plain: Dictionary = r_plain.get("node_values", {})
	var v_ir: Dictionary = r_ir.get("node_values", {})
	_check(_sample_text(v_plain.get("m", [])) == _sample_text(v_ir.get("m", [])) \
			and _sample_text(v_ir.get("m", [])).contains("5"),
		"常量折叠后数值读数仍在（没有把上一轮的修复剪掉）")
	var st_plain: Dictionary = r_plain.get("stats", {})
	var st_ir: Dictionary = r_ir.get("stats", {})
	_check(int(st_ir.get("folded", 0)) >= 1, "求值器确实取用了编译期常量")
	_check(int(st_ir.get("steps", 0)) < int(st_plain.get("steps", 0)),
		"常量折叠真的少调一次算子（steps %d → %d）" % [
			int(st_plain.get("steps", 0)), int(st_ir.get("steps", 0))])
	_check(int(st_ir.get("plan_live", 0)) == int(s.get("live", 0)),
		"统计里带回计划判定的 Live 规模")

	# ---- 5. Dead 短路：显式单点求值时生效 ----
	var pruned_probe := FxGraphRunner.new()
	pruned_probe.compile_plan = plan
	var dead_result := pruned_probe.evaluate_node(doc, "d1", 0.0)
	_check(dead_result.is_empty(), "可剪节点被显式求值时短路，不跑图像算子")

	# ---- 6. 计划与文档失配 → 自动关闭剪枝 ----
	var changed := doc.duplicate(true)
	(changed["nodes"] as Array).append({
		"id": "new1", "type": "image.gradient", "params": {},
	})
	var stale := FxGraphRunner.new()
	stale.compile_plan = plan
	stale.preview_roots = ["m"]
	var r_stale := stale.run(changed, 0.0)
	var st_stale: Dictionary = r_stale.get("stats", {})
	_check(int(st_stale.get("plan_live", 0)) == 0 and int(st_stale.get("folded", 0)) == 0,
		"节点集合变了：旧计划自动作废，不误剪新文档")
	var img_stale: Variant = r_stale.get("image")
	_check(img_stale is Image, "计划作废后仍走原求值路径，图像照常产出")

	# ---- 7. 插件停用 = 空计划 = 原行为 ----
	var no_plugin := FxGraphRunner.new()
	no_plugin.capture_previews = true
	no_plugin.preview_roots = ["m"]
	no_plugin.compile_plan = {}
	var r_off := no_plugin.run(doc, 0.0)
	var st_off: Dictionary = r_off.get("stats", {})
	_check(int(st_off.get("folded", 0)) == 0 and int(st_off.get("pruned", 0)) == 0,
		"空计划下所有剪枝分支关闭（删掉 core.compile 也能跑）")
	var img_off: Variant = r_off.get("image")
	if img_off is Image and img_plain is Image:
		_check((img_off as Image).get_data() == (img_plain as Image).get_data(),
			"空计划与未剪枝路径结果完全一致")

	# ---- 8. 汇点里的导出副作用节点必须保留（只编译，不求值）----
	var exp_doc := FxGraphDoc.create("副作用")
	(exp_doc["nodes"] as Array).append({
		"id": "exp", "type": "io.export_sequence", "params": {},
	})
	exp_doc["output"] = ""
	var exp_plan := FxIRCompiler.compile(exp_doc, [])
	_check((exp_plan.get("sinks", []) as Array).has("exp") \
			and (exp_plan.get("live", {}) as Dictionary).has("exp"),
		"导出节点是根，绝不因「不连输出」被剪掉")

	# ---- 9. 类型检查 / 环检测 ----
	var bad := doc.duplicate(true)
	(bad["edges"] as Array).append({
		"from": "src", "from_port": "image", "to": "m", "to_port": "a",
	})
	var bad_plan := FxIRCompiler.compile(bad, ["m"])
	_check(int((bad_plan.get("stats", {}) as Dictionary).get("type_errors", 0)) >= 1,
		"image → number 的类型不匹配被报出（归属插件层）")
	var cyc := doc.duplicate(true)
	(cyc["edges"] as Array).append({
		"from": "sink", "from_port": "image", "to": "src", "to_port": "out_width",
	})
	var cyc_plan := FxIRCompiler.compile(cyc, ["m"])
	_check(int((cyc_plan.get("stats", {}) as Dictionary).get("cycles", 0)) >= 1,
		"环不能被拓扑排序，报告里单列出来")

	# ---- 10. 103 节点示范工程：量出真实收益上界 ----
	var raw := FileAccess.get_file_as_string("res://examples/demo/示范工程.fxgraph")
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary:
		var demo_plan := FxIRCompiler.compile(parsed as Dictionary, [])
		print(FxIRCompiler.explain(demo_plan, "示范工程 IR（103 节点实测）"))
		var ds: Dictionary = demo_plan.get("stats", {})
		var dfs: Dictionary = demo_plan.get("frame_stats", {})
		_check(int(ds.get("total", 0)) == 103, "示范工程按 103 节点编译")
		_check(int(ds.get("edges", 0)) == 81, "示范工程识别出 81 条连线")
		dfs = demo_plan.get("frame_stats", {})
		_check(int(dfs.get("frames", 0)) == 60 and int(dfs.get("tracks", 0)) == 3,
			"示范工程 60 帧 / 3 条轨道纳入帧指纹")
	else:
		_check(false, "示范工程可读")

	# ---- 11. 帧区间分段：step 保持段只算一次 ----
	var seg := FxGraphDoc.create("帧段测试")
	(seg["nodes"] as Array).append({
		"id": "num", "type": "math.number",
		"params": {"op": "add", "b": 1.0,
			"a": {"track": [[0.0, 2.0], [0.5, 5.0]], "interp": "step"}},
	})
	seg["output"] = "num"
	FxGraphDoc.set_timeline(seg, 10, 1.0, false)
	var seg_plan := FxIRCompiler.compile(seg, ["num"])
	var sfs: Dictionary = seg_plan.get("frame_stats", {})
	_check(int(sfs.get("frames", 0)) == 10 and int(sfs.get("tracks", 0)) == 1,
		"10 帧 / 1 条 step 轨道被编译")
	_check(int(sfs.get("distinct_keys", 0)) == 2,
		"step 轨道自然切出 2 个帧段（0.0–0.4 / 0.5–0.9）")
	_check(int(sfs.get("reusable_frames", 0)) == 8,
		"其中 8 帧与上一段采样值相同，可跨帧复用")
	var seg_tracks: Array = seg_plan.get("plan_tracks", [])
	_check(FxTracks.key_of(seg_tracks, 0.0) == FxTracks.key_of(seg_tracks, 0.4),
		"同一保持段内帧指纹相同")
	_check(FxTracks.key_of(seg_tracks, 0.0) != FxTracks.key_of(seg_tracks, 0.5),
		"跨过关键帧后指纹改变")
	_check((seg_plan.get("clock_nodes", {}) as Dictionary).is_empty(),
		"纯数值轨道节点不在时钟闭包里，允许按段缓存")

	# 带计划 / 无计划各跑 10 帧，逐帧比对数值读数
	var seg_on := FxGraphRunner.new()
	seg_on.capture_previews = true
	seg_on.preview_roots = ["num"]
	seg_on.compile_plan = seg_plan
	var seg_off := FxGraphRunner.new()
	seg_off.capture_previews = true
	seg_off.preview_roots = ["num"]
	var total_hits := 0
	var all_same := true
	var first_value := ""
	var sixth_value := ""
	for f in range(10):
		var time := float(f) / 10.0
		var on_result := seg_on.run(seg, time)
		var off_result := seg_off.run(seg, time)
		var on_val := _sample_text((on_result.get("node_values", {}) as Dictionary).get("num", []))
		var off_val := _sample_text((off_result.get("node_values", {}) as Dictionary).get("num", []))
		if on_val != off_val:
			all_same = false
		total_hits += int((on_result.get("stats", {}) as Dictionary).get("segment_hits", 0))
		if f == 0:
			first_value = on_val
		elif f == 5:
			sixth_value = on_val
	_check(all_same, "十条帧上，按段缓存与未剪枝路径的数值读数逐字一致")
	_check(total_hits >= 8, "保持段内真的命中跨帧缓存（segment_hits = %d）" % total_hits)
	_check(first_value.contains("3") and sixth_value.contains("6"),
		"采样正确：前段 2+1=3，后段 5+1=6（实得 %s / %s）" % [first_value, sixth_value])

	# ---- 12. 单帧常量轨道 = 全时间轴一段 ----
	var const_doc := FxGraphDoc.create("常量轨道")
	(const_doc["nodes"] as Array).append({
		"id": "num", "type": "math.number",
		"params": {"op": "add", "b": 1.0,
			"a": {"track": [[0.0, 7.0]]}},
	})
	const_doc["output"] = "num"
	FxGraphDoc.set_timeline(const_doc, 10, 1.0, false)
	var const_plan := FxIRCompiler.compile(const_doc, ["num"])
	var cfs: Dictionary = const_plan.get("frame_stats", {})
	_check(int(cfs.get("distinct_keys", 0)) == 1 and int(cfs.get("reusable_frames", 0)) == 9,
		"单帧轨道是常量：10 帧只有 1 段，9 帧可复用")

	# ---- 13. 空计划：帧分段统计归零，原行为不变 ----
	var off_stats: Dictionary = seg_off.run(seg, 0.1).get("stats", {})
	_check(int(off_stats.get("segment_hits", 0)) == 0 			and int(off_stats.get("frame_tracks", 0)) == 0,
		"没有计划时帧分段完全关闭")

	_quit(0 if failures.is_empty() else 1)


func _build_doc() -> Dictionary:
	var doc := FxGraphDoc.create("IR 测试")
	(doc["nodes"] as Array).append({
		"id": "src", "type": "image.gradient", "params": {},
	})
	(doc["nodes"] as Array).append({
		"id": "m", "type": "math.number",
		"params": {"op": "add", "a": 2.0, "b": 3.0},
	})
	(doc["nodes"] as Array).append({
		"id": "d1", "type": "image.gradient", "params": {},
	})
	(doc["nodes"] as Array).append({
		"id": "d2", "type": "image.gradient", "params": {},
	})
	(doc["nodes"] as Array).append({
		"id": "sink", "type": "output.preview", "params": {},
	})
	doc["output"] = "src"
	FxGraphDoc.connect_ports(doc, "src", "image", "sink", "image")
	return doc


static func _has_object_value(out: Dictionary) -> bool:
	for value in out.values():
		if value is Object or value is Image or value is Dictionary:
			return true
	return false


## 读数现在是结构化样本 `[{port, type, value, text}]`；断言只关心文本那一项。
func _sample_text(raw: Variant) -> String:
	if raw is Array and not (raw as Array).is_empty():
		return String(((raw as Array)[0] as Dictionary).get("text", ""))
	return String(raw)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
