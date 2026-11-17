class_name FxIRCompiler
extends RefCounted
## 图编译器（插件层 IR）：把节点图降级成 DAG 指令序列 + 剪枝计划。
##
## 它**不接管求值**。产出的计划是一张纯数据字典，由 FxGraphRunner 自愿消费：
##
##   · order        拓扑序的指令序列（依赖在前），也是 IR 的线性化形态
##   · live / dead  按冻结判活标准算出的活节点 / 可剪节点
##   · sinks        所有 evaluate_always 汇点，一个都不剪（含 6 个有副作用的导出节点）
##   · static_nodes 时间无关子图，可跨帧复用（不是删除）
##   · constants    编译期常量折叠的算子输出（只收标量类，绝不含 Image/Object）
##   · type_errors  端口类型不匹配的存量连线（归因插件：节点定义或手写 JSON 的错）
##   · cycles       不能拓扑排序的部分
##
## 为什么计划是 Dictionary 而不是一个 FxGraphIR 类型：求值器在 core.graph，
## 编译器在 core.compile，两边都只认数据形状。插件停用 → 计划为空 → 求值器
## 走原行为，不认识任何编译器类名，也就不会出现「删一个插件基座编译不过」。
##
## 两条路径（实时预览 / 最终渲染）共用同一份计划与同一个算子表：
## 计划只决定「跑不跑 / 能不能直接取常量」，从不改变单个算子的结果。

const KEY_LIVE := "live"
const KEY_DEAD := "dead"
const KEY_SINKS := "sinks"
const KEY_CONSTANTS := "constants"
const KEY_FOLD_PARAMS := "fold_params"

## 只有这些输出类型的节点才允许编译期预算：其余（图像 / 纹理 / any / exec）
## 一律跳过，连算子都不调用 —— 否则编译一张 103 节点的图会先生成几十张全尺寸图。
const NON_SCALAR_PORTS := ["image", "image_object", "texture", "any", "exec", ""]


