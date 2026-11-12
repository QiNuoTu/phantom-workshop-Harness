class_name FxGraphRunner
extends RefCounted
## 图执行器：拉取式数据流 + 可选执行流。
##
## 规则：
##   · 图像/数值沿数据端口传递；没有 exec 端口的节点是纯函数，被需要时才求值（带缓存）。
##   · 有 exec 端口的节点由执行流驱动；控制算子（分支/循环）通过 ctx.follow() 决定接下来跑谁。
##   · 执行流跑完后，再拉取输出节点，保证图层拿到的是本帧最终结果。
##
## 执行器只认识三件事：文档结构、目录里的定义、op_id 对应的 Callable。
## 它不认识 blur / branch / output.final 中的任何一个 —— 加节点类型不需要改这个文件。
##
## 预览：每个节点求值后取第一张 image 输出，缩小到 preview_limit 存进 ctx.previews
## 并发 node_previewed 信号。核心不创建 Texture，也不碰 UI。

signal node_previewed(node_id: StringName, image: Image)
signal run_finished(stats: Dictionary)

var doc: Dictionary = {}
var ctx: FxEvalContext
var capture_previews: bool = true
var preview_limit: int = 128
## 空 = 所有节点都发预览；播放时可只保留选中节点与输出节点，省掉纹理上传。
var preview_nodes: Dictionary = {}
## 跨帧缓存：时间无关的子图只算一次，参数/结构变化时由调用方 invalidate_cache()。
var static_cache_enabled: bool = true
## 0 = 交互预览（模糊等中间算子可走快速路径）；1 = 精确（导出默认）。
## 注意：输出链与配方渲染不读它做降采样，播放中的大图始终是全分辨率。
var quality: int = 1
## 轨道 solo/mute 谓词：(node_id: String, path: String) -> bool。
## 由渲染服务从 FxDocumentStore 注入，核心不依赖 UI 状态的具体存法。
var track_enabled: Callable = Callable()
## 由渲染服务从质量策略代理注入；算子通过 ctx.operator_quality / ctx.option() 读取。
## 核心不知道有哪几种质量策略，也不认识任何具体旋钮。
var operator_quality: float = 1.0
var options: Dictionary = {}

## 子图边界：run() 之前填 boundary_inputs（键 = 子图输入端口 id），
## run() 之后读 boundary_outputs（键 = 子图输出端口 id）。普通图两者都空。
var boundary_inputs: Dictionary = {}
var boundary_outputs: Dictionary = {}
## 父级子图链：嵌套求值时把「已经进入过哪些子图」传给内层执行器。
## 这是每次 run 的输入参数，不是共享状态；顶层求值时为空。
var inherited_subgraph_stack: Array[String] = []
var _last_stats: Dictionary = {}
var _start_usec: int = 0
var _static_cache: Dictionary = {}
var _cache_hits: int = 0
## 文档指纹：参数/连线被任何代码直接改动时，跨帧缓存也能自动失效。
var _doc_signature: int = 0
## 结构与参数指纹（不含时间）：易变/时间相关表按它缓存。
var _structure_signature: int = -1
var _volatile_cache: Dictionary = {}
var _time_cache: Dictionary = {}
## 每帧建一次的结构索引。原来是「每个节点求值都线性扫一遍 nodes/edges」，
## 103 节点的工程里一帧要几万次字符串比较；换成 O(1) 查表后解析开销大幅下降。
## 端口表也按节点缓存：同一帧内参数不变，重复调动态 provider 纯属浪费。
var _index_nodes: Dictionary = {}
var _index_edges: Dictionary = {}
var _index_adj: Dictionary = {}
var _index_ports: Dictionary = {}
## 结构索引的缓存键：整份 nodes/edges 的 C++ 递归哈希（103 节点实测 0.034ms）。
## 文档不变（只是时间推进）时跨帧复用，不每帧重建；结构或参数一变键就变。
var _index_key: int = 0
var _index_valid: bool = false
## 诊断计数：整个预渲染段重建了几次索引（理想是每线程 1 次）。
var index_rebuilds: int = 0