## 主入口。roots = 编辑器给的 preview_roots（展开 ∪ 选中）。
static func compile(doc: Dictionary, roots: Array = [], allow_fold: bool = true) -> Dictionary:
	var nodes: Array = doc.get("nodes", [])
	var edges: Array = doc.get("edges", [])
	var ids: Array[String] = []
	var node_of: Dictionary = {}
	var def_of: Dictionary = {}
	for raw in nodes:
		if not raw is Dictionary:
			continue
		var nd: Dictionary = raw
		var id := String(nd.get("id", ""))
		if id.is_empty() or node_of.has(id):
			continue
		ids.append(id)
		node_of[id] = nd
		def_of[id] = FxCatalog.def(nd.get("type", ""))

	# ---- 依赖图（from → to）----
	var deps: Dictionary = {}       # to -> Array[String] 上游
	var adj: Dictionary = {}        # from -> Array[String] 下游
	for id in ids:
		deps[id] = []
		adj[id] = []
	var edge_rows: Array[Dictionary] = []
	for raw in edges:
		if not raw is Dictionary:
			continue
		var e: Dictionary = raw
		var from := String(e.get("from", ""))
		var to := String(e.get("to", ""))
		if from.is_empty() or to.is_empty() or from == to \
				or not node_of.has(from) or not node_of.has(to):
			continue
		edge_rows.append(e)
		var ups: Array = deps[to]
		if not ups.has(from):
			ups.append(from)
		var downs: Array = adj[from]
		if not downs.has(to):
			downs.append(to)

	# ---- DAG 线性化（Kahn，按文档顺序稳定）----
	var indeg: Dictionary = {}
	for id in ids:
		indeg[id] = (deps[id] as Array).size()
	var queue: Array[String] = []
	for id in ids:
		if int(indeg[id]) == 0:
			queue.append(id)
	var order: Array[String] = []
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		order.append(cur)
		for raw_next in (adj[cur] as Array):
			var nxt := String(raw_next)
			indeg[nxt] = int(indeg.get(nxt, 0)) - 1
			if int(indeg[nxt]) == 0:
				queue.append(nxt)
	var cycles: Array = []
	if order.size() != ids.size():
		var stuck: Array[String] = []
		for id in ids:
			if not order.has(id):
				stuck.append(id)
		cycles.append(stuck)

	# ---- 根集合 ----
	# 冻结标准：Live = Reachable(output) ∪ ⋃Reachable(preview_roots) ∪ 汇点 ∪ 执行流节点。
	# 后两项是执行器语义要求的精确化：汇点是「用户要看的预览」，导出汇点还有写文件副作用；
	# 执行流节点由 _exec_entries() 无条件驱动，若不算根，它们的上游会被 dead 短路掉。
	var sinks: Array[String] = []
	var exec_nodes: Array[String] = []
	for id in ids:
		var d: FxNodeDef = def_of[id]
		if d == null:
			continue
		if d.evaluate_always:
			sinks.append(id)
		if d.has_exec_in:
			exec_nodes.append(id)
	sinks.sort_custom(func(a: String, b: String) -> bool:
		return order.find(a) < order.find(b))
	var root_ids: Array[String] = []
	var output_id := FxGraphDoc.output_id(doc)
	if not output_id.is_empty() and node_of.has(output_id):
		root_ids.append(output_id)
	for raw_root in roots:
		var rid := String(raw_root)
		if not rid.is_empty() and node_of.has(rid) and not root_ids.has(rid):
			root_ids.append(rid)
	for id in sinks:
		if not root_ids.has(id):
			root_ids.append(id)
	for id in exec_nodes:
		if not root_ids.has(id):
			root_ids.append(id)

	var live: Dictionary = _reachable(root_ids, deps)
	var reachable_output := _reachable([output_id] if node_of.has(output_id) else [], deps).size()
	var dead: Array[String] = []
	for id in ids:
		if not live.has(id):
			dead.append(id)

	# ---- 端口类型检查（存量坏连线的归因）----
	var type_errors: Array[Dictionary] = []
	for e in edge_rows:
		var from := String(e.get("from", ""))
		var to := String(e.get("to", ""))
		var fd: FxNodeDef = def_of[from]
		var td: FxNodeDef = def_of[to]
		if fd == null or td == null:
			continue
		var fports := FxCatalog.ports(fd, (node_of[from] as Dictionary).get("params", {}))
		var tports := FxCatalog.ports(td, (node_of[to] as Dictionary).get("params", {}))
		var fs := FxCatalog.find_port(fports.get("outputs", []), String(e.get("from_port", "")))
		var ts := FxCatalog.find_port(tports.get("inputs", []), String(e.get("to_port", "")))
		if fs.is_empty() or ts.is_empty():
			type_errors.append({
				"from": from, "to": to, "reason": "missing_port",
				"message": "连线 %s → %s 引用了不存在的端口" % [from, to],
			})
		elif not FxPortType.can_connect(fs.get("type", ""), ts.get("type", "")):
			type_errors.append({
				"from": from, "to": to, "reason": "type_mismatch",
				"message": "连线 %s → %s 类型不匹配：%s → %s" % [
					from, to, str(fs.get("type", "")), str(ts.get("type", ""))],
			})

	# ---- 时间相关性传播（与 FxGraphRunner._build_time_dependence 同语义）----
	var time_dep: Dictionary = {}
	var tq: Array[String] = []
	for id in ids:
		var d: FxNodeDef = def_of[id]
		if d == null:
			continue
		var nd: Dictionary = node_of[id]
		var dependent := d.has_exec_in or FxOpRegistry.is_time_dependent(d.op) \
				or not FxTracks.collect(nd.get("params", {})).is_empty()
		if dependent:
			time_dep[id] = true
			tq.append(id)
	while not tq.is_empty():
		var cur: String = tq.pop_front()
		for raw_next in (adj[cur] as Array):
			var nxt := String(raw_next)
			if not time_dep.has(nxt):
				time_dep[nxt] = true
				tq.append(nxt)
	var static_nodes: Dictionary = {}
	for id in ids:
		if not time_dep.has(id):
			static_nodes[id] = true

	# ---- 常量折叠 ----
	var foldable: Dictionary = {}
	var constants: Dictionary = {}
	var fold_params: Dictionary = {}
	if allow_fold:
		for id in ids:
			if not static_nodes.has(id) or not (deps[id] as Array).is_empty():
				continue
			var d: FxNodeDef = def_of[id]
			if d == null or not d.cacheable or d.has_exec_in or d.evaluate_always or d.gpu:
				continue
			if not _scalar_outputs_only(d):
				continue
			var folded := _try_fold(id, node_of[id] as Dictionary, d, doc)
			if folded.is_empty():
				continue
			foldable[id] = true
			constants[id] = folded["out"]
			fold_params[id] = folded["params"]

	# ---- 帧区间分段：全图轨道 + 时钟闭包 ----
	# 轨道采样值相同的两帧，「不读时钟」的节点输出必然相同，可跨帧复用。
	# 把轨道定义放进计划，由 FxTracks.key_of(tracks, 实际 t) 在运行时算指纹 ——
	# 用实际 t 而不是整数帧号，避免「交互时 t 落在两帧之间」被近似到错误段。
	var plan_tracks: Array = []
	for id in ids:
		var nd: Dictionary = node_of[id]
		var collected := FxTracks.collect(nd.get("params", {}))
		for path in collected.keys():
			plan_tracks.append(collected[path])

	# 直接读时钟 / 执行流 / 汇点 / gpu / 非 cacheable 的节点，以及它们的**全部下游**：
	# 这些节点即使轨道采样值不变也可能变，永远不能按帧指纹缓存。
	var clock: Dictionary = {}
	var cq: Array[String] = []
	for id in ids:
		var d: FxNodeDef = def_of[id]
		if d == null:
			continue
		if d.has_exec_in or d.evaluate_always or d.gpu or not d.cacheable \
				or FxOpRegistry.is_time_dependent(d.op):
			clock[id] = true
			cq.append(id)
	while not cq.is_empty():
		var cur: String = cq.pop_front()
		for raw_next in (adj[cur] as Array):
			var nxt := String(raw_next)
			if not clock.has(nxt):
				clock[nxt] = true
				cq.append(nxt)

	# 按整数帧预采一次，只用于报告与量化（运行时用实际 t 重算，不读这张表）。
	var tl := FxGraphDoc.timeline(doc)
	var fps := maxi(int(tl.get("fps", 30)), 1)
	var duration := maxf(float(tl.get("duration", 1.0)), 0.001)
	var loop := bool(tl.get("loop", true))
	var frame_count := maxi(1, int(round(duration * float(fps))))
	var distinct: Dictionary = {}
	var reusable := 0
	var prev_key := ""
	for f in range(frame_count):
		var t_raw := float(f) / float(fps)
		var t_frame := fmod(t_raw, duration) if loop else clampf(t_raw, 0.0, duration)
		var key := FxTracks.key_of(plan_tracks, t_frame)
		distinct[key] = true
		if f > 0 and key == prev_key:
			reusable += 1
		prev_key = key
	var frame_stats := {
		"frames": frame_count,
		"tracks": plan_tracks.size(),
		"distinct_keys": distinct.size(),
		"reusable_frames": reusable,
		"clock_nodes": clock.size(),
	}

	# 计划与文档的绑定键：只认 id 集合（参数变化不改变它，但换节点/删节点会）。
	# 求值器在 _begin 里用同样算法复算，不一致就整份计划作废，避免误剪新文档。
	var sorted_ids: Array[String] = ids.duplicate()
	sorted_ids.sort()
	var ids_hash := hash(",".join(PackedStringArray(sorted_ids)))
	var stats := {
		"total": ids.size(),
		"live": live.size(),
		"dead": dead.size(),
		"sinks": sinks.size(),
		"exec": exec_nodes.size(),
		"static": static_nodes.size(),
		"foldable": foldable.size(),
		"edges": edge_rows.size(),
		"order": order.size(),
		"reachable_output": reachable_output,
		"type_errors": type_errors.size(),
		"cycles": cycles.size(),
	}
	return {
		"ids_hash": ids_hash,
		"signature": hash(nodes) * 31 + hash(edges),
		"order": order,
		KEY_LIVE: live,
		KEY_DEAD: dead,
		KEY_SINKS: sinks,
		"exec_nodes": exec_nodes,
		"static_nodes": static_nodes,
		"foldable": foldable,
		KEY_CONSTANTS: constants,
		KEY_FOLD_PARAMS: fold_params,
		"type_errors": type_errors,
		"cycles": cycles,
		"plan_tracks": plan_tracks,
		"clock_nodes": clock,
		"frame_stats": frame_stats,
		"stats": stats,
	}


## 从若干根沿入边反向走到的全部节点（根自己也算）。
static func _reachable(roots: Array, deps: Dictionary) -> Dictionary:
	var seen: Dictionary = {}
	var stack: Array[String] = []
	for raw in roots:
		var id := String(raw)
		if not id.is_empty():
			stack.append(id)
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		if seen.has(cur) or not deps.has(cur):
			continue
		seen[cur] = true
		for raw_up in (deps[cur] as Array):
			stack.append(String(raw_up))
	return seen


static func _scalar_outputs_only(d: FxNodeDef) -> bool:
	for raw in d.outputs:
		var p: Dictionary = raw
		var port_type := String(StringName(p.get("type", ""))).to_lower()
		if NON_SCALAR_PORTS.has(port_type):
			return false
	return not d.outputs.is_empty()


## 用一个临时 ctx 预算常量节点。只接受「无警告 + 输出全是标量」的结果；
## 任何一步不满足就不折叠，求值器照常调算子 —— 折叠永远是可选加速，不是语义来源。
static func _try_fold(_id: String, nd: Dictionary, d: FxNodeDef, doc: Dictionary) -> Dictionary:
	var op := FxOpRegistry.get_op(d.op)
	if not op.is_valid():
		return {}
	var ctx := FxEvalContext.new()
	ctx.doc = doc
	ctx.canvas = FxGraphDoc.canvas(doc)
	var tl := FxGraphDoc.timeline(doc)
	ctx.fps = float(tl.get("fps", 30))
	ctx.duration = maxf(0.001, float(tl.get("duration", 1.0)))
	ctx.loop = bool(tl.get("loop", true))
	ctx.t = 0.0
	ctx.seed = int(FxGraphDoc.meta_value(doc, "seed", 1))
	ctx.quality = 1
	ctx.operator_quality = 1.0
	ctx.capture_previews = false
	var params := FxCatalog.default_params(d)
	var raw_params: Dictionary = nd.get("params", {})
	for key in raw_params.keys():
		var value: Variant = raw_params[key]
		params[String(key)] = value.duplicate(true) if value is Array or value is Dictionary else value
	params = FxTracks.resolve_layer(params, 0.0)
	var result: Variant = op.call(ctx, nd, d, {}, params)
	if not ctx.warnings.is_empty() or not result is Dictionary:
		return {}
	var out: Dictionary = result
	if out.is_empty():
		return {}
	for value in out.values():
		if not _is_scalar(value):
			return {}
	return {"out": out.duplicate(true), "params": params.duplicate(true)}