## 执行一帧。t 为秒；循环图会按 duration 取模。
## 返回 {image, previews, stats, warnings}。
func run(p_doc: Dictionary, t: float, signature: int = -1) -> Dictionary:
	_begin(p_doc, t, signature)
	_exec_entries()
	var output := String(FxGraphDoc.output_id(doc))
	var final_image: Image = null
	if not output.is_empty():
		var out := _eval(output)
		var def := FxCatalog.def(_node(output).get("type", ""))
		if def != null:
			final_image = _first_image(out, def)
	else:
		ctx.warn("未指定输出节点")
	# 汇点节点（输出预览等）不一定接在输出链上，最后统一补跑一次，
	# 这样「旁支预览」也能拿到本帧图像。
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var node_id := String(node_data.get("id", ""))
		if node_id == output or ctx.outputs.has(node_id):
			continue
		var node_def := FxCatalog.def(node_data.get("type", ""))
		if node_def != null and node_def.evaluate_always:
			_eval(node_id)
	_end()
	return {
		"image": final_image,
		"previews": ctx.previews,
		"node_params": ctx.node_params,
		"stats": _last_stats,
		"warnings": ctx.warnings,
	}


## 只求值一个节点（参数面板/单节点预览用）。不跑执行流入口。
## p_doc 必须显式传入：runner 可能是新建的，成员 doc 还是空的。
func evaluate_node(p_doc: Dictionary, node_id: String, _t: float) -> Dictionary:
	_begin(p_doc, _t)
	var result: Dictionary = {}
	var node_data := _node(node_id)
	if node_data.is_empty():
		ctx.warn("节点不存在：%s" % node_id)
	else:
		var def := FxCatalog.def(node_data.get("type", ""))
		if def == null:
			ctx.warn("节点类型不存在：%s" % String(node_data.get("type", "")))
		elif def.has_exec_in:
			result = ctx.outputs.get(node_id, {})
			if result.is_empty():
				ctx.warn("节点 %s 由执行流驱动，单点预览需要先跑一次图" % node_id)
		else:
			result = _eval(node_id)
	_end()
	return result


func last_stats() -> Dictionary:
	return _last_stats


func invalidate_cache() -> void:
	_static_cache.clear()
	_cache_hits = 0
	_structure_signature = -1
	# 结构索引也可能因外部直接改 doc 而失效；下一次 _begin 强制重建。
	_index_valid = false


# ================= 生命周期 =================

func _begin(p_doc: Dictionary, t: float, signature: int = -1) -> void:
	doc = p_doc
	_start_usec = Time.get_ticks_usec()
	ctx = FxEvalContext.new()
	ctx.doc = doc
	ctx.canvas = FxGraphDoc.canvas(doc)
	var timeline := FxGraphDoc.timeline(doc)
	ctx.fps = float(timeline.get("fps", 30))
	ctx.duration = maxf(0.001, float(timeline.get("duration", 1.0)))
	ctx.loop = bool(timeline.get("loop", true))
	ctx.t = fmod(t, ctx.duration) if ctx.loop else clampf(t, 0.0, ctx.duration)
	ctx.seed = int(FxGraphDoc.meta_value(doc, "seed", 1))
	ctx.quality = quality
	ctx.operator_quality = operator_quality
	ctx.options = options.duplicate(true)
	ctx.capture_previews = capture_previews
	ctx.preview_limit = maxi(16, preview_limit)
	ctx.flow = Callable(self, "_follow")
	# 边界值只属于这一帧：子图每次被求值都从外层拿一份新的。
	ctx.subgraph_inputs = boundary_inputs.duplicate(true)
	ctx.subgraph_outputs = {}
	ctx.subgraph_stack = []
	for entry in inherited_subgraph_stack:
		ctx.subgraph_stack.append(String(entry))
	ctx.subgraph_runners = {}
	_cache_hits = 0
	_build_index()
	# 签名可以由调用方给（文档修订号）：省掉每帧 hash 整份文档。
	_doc_signature = signature if signature >= 0 else _signature_of(doc)
	# 易变/时间相关两张表只取决于结构与参数，不取决于时间：
	# 签名没变就复用，省掉每帧 O(节点 × 连线) 的两次图遍历。
	if _structure_signature != _doc_signature:
		_build_volatility()
		_build_time_dependence()
		_structure_signature = _doc_signature
		_volatile_cache = ctx.volatile
		_time_cache = ctx.time_dependent
	else:
		ctx.volatile = _volatile_cache
		ctx.time_dependent = _time_cache


func _end() -> void:
	var elapsed := 0
	if ctx != null:
		ctx.flow = Callable()
		# 子图输出节点写在这里；必须在清 ctx 之前抄出来。
		boundary_outputs = ctx.subgraph_outputs.duplicate(true)
		_last_stats = {
			"steps": ctx.steps,
			"nodes": ctx.outputs.size(),
			"previews": ctx.previews.size(),
			"loop_ticks": ctx.loop_ticks,
			"cache_hits": _cache_hits,
			"timings": ctx.timings,
			"warnings": ctx.warnings.size(),
			"ms": snappedf(float(Time.get_ticks_usec() - _start_usec) / 1000.0, 0.01),
		}
	run_finished.emit(_last_stats)