static func _is_scalar(value: Variant) -> bool:
	if value is float or value is int or value is bool or value is Vector2 \
			or value is Color or value is String or value is StringName:
		return true
	if value is Array:
		for item in (value as Array):
			if not _is_scalar(item):
				return false
		return true
	return false


## 人类可读报告（diag.compile 用）。只写从数字能直接读出来的结论，不猜动机。
static func explain(plan: Dictionary, title: String = "IR 编译与剪枝") -> String:
	var lines: Array[String] = []
	lines.append("== %s ==" % title)
	if plan.is_empty():
		lines.append("没有可用的编译计划：core.compile 未启用，或当前文档为空。")
		lines.append("求值器会自动走未剪枝的原路径 —— 停用插件不应该改变结果。")
		return "\n".join(PackedStringArray(lines))
	var s: Dictionary = plan.get("stats", {})
	lines.append("节点 %d · 连线 %d · 拓扑序 %d · 环 %d · 类型不匹配 %d" % [
		int(s.get("total", 0)), int(s.get("edges", 0)), int(s.get("order", 0)),
		int(s.get("cycles", 0)), int(s.get("type_errors", 0)),
	])
	lines.append("Live %d / Dead %d（输出链 %d · 汇点 %d · 执行流 %d）" % [
		int(s.get("live", 0)), int(s.get("dead", 0)),
		int(s.get("reachable_output", 0)), int(s.get("sinks", 0)), int(s.get("exec", 0)),
	])
	lines.append("时间无关 %d · 编译期折叠 %d" % [
		int(s.get("static", 0)), int(s.get("foldable", 0)),
	])
	var fs: Dictionary = plan.get("frame_stats", {})
	lines.append("帧指纹：%d 帧 / %d 条轨道 / %d 个不同段（可跨帧复用 %d 帧）· 时钟节点 %d" % [
		int(fs.get("frames", 0)), int(fs.get("tracks", 0)),
		int(fs.get("distinct_keys", 0)), int(fs.get("reusable_frames", 0)),
		int(fs.get("clock_nodes", 0)),
	])
	if int(fs.get("tracks", 0)) == 0:
		lines.append("· 全图无关键帧：时间轴只有一段，除时钟/执行流节点外整图只需算一次。")
	var dead: Array = plan.get(KEY_DEAD, [])
	if not dead.is_empty():
		var sample: Array[String] = []
		for i in range(mini(dead.size(), 6)):
			sample.append(String(dead[i]))
		lines.append("可剪节点：%s%s" % [", ".join(PackedStringArray(sample)),
				" …" if dead.size() > 6 else ""])
	var errors: Array = plan.get("type_errors", [])
	for raw in errors:
		var e: Dictionary = raw
		lines.append("! [插件] %s" % String(e.get("message", "")))
	for raw_cycle in plan.get("cycles", []):
		lines.append("! [插件] 环：%s" % str(raw_cycle))
	var total := int(s.get("total", 0))
	var live_n := int(s.get("live", 0))
	if total > 0 and live_n == total:
		lines.append("· 输出链/汇点覆盖全图，结构剪枝收益为 0 —— 这是图的性质，不是剪枝失效。")
	elif total > 0:
		lines.append("· 结构剪枝上界：%.1f%% 节点本帧可以不参与求值。" % [
			100.0 * float(total - live_n) / float(total)])
	lines.append("注意：汇点（含 6 个导出节点）与执行流节点一律保留，剪枝只针对纯数据旁支。")
	return "\n".join(PackedStringArray(lines))