# ================= 结构索引 =================

func _build_index() -> void:
	# 端口表依赖节点参数（关键帧 / 动态 provider），每帧重建；
	# 结构三张表只依赖拓扑，按整表哈希跨帧复用 —— 60 帧预渲染只建 1 次。
	_index_ports.clear()
	var nodes: Array = doc.get("nodes", [])
	var edges: Array = doc.get("edges", [])
	var key := int(hash(nodes)) * 31 + int(hash(edges))
	if _index_valid and key == _index_key:
		return
	_index_nodes.clear()
	_index_edges.clear()
	_index_adj.clear()
	index_rebuilds += 1
	for item in nodes:
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		_index_nodes[id] = node_data
		if not _index_adj.has(id):
			_index_adj[id] = []
	for item in edges:
		var edge: Dictionary = item
		var from := String(edge.get("from", ""))
		var to := String(edge.get("to", ""))
		var port := String(edge.get("to_port", ""))
		# 与原 edge_into 一致：同一输入端口只认第一条连进来的边。
		var edge_key := to + "\u001F" + port
		if not _index_edges.has(edge_key):
			_index_edges[edge_key] = edge
		if not _index_adj.has(from):
			_index_adj[from] = []
		(_index_adj[from] as Array).append(to)
	_index_key = key
	_index_valid = true


func _node(node_id: String) -> Dictionary:
	return _index_nodes.get(node_id, {}) as Dictionary


func _edge_into(node_id: String, port_id: String) -> Dictionary:
	return _index_edges.get(node_id + "\u001F" + port_id, {}) as Dictionary


func _ports(node_id: String, node_data: Dictionary, def: FxNodeDef) -> Dictionary:
	if _index_ports.has(node_id):
		return _index_ports[node_id] as Dictionary
	var built := FxCatalog.ports(def, node_data.get("params", {}))
	_index_ports[node_id] = built
	return built


## 只对“会进缓存的节点”做签名：节点 id、类型、参数与全部连线。
## 成本远低于一次图像运算，却能让缓存对直接改 doc 的旧代码也安全。
func _signature_of(target: Dictionary) -> int:
	var sig := hash(target.get("edges", []))
	for item in target.get("nodes", []):
		var node_data: Dictionary = item
		sig = sig * 31 + hash(String(node_data.get("type", "")))
		sig = sig * 31 + hash(node_data.get("params", {}))
	return sig


## 静态缓存能力：节点自身可缓存，且没有绑定任何参数端口。
func _node_static_cacheable(node_data: Dictionary, def: FxNodeDef) -> bool:
	if def == null or not def.cacheable:
		return false
	for p in def.params:
		if bool(p.get("bindable", true)) \
				and not _edge_into(String(node_data.get("id", "")), String(p.get("id", ""))).is_empty():
			return false
	return true


## 易变传播：非缓存节点的所有下游都不可缓存。
## 否则循环里“索引 → 中间节点 → 变换”这条链会把第一轮的图缓存到最后一轮。
func _build_volatility() -> void:
	ctx.volatile.clear()
	var queue: Array[String] = []
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var def := FxCatalog.def(node_data.get("type", ""))
		if def != null and not _node_static_cacheable(node_data, def):
			var id := String(node_data.get("id", ""))
			ctx.volatile[id] = true
			queue.append(id)
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for downstream in (_index_adj.get(current, []) as Array):
			var to := String(downstream)
			if not ctx.volatile.has(to):
				ctx.volatile[to] = true
				queue.append(to)


## 时间相关性：自身参数有轨道、算子读时钟、或上游是时间相关的。
## 跨帧缓存只对“整条上游都与时间无关”的节点生效，避免把动画第一帧冻住。
func _build_time_dependence() -> void:
	ctx.time_dependent.clear()
	var queue: Array[String] = []
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		var def := FxCatalog.def(node_data.get("type", ""))
		if def == null:
			continue
		var dependent := def.has_exec_in or FxOpRegistry.is_time_dependent(def.op)
		if not dependent:
			var tracks := FxTracks.collect(node_data.get("params", {}))
			dependent = not tracks.is_empty()
		if dependent:
			ctx.time_dependent[id] = true
			queue.append(id)
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for downstream in (_index_adj.get(current, []) as Array):
			var to := String(downstream)
			if not ctx.time_dependent.has(to):
				ctx.time_dependent[to] = true
				queue.append(to)


# ================= 执行流 =================

func _exec_entries() -> void:
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var def := FxCatalog.def(node_data.get("type", ""))
		if def == null or not def.has_exec_in:
			continue
		var id := String(node_data.get("id", ""))
		var ports: Dictionary = _ports(id, node_data, def)
		var has_incoming := false
		for p in ports.get("inputs", []):
			if StringName((p as Dictionary).get("type", "")) == FxPortType.EXEC \
					and not _edge_into(id, String((p as Dictionary).get("id", ""))).is_empty():
				has_incoming = true
				break
		if not has_incoming:
			_exec_node(id)


func _follow(node_id: String, port_id: String) -> void:
	# 复制一份快照：执行过程中下游不会改图，但避免迭代期间数组被替换。
	for item in (doc.get("edges", []) as Array).duplicate(false):
		var edge: Dictionary = item
		if String(edge.get("from", "")) != node_id or String(edge.get("from_port", "")) != port_id:
			continue
		_exec_node(String(edge.get("to", "")))


func _exec_node(node_id: String) -> void:
	if not ctx.step():
		return
	var node_data := _node(node_id)
	if node_data.is_empty():
		return
	var def := FxCatalog.def(node_data.get("type", ""))
	if def == null:
		return
	var inputs := _resolve_inputs(node_data, def)
	var params := _resolve_params(node_data, def, inputs)
	ctx.node_params[node_id] = params
	var op := FxOpRegistry.get_op(def.op)
	if not op.is_valid():
		ctx.warn("节点 %s 缺少算子实现：%s" % [node_id, String(def.op)])
		push_error("FxGraphRunner：缺少算子实现 %s" % String(def.op))
		return
	var op_start := Time.get_ticks_usec()
	var result: Variant = op.call(ctx, node_data, def, inputs, params)
	ctx.timings[node_id] = snappedf(float(Time.get_ticks_usec() - op_start) / 1000.0, 0.01)
	var out: Dictionary = result if result is Dictionary else {}
	ctx.outputs[node_id] = out
	_capture_preview(node_id, def, out)


# ================= 数据流 =================

func _eval(node_id: String) -> Dictionary:
	var node_data := _node(node_id)
	if node_data.is_empty():
		return {}
	var def := FxCatalog.def(node_data.get("type", ""))
	if def == null:
		return {}
	# 有执行入口的节点只能由执行流驱动；拉取时返回它最近一次的结果。
	if def.has_exec_in:
		return ctx.outputs.get(node_id, {}) as Dictionary
	var use_cache := not ctx.volatile.has(node_id) and not ctx.time_dependent.has(node_id)
	if use_cache and ctx.outputs.has(node_id):
		return ctx.outputs[node_id] as Dictionary
	var static_cacheable := static_cache_enabled and use_cache and not def.has_exec_in
	if static_cacheable and _static_cache.has(node_id) \
			and int((_static_cache[node_id] as Dictionary).get("sig", 0)) == _doc_signature:
		var hit: Dictionary = _static_cache[node_id]
		var cached_out: Dictionary = hit.get("out", {})
		if hit.has("preview") and ctx.capture_previews:
			ctx.previews[node_id] = hit["preview"]
		ctx.outputs[node_id] = cached_out
		_cache_hits += 1
		return cached_out
	if ctx.evaluating.has(node_id):
		# 同时写进本帧警告：无头测试与界面状态栏都能看到，而不是只在 stderr 里
		# 冒一条 push_error。并发求值误报时可以据此断言定位。
		ctx.warn("检测到循环依赖：%s" % node_id)
		push_error("FxGraphRunner：检测到循环依赖 %s" % node_id)
		return {}
	ctx.evaluating[node_id] = true
	if not ctx.step():
		ctx.evaluating.erase(node_id)
		return {}
	var inputs := _resolve_inputs(node_data, def)
	var params := _resolve_params(node_data, def, inputs)
	ctx.node_params[node_id] = params
	var op := FxOpRegistry.get_op(def.op)
	var out: Dictionary = {}
	if op.is_valid():
		var op_start := Time.get_ticks_usec()
		var result: Variant = op.call(ctx, node_data, def, inputs, params)
		ctx.timings[node_id] = snappedf(float(Time.get_ticks_usec() - op_start) / 1000.0, 0.01)
		if result is Dictionary:
			out = result
	else:
		ctx.warn("节点 %s 缺少算子实现：%s" % [node_id, String(def.op)])
	ctx.evaluating.erase(node_id)
	ctx.outputs[node_id] = out
	_capture_preview(node_id, def, out)
	if static_cacheable:
		_static_cache[node_id] = {
			"out": out,
			"preview": ctx.previews.get(node_id),
			"sig": _doc_signature,
		}
	return out


func _resolve_inputs(node_data: Dictionary, def: FxNodeDef) -> Dictionary:
	var out: Dictionary = {}
	var node_id := String(node_data.get("id", ""))
	var ports: Dictionary = _ports(node_id, node_data, def)
	for item in ports.get("inputs", []):
		var port: Dictionary = item
		var port_id := String(port.get("id", ""))
		if StringName(port.get("type", "")) == FxPortType.EXEC:
			continue
		var edge := _edge_into(node_id, port_id)
		if edge.is_empty():
			continue
		var upstream_id := String(edge.get("from", ""))
		var upstream_port := String(edge.get("from_port", ""))
		var upstream := _eval(upstream_id)
		if not upstream.has(upstream_port):
			continue
		var value: Variant = upstream[upstream_port]
		var from_type: Variant = port.get("type", "")
		var upstream_node := _node(upstream_id)
		var upstream_def := FxCatalog.def(upstream_node.get("type", ""))
		if upstream_def != null:
			var upstream_ports: Dictionary = _ports(upstream_id, upstream_node, upstream_def)
			var spec := FxCatalog.find_port(upstream_ports.get("outputs", []), upstream_port)
			if not spec.is_empty():
				from_type = spec.get("type", from_type)
		out[port_id] = FxPortType.cast_value(value, from_type, port.get("type", ""))
	return out


func _resolve_params(node_data: Dictionary, def: FxNodeDef, inputs: Dictionary) -> Dictionary:
	var params := FxCatalog.default_params(def)
	var raw: Dictionary = node_data.get("params", {})
	for key in raw.keys():
		var value: Variant = raw[key]
		params[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	# mute / solo：被禁用的轨道冻结成静态值（第一帧），不参与本帧插值。
	# 只改内存里的 params，文档与撤销栈不受影响 —— 这是纯视图状态。
	if track_enabled.is_valid():
		var node_id := String(node_data.get("id", ""))
		for path in FxTracks.collect(raw).keys():
			var track_path := String(path)
			if bool(track_enabled.call(node_id, track_path)):
				continue
			var frozen: Variant = FxCatalog.value_at(params, track_path)
			FxCatalog.apply_path(params, track_path, FxTracks.first(frozen))
	# 关键帧在这里统一采样：任意参数都可以是 {track: [...]}，算子看到的永远是本帧数值。
	params = FxTracks.resolve_layer(params, ctx.t)
	# 参数端口由 FxCatalog.ports() 统一生成，这里只按端口表回填 ——
	# 界面上看得到的端口，执行时一定认；插件新增参数不需要两处各写一遍。
	for p in def.params:
		var pid := String(p.get("id", ""))
		if not bool(p.get("bindable", true)) or not inputs.has(pid):
			continue
		params[pid] = FxPortType.coerce_kind(inputs[pid], String(p.get("kind", "float")),
			params.get(pid))
	return params


# ================= 预览 =================

func _first_image(out: Dictionary, def: FxNodeDef) -> Image:
	for p in def.outputs:
		var port_id := String(p.get("id", ""))
		if StringName(p.get("type", "")) == FxPortType.IMAGE and out.get(port_id) is Image:
			return out[port_id] as Image
	return null


func _capture_preview(node_id: String, def: FxNodeDef, out: Dictionary) -> void:
	if not ctx.capture_previews:
		return
	if not preview_nodes.is_empty() and not preview_nodes.has(node_id):
		return
	var image := _first_image(out, def)
	if image == null:
		return
	var copy: Image = image.duplicate()
	var width := copy.get_width()
	var height := copy.get_height()
	var longest := maxi(width, height)
	if longest > ctx.preview_limit:
		var scale := float(ctx.preview_limit) / float(longest)
		copy.resize(maxi(1, int(round(float(width) * scale))),
			maxi(1, int(round(float(height) * scale))), Image.INTERPOLATE_NEAREST)
	ctx.previews[node_id] = copy
	node_previewed.emit(StringName(node_id), copy)
