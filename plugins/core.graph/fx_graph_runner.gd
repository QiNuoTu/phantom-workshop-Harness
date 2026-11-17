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
## 额外的**求值根**。输出链之外的节点（旁支预览、单独看某个数值节点）只有进了
## 这个集合才会被求值。剪枝必须把它和输出节点一起当作根，否则「用户正在看的节点」
## 会被当成死节点删掉 —— 这是剪枝与预览共用的活节点定义。
var preview_roots: Array[String] = []
## 由 core.compile 插件贡献的 **IR 剪枝计划**（纯数据字典）。
## 空 = 完全原行为。求值器不认识任何编译器类名，只认这几个键：
## dead / sinks / constants / fold_params / ids_hash / stats。
## 插件停用 → 渲染服务给空字典 → 本文件的所有新分支自动关闭。
var compile_plan: Dictionary = {}
var _plan_active: bool = false
var _plan_dead: Dictionary = {}
var _plan_pruned: int = 0
var _plan_folded: int = 0
## 帧区间分段：计划里的全图轨道定义、时钟闭包、本帧指纹、按段复用命中数。
## 空计划时 _frame_key 恒为 ""，静态缓存退化为原来的「签名相同即复用」。
var _plan_tracks: Array = []
var _plan_clock: Dictionary = {}
var _frame_key: String = ""
var _segment_hits: int = 0
## 跨帧缓存：时间无关的子图只算一次。失效判定按**每节点签名**（见 `_node_sig`），
## 不再靠「整份文档签名变了就全清」—— 那是差量失效的反面。
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
## 每节点内容签名：`自身内容 + 上游闭包`（不含位置/折叠态这类布局键）。
##
## 这是「差量失效」的地基：静态缓存条目按它记，于是改一个节点的参数只会让它
## 自己和下游失配，上游照样命中。旧实现用 `_doc_signature`（整份文档）当键，
## 任何一处参数变化都会让**每一个**条目同时失配 —— 缓存存在但永远不命中。
var _node_sigs: Dictionary = {}
var _node_sigs_stamp: int = -1
## 子图执行器缓存（路径 → runner），**跨帧复用**。
##
## 旧实现把它挂在 ctx 上，而 ctx 每帧新建 —— 于是每个子图每帧都要重新建执行器、
## 重建索引、重算易变表，付一次「首跑价」。示范工程里两个 9 节点子图合计
## 每帧 12.7ms（占整帧 15%），但其中真正算像素的只有 3.4ms。
##
## 复用是安全的，理由逐条写明（这类「共享可变对象」的改动最容易埋雷）：
##   · 顶层 runner 同一时刻只被一条线程使用（主线程 / 工作线程 / 每条预渲染线程各一个）；
##   · 子图的 doc 每次 run 都由 run() 重新设，路径改了内容也不会读到旧文档；
##   · 子执行器的跨帧静态缓存按**每节点签名**判定（见 _node_sig），文档一变自然失配；
##   · 同一路径不会自我嵌套（递归栈 ctx.subgraph_stack 会拦下 A→…→A）。
var _sub_runners: Dictionary = {}
## 单节点追踪：`FX_TRACE_NODE=<节点 id>` 时打印该节点的缓存判定。
var _trace_node: String = OS.get_environment("FX_TRACE_NODE")
## 诊断：本帧有多少条目是被「签名不匹配 / 倍率不匹配」挡下，
## 而不是压根没缓存。两者混着看会得出「缓存没用」的错误结论。
var _sig_misses: int = 0
var _scale_misses: int = 0
## 上一次差量失效丢了哪些节点（诊断用，只保留最近一次）。
var last_downstream: Dictionary = {}
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
## 入边索引：节点 → [{from, from_port, to_port}]。指纹与区段模型都要按上游走，
## 每次都线性扫 edges 是 O(节点×边)，103 节点一帧几千次比较。
var _index_pred: Dictionary = {}
var _index_ports: Dictionary = {}
## 结构索引的缓存键：整份 nodes/edges 的 C++ 递归哈希（103 节点实测 0.034ms）。
## 文档不变（只是时间推进）时跨帧复用，不每帧重建；结构或参数一变键就变。
var _index_key: int = 0
var _index_valid: bool = false
## 倍率表的缓存键（预览根 + 继承档位）：拓扑没变但倍率该重算时用它识别。
var _scales_stamp: int = 0
## 诊断计数：整个预渲染段重建了几次索引（理想是每线程 1 次）。
var index_rebuilds: int = 0
## 逐层分辨率档：节点 → 本节点所处的求值倍率（缺省不在表里 = 1.0）。
## 由 _build_scales() 按「声明者向上游传播、遇另一个声明者即停」算出来。
## 空表时本文件的降采样分支全部关闭，行为与旧版逐像素一致。
var _eval_scale: Dictionary = {}
## 整张图继承的档位：子图被外层降档时，内层执行器靠它一起降。
## 顶层恒 1.0；子图算子在调用前把它设成父级的相对档位。
var base_scale: float = 1.0
## 供诊断/测试读：本帧真正生效的倍率（只列 < 1 的节点）与像素预算比。
var scale_report: Dictionary = {}
## 跳过汇点（`evaluate_always` 那批：输出预览 / 导出）。
##
## 只有草稿帧会打开它。汇点里有写文件的副作用（`io.export_*`），
## 而草稿是一件「随时可能被丢弃」的东西 —— 拿它去触发导出，
## 就是让一次预览把磁盘写满。精确趟与导出永远保持关闭。
var skip_sinks: bool = false


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
	# 汇点节点（输出预览 / 导出等）不一定接在输出链上，最后统一补跑，
	# 这样「旁支预览」也能拿到本帧图像。
	# 有计划时按拓扑序只遍历计划列出的汇点，省掉每帧一次全图线性扫描；
	# 没有计划时保持原来的全图扫描 —— 停用 core.compile 后行为逐字不变。
	# 注意：汇点一个都不剪，6 个 io.export_* 的写文件副作用必须保留。
	if skip_sinks:
		pass
	elif _plan_active:
		for raw_id in (compile_plan.get("sinks", []) as Array):
			var sid := String(raw_id)
			if sid == output or ctx.outputs.has(sid):
				continue
			_eval(sid)
	else:
		for item in doc.get("nodes", []):
			var node_data: Dictionary = item
			var node_id := String(node_data.get("id", ""))
			if node_id == output or ctx.outputs.has(node_id):
				continue
			var node_def := FxCatalog.def(node_data.get("type", ""))
			if node_def != null and node_def.evaluate_always:
				_eval(node_id)
	# 预览根：展开 / 选中的节点即使不在输出链上也要算一次。
	# 没有这一步，「路径不与输出相连就看不见预览」是必然结果，不是偶发 bug。
	for root_id in preview_roots:
		if root_id == output or ctx.outputs.has(root_id):
			continue
		var root_def := FxCatalog.def(_node(root_id).get("type", ""))
		if root_def != null and not root_def.has_exec_in:
			_eval(root_id)
	_end()
	return {
		"image": final_image,
		"previews": ctx.previews,
		"node_values": ctx.node_values,
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
	_node_sigs.clear()
	_node_sigs_stamp = -1
	# 子执行器持有的索引/易变表是按「当时的目录与节点定义」算的。
	# 插件被停用（节点类型消失）时必须连它们一起丢掉，否则复用的是一个
	# 已经不存在任何算子的旧世界。
	_sub_runners.clear()
	_index_ports.clear()


## 差量失效：只丢「改动节点的下游闭包 ∩ 当前缓存条目」。
##
## 语义由 `_node_sig` 保证 —— 即使这里一个都不丢，签名对不上的条目也不会被命中，
## 所以本函数**只做三件事**：提前腾掉必然失效的条目、把「丢了哪些」记下来供诊断、
## 让「改了但没影响任何人」的情形可观测（`dropped == 0`）。
##
## 为什么是下游闭包而不是「下游闭包 ∩ live」：缓存条目只对**已求值过**的节点存在，
## dead 节点在剪枝下从来不会被求值，本来就不在表里，求交集等于白走一趟图。
## 交集那一步在这里是恒等的，真正的剪枝发生在 IR 编译期。
func invalidate_downstream(ids: Array) -> Dictionary:
	_build_index()
	var touched: Array[String] = []
	var queue: Array[String] = []
	for raw in ids:
		var id := String(raw)
		if id.is_empty() or queue.has(id) or touched.has(id):
			continue
		if not _index_nodes.has(id):
			continue
		queue.append(id)
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if touched.has(current):
			continue
		touched.append(current)
		for downstream in (_index_adj.get(current, []) as Array):
			var to := String(downstream)
			if not touched.has(to) and not queue.has(to):
				queue.append(to)
	var dropped := 0
	for id in touched:
		if _static_cache.has(id):
			_static_cache.erase(id)
			dropped += 1
	# 上游不动：那些条目的签名没变，仍然有效 —— 这正是差量失效的全部收益。
	last_downstream = {
		"roots": ids.duplicate(),
		"touched": touched.size(),
		"dropped": dropped,
		"kept": _static_cache.size(),
	}
	return last_downstream


## 每节点内容签名：自身类型/参数/分辨率档 + 全部上游的签名。
## 布局键（pos / collapsed）**不算内容**：拖动节点不该让缓存失配。
func _node_sig(node_id: String) -> int:
	if _node_sigs_stamp != _doc_signature:
		# 文档内容身份变了才重算整表；同一版文档内跨帧复用。
		_node_sigs.clear()
		_node_sigs_stamp = _doc_signature
	return _sig_walk(node_id)


func _sig_walk(node_id: String) -> int:
	if _node_sigs.has(node_id):
		return int(_node_sigs[node_id])
	# 先占位再递归：执行流的回边会走回来，不能无限递归（与 has_cycle 同一处理）。
	_node_sigs[node_id] = 0
	var node_data: Dictionary = _index_nodes.get(node_id, {})
	var acc := _content_of(node_data) if not node_data.is_empty() else int(hash(node_id))
	var parts: Array[String] = []
	for raw in (_index_pred.get(node_id, []) as Array):
		var edge: Dictionary = raw
		var from := String(edge.get("from", ""))
		parts.append("%s\u001F%s\u001F%d" % [String(edge.get("to_port", "")),
			String(edge.get("from_port", "")), _sig_walk(from)])
	# 按端口名排序：连线的存放顺序不该影响签名，否则重连同一根线会白白失配。
	parts.sort()
	# 有效倍率也要进签名：`res_scale` 声明在下游节点上，改它不会改上游的**内容**，
	# 却会改上游的求值分辨率。只比内容就会拿一张旧档位的图当命中，
	# 而这种错在纯色图上看起来「没问题」—— 直到换成有细节的素材才暴露。
	acc = int(hash("|".join(PackedStringArray(parts)))) * 31 + acc
	acc = int(hash("%d|%.4f" % [acc, _scale_of(node_id)])) * 31 + acc
	_node_sigs[node_id] = acc
	return acc


## 节点自身的内容指纹：只取会改变像素/数值的东西。
func _content_of(node_data: Dictionary) -> int:
	if node_data.is_empty():
		return 0
	var params: Variant = node_data.get("params", {})
	var scale := FxGraphDoc.res_scale_of(node_data)
	return int(hash("%s|%s|%.4f" % [String(node_data.get("type", "")), str(params), scale]))


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
	ctx.subgraph_runners = _sub_runners
	_cache_hits = 0
	_sig_misses = 0
	_scale_misses = 0
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
	_plan_active = _plan_matches()
	_plan_dead.clear()
	if _plan_active:
		for raw_dead in (compile_plan.get("dead", []) as Array):
			_plan_dead[String(raw_dead)] = true
	_plan_pruned = 0
	_plan_folded = 0
	_plan_clock.clear()
	_plan_tracks = []
	_frame_key = ""
	_segment_hits = 0
	if _plan_active:
		_plan_tracks = compile_plan.get("plan_tracks", []) as Array
		# 用**实际 t** 采样，不用整数帧号：交互时播放头可能落在两帧之间，
		# 近似到最近帧会把 linear/ease 段误判成「与上帧相同」。
		_frame_key = FxTracks.key_of(_plan_tracks, ctx.t)
		var clock: Dictionary = compile_plan.get("clock_nodes", {})
		for raw_clock in clock.keys():
			_plan_clock[String(raw_clock)] = true


## 计划只绑定「节点 id 集合」，不绑定参数值：参数改了仍可复用计划，
## 但换工程 / 增删节点会立刻失配 → 整份作废，避免拿旧计划误剪新文档。
func _plan_matches() -> bool:
	if compile_plan.is_empty():
		return false
	var expected := int(compile_plan.get("ids_hash", 0))
	if expected == 0:
		return false
	var ids: Array[String] = []
	for key in _index_nodes.keys():
		ids.append(String(key))
	ids.sort()
	return hash(",".join(PackedStringArray(ids))) == expected


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
			"sig_misses": _sig_misses,
			"scale_misses": _scale_misses,
			"cache_entries": _static_cache.size(),
			"pruned": _plan_pruned,
			"folded": _plan_folded,
			"segment_hits": _segment_hits,
			"frame_tracks": _plan_tracks.size(),
			# 分辨率档的实况也进统计：诊断面板与测试都靠它判断「设了到底生效没」。
			# 只读 scale_report 是不够的 —— 工作线程路径下主线程的 runner 根本不跑，
			# 那份报告会一直是上一帧的旧值（本轮的冒烟就是这么被误导的）。
			"scale_declared": int((scale_report as Dictionary).get("declared", 0)),
			"scale_refused": ((scale_report as Dictionary).get("refused", []) as Array).size(),
			"plan_live": int((compile_plan.get("stats", {}) as Dictionary).get("live", 0)) 					if _plan_active else 0,
			"plan_dead": int((compile_plan.get("stats", {}) as Dictionary).get("dead", 0)) 					if _plan_active else 0,
			"timings": ctx.timings,
			"warnings": ctx.warnings.size(),
			"ms": snappedf(float(Time.get_ticks_usec() - _start_usec) / 1000.0, 0.01),
		}
	run_finished.emit(_last_stats)


# ================= 结构索引 =================

func _build_index() -> void:
	# 端口表按「节点内容签名 + 目录修订号」跨帧复用（见 _ports）：
	# 它依赖节点参数，但播放期间参数没动，每帧重建纯属浪费。
	# 结构三张表只依赖拓扑，按整表哈希跨帧复用 —— 60 帧预渲染只建 1 次。
	var nodes: Array = doc.get("nodes", [])
	var edges: Array = doc.get("edges", [])
	var key := int(hash(nodes)) * 31 + int(hash(edges))
	# 倍率表只依赖「预览根 + 继承档位」，与拓扑无关：展开/收起一个节点、
	# 子图换了外层档位，都该重算 `_eval_scale`，但没必要重建整张索引。
	# 少了这一步，预览根的改动会一直用上一轮的档位 —— 而档位现在进了节点签名，
	# 于是「签名」与「实际求值」会长期不一致，缓存命中的是一张错档位的图。
	var scale_key := _scales_key_of()
	if _index_valid and key == _index_key:
		if scale_key != _scales_stamp:
			_build_scales()
			_scales_stamp = scale_key
		return
	_index_nodes.clear()
	_index_edges.clear()
	_index_adj.clear()
	_index_pred.clear()
	index_rebuilds += 1
	for item in nodes:
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		_index_nodes[id] = node_data
		if not _index_adj.has(id):
			_index_adj[id] = []
		if not _index_pred.has(id):
			_index_pred[id] = []
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
		if not _index_pred.has(to):
			_index_pred[to] = []
		(_index_pred[to] as Array).append(edge)
	_index_key = key
	_index_valid = true
	_build_scales()
	_scales_stamp = scale_key


## 逐层分辨率档：算出每个节点「应该在哪一档求值」。
##
## 规则（区段模型，对应 AE 的「每个图层一个分辨率」）：
## 声明者 N(s) 要求「N 及其全部上游」按 s 求值；向上游传播时遇到**另一个声明者**就停，
## 那个声明者的区段由它自己决定。所以区段之间互不重叠，语义可预测：
## 改一个节点的档位，只会影响它到下一个声明者之间那一段。
##
## 两个节点不接受声明，一律 1.0：
## - 输出节点（`doc.output`）—— 它降了，交付的画面就不是全尺寸；
## - 汇点（`evaluate_always`，含 6 个导出节点）—— 导出文件会变小。
## 这条保护不是「防呆」，而是「所见即所得」的底线：降分辨率只允许发生在中间过程。
func _scales_key_of() -> int:
	var roots: Array[String] = []
	for raw in preview_roots:
		roots.append(String(raw))
	roots.sort()
	return int(hash("%s|%.4f" % [",".join(PackedStringArray(roots)), base_scale]))


func _build_scales() -> void:
	_eval_scale.clear()
	scale_report = {"declared": 0, "refused": [], "effective": {}}
	var nodes: Array = doc.get("nodes", [])
	if nodes.is_empty():
		return
	var output := FxGraphDoc.output_id(doc)
	var pred := {}
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		var from := String(edge.get("from", ""))
		var to := String(edge.get("to", ""))
		if from.is_empty() or to.is_empty():
			continue
		if not pred.has(to):
			pred[to] = []
		(pred[to] as Array).append(from)
	# 1. 谁声明了降档（输出 / 汇点拒绝）
	var declared := {}
	var refused: Array[String] = []
	for item in nodes:
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		if not FxGraphDoc.has_res_scale(node_data):
			continue
		if id == output or _is_sink_node(node_data):
			refused.append(id)
			continue
		declared[id] = FxGraphDoc.res_scale_of(node_data)
	# 拒绝的信息要留住：它是「为什么我设了没生效」的唯一答案，不能因为
	# 「没有生效的声明」就把它一起丢了（测试当场抓到过这一点）。
	scale_report["refused"] = refused
	if declared.is_empty():
		for item in nodes:
			_eval_scale[String((item as Dictionary).get("id", ""))] = 1.0
		return
	# 2. 全分辨率需求：从输出 / 汇点 / 预览根向上游传播，遇声明者就停。
	#    这一步是「共享上游不能被我拖下水」的关键：同一个节点如果还被一条
	#    全分辨率路径消费，它必须按 1.0 算，降档由消费方自己在边界缩放。
	#    少了这一步，一条旁支的降档会悄悄拉低主干精度 —— 那是最难查的一类画质问题。
	var needed := {}
	var full_roots: Array[String] = []
	if not output.is_empty():
		full_roots.append(output)
	for item in nodes:
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		if _is_sink_node(node_data):
			full_roots.append(id)
	for raw_root in preview_roots:
		full_roots.append(String(raw_root))
	for root in full_roots:
		_propagate_scale(root, 1.0, pred, declared, needed)
	# 3. 降档需求：声明者自己按声明的档位（别人要 1.0 也不改它，它的输出就该是缩的，
	#    由下游放大），再往上传播到它的区段。
	for id in declared.keys():
		var want := float(declared[id])
		needed[id] = want
		_propagate_scale(id, want, pred, declared, needed)
	var effective := {}
	for item in nodes:
		var id := String((item as Dictionary).get("id", ""))
		var value := maxf(float(needed.get(id, 1.0)), 0.125)
		_eval_scale[id] = value
		if value < 0.999:
			effective[id] = value
	scale_report = {
		"declared": declared.size(),
		"refused": refused,
		"effective": effective,
	}


## 把一个「档位需求」沿上游传播。声明者是硬边界：不改它、也不越过它，
## 因为它的上游属于它自己的区段（由它那次传播决定）。
func _propagate_scale(start: String, want: float, pred: Dictionary,
		declared: Dictionary, needed: Dictionary) -> void:
	var stack: Array[String] = [start]
	var seen := {start: true}
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		if not declared.has(cur):
			needed[cur] = maxf(float(needed.get(cur, 0.0)), want)
		for raw_up in pred.get(cur, []):
			var up := String(raw_up)
			if seen.has(up):
				continue
			seen[up] = true
			if declared.has(up):
				continue
			stack.append(up)


## 汇点判定：`evaluate_always` 是汇点的既有标记（导出 / 输出预览那批节点）。
static func _is_sink_node(node_data: Dictionary) -> bool:
	var def := FxCatalog.def(node_data.get("type", ""))
	return def != null and def.evaluate_always


## 某节点本帧的求值倍率（未声明 = 1.0）。
func _scale_of(node_id: String) -> float:
	return float(_eval_scale.get(node_id, 1.0))


## 某一档对应的求值画布。用它给算子一个「更小的画布」，
## 算子内部读 ctx.canvas 决定输出尺寸，所以这里改了就够了 —— 不需要每个算子各写一遍。
## `base_scale` 让子图跟着外层一起降：否则外层给了半尺寸输入，子图内部又按全尺寸算，
## 出来还要再缩一次，等于白缩两趟。
func _canvas_for(scale: float) -> Vector2i:
	var base := FxGraphDoc.canvas(doc)
	var total := clampf(scale * base_scale, 0.0625, 1.0)
	if total >= 0.999:
		return base
	return Vector2i(maxi(1, int(round(float(base.x) * total))),
		maxi(1, int(round(float(base.y) * total))))


func _node(node_id: String) -> Dictionary:
	return _index_nodes.get(node_id, {}) as Dictionary


func _edge_into(node_id: String, port_id: String) -> Dictionary:
	return _index_edges.get(node_id + "\u001F" + port_id, {}) as Dictionary


## 端口表缓存。**按节点内容签名跨帧复用**，而不是每帧重建。
##
## 端口表只取决于三件事：节点定义、节点参数、目录修订号。前两件已经包含在
## `_content_of()` 里，第三件单独记。因此「缓存命中」与「重新生成」结果逐字段相同，
## 不存在近似。早期实现每帧 clear 一次，103 节点实测 4.2ms/帧 —— 而这些表在
## 纯播放期间一个字都没变过（播放只推进时间，不动参数）。
func _ports(node_id: String, node_data: Dictionary, def: FxNodeDef) -> Dictionary:
	var cached: Dictionary = _index_ports.get(node_id, {})
	if not cached.is_empty():
		var sig := _content_of(node_data)
		if int(cached.get("sig", 0)) == sig \
				and int(cached.get("catalog", -1)) == FxRegistry.revision:
			return cached.get("ports", {}) as Dictionary
	var built := FxCatalog.ports(def, node_data.get("params", {}))
	_index_ports[node_id] = {
		"sig": _content_of(node_data),
		"catalog": FxRegistry.revision,
		"ports": built,
	}
	return built


## 只对“会进缓存的节点”做签名：节点 id、类型、参数与全部连线。
## 成本远低于一次图像运算，却能让缓存对直接改 doc 的旧代码也安全。
func _signature_of(target: Dictionary) -> int:
	var sig := hash(target.get("edges", []))
	for item in target.get("nodes", []):
		var node_data: Dictionary = item
		sig = sig * 31 + hash(String(node_data.get("type", "")))
		sig = sig * 31 + hash(node_data.get("params", {}))
		# res_scale 是节点字段而不是参数，但它改变求值分辨率 —— 漏了它，
		# 「改档位」会被当成「什么都没变」，整条链继续命中旧档位的图。
		sig = sig * 31 + hash(node_data.get("res_scale", 1.0))
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
	if _plan_active:
		# 结构剪枝：只有纯数据旁支会落进 dead。汇点（含导出副作用）与执行流节点
		# 都是编译计划的根，永远不会出现在这里。
		if _plan_dead.has(node_id):
			_plan_pruned += 1
			return {}
		# 常量折叠：编译期预算好的纯标量输出，直接取，不调算子。
		var consts: Dictionary = compile_plan.get("constants", {})
		if consts.has(node_id):
			var folded: Dictionary = (consts[node_id] as Dictionary).duplicate(true)
			ctx.outputs[node_id] = folded
			var fparams: Dictionary = compile_plan.get("fold_params", {})
			if fparams.has(node_id):
				ctx.node_params[node_id] = (fparams[node_id] as Dictionary).duplicate(true)
			# 折叠也必须喂预览 / 数值读数，否则「数值节点看不到结果」会卷土重来。
			_capture_preview(node_id, def, folded)
			_plan_folded += 1
			return folded
	# 有执行入口的节点只能由执行流驱动；拉取时返回它最近一次的结果。
	if def.has_exec_in:
		return ctx.outputs.get(node_id, {}) as Dictionary
	var use_cache := not ctx.volatile.has(node_id) and not ctx.time_dependent.has(node_id)
	if use_cache and ctx.outputs.has(node_id):
		return ctx.outputs[node_id] as Dictionary
	# 旧判定把所有「自身或上游有轨道」的节点一律标成 time_dependent，于是即使
	# 轨道是单帧常量 / step 保持段 / 到达终点后的保持段，也都逐帧重算。
	# 有计划时放宽：只要本帧的全图轨道指纹与缓存时相同，且该节点不在时钟闭包里
	# （时钟算子、执行流、汇点、gpu、非 cacheable 及其下游），输出就必然相同。
	# 空计划时 plan_relaxed 恒为 false，行为逐字不变。
	# volatile 是「非 cacheable / 参数端口被连线」的传播闭包，它比时钟闭包更宽，
	# 必须一并排除：这类节点即使轨道指纹不变也可能每次调用产出不同结果。
	var plan_relaxed := _plan_active and not _plan_clock.has(node_id) \
			and not ctx.volatile.has(node_id)
	var static_cacheable := static_cache_enabled and (use_cache or plan_relaxed) \
			and not def.has_exec_in
	# 命中判定拆开写：除了「中/不中」，还要能回答「为什么没中」。
	# `sig_misses` = 条目存在但签名变了（差量失效的正常结果）；
	# 条目压根不存在才是「第一次算」。两者混在一起看，就会得出
	# 「缓存没用」的错误结论 —— 那正是上一轮审计里最容易误判的一处。
	var hit: Dictionary = {}
	if static_cacheable and _static_cache.has(node_id):
		var entry: Dictionary = _static_cache[node_id]
		# 有效倍率必须一起比：`res_scale` 声明在**下游**节点上，改它不会改上游的
		# 内容签名，但会改上游的求值倍率 —— 只比签名就会拿一张旧档位的图当命中。
		# 预览根变化（展开/收起节点）走的是同一条路，所以这里一次覆盖两种情形。
		var want_scale := _scale_of(node_id) * base_scale
		if int(entry.get("sig", 0)) != _node_sig(node_id):
			_sig_misses += 1
		elif String(entry.get("frame_key", "")) != _frame_key:
			pass
		elif absf(float(entry.get("scale", -1.0)) - want_scale) > 0.0001:
			_scale_misses += 1
		else:
			hit = entry
	if not hit.is_empty():
		if _trace_node != "" and _trace_node == node_id:
			print("[node] %s 命中缓存 sig=%d out_img=%s" % [node_id,
				_node_sig(node_id), str((hit.get("out", {}) as Dictionary).get("image"))])
		var cached_out: Dictionary = hit.get("out", {})
		if hit.has("preview") and ctx.capture_previews:
			ctx.previews[node_id] = hit["preview"]
		# 缓存命中也要恢复参数读数与数值读数，否则「数值节点看不到结果」会复发。
		# 读数现在是结构化的（含端口类型），必须深拷贝：跨帧共用一个 Array 会让
		# 上一帧的采样被这一帧的卡片改写。
		if hit.has("params"):
			ctx.node_params[node_id] = (hit["params"] as Dictionary).duplicate(true)
		var cached_values: Variant = hit.get("values", [])
		if cached_values is Array and not (cached_values as Array).is_empty():
			ctx.node_values[node_id] = (cached_values as Array).duplicate(true)
		elif cached_values is String and not String(cached_values).is_empty():
			# 旧格式（上一个版本把读数存成一行文本）：按文本降级，不整段作废旧缓存。
			var legacy := String(cached_values)
			ctx.node_values[node_id] = [
				{"port": "", "type": "string", "value": legacy, "text": legacy}]
		ctx.outputs[node_id] = cached_out
		_cache_hits += 1
		if plan_relaxed and not use_cache:
			_segment_hits += 1
		return cached_out
	if _trace_node != "" and _trace_node == node_id:
		print("[node] %s 未命中 → 重算 sig=%s cached=%s static_cacheable=%s" % [
			node_id, str(_node_sig(node_id)),
			str(_static_cache.has(node_id)), str(static_cacheable)])
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
	var scale := _scale_of(node_id)
	var want_canvas := _canvas_for(scale)
	var saved_canvas := ctx.canvas
	var saved_eval_scale := ctx.eval_scale
	if want_canvas != saved_canvas:
		ctx.canvas = want_canvas
	# 算子读它来换算像素单位的参数（模糊半径、描边宽度…）。
	# 只在真的降档时暴露 < 1 的值，全分辨率下与旧行为逐字节一致。
	ctx.eval_scale = clampf(scale * base_scale, 0.0625, 1.0)
	var inputs := _resolve_inputs(node_data, def, scale)
	var params := _resolve_params(node_data, def, inputs)
	ctx.node_params[node_id] = params
	var op := FxOpRegistry.get_op(def.op)
	var out: Dictionary = {}
	if op.is_valid():
		var op_start := Time.get_ticks_usec()
		var result: Variant = op.call(ctx, node_data, def, inputs, params)
		var elapsed := float(Time.get_ticks_usec() - op_start) / 1000.0
		ctx.timings[node_id] = snappedf(elapsed, 0.01)
		ctx.timing_totals[node_id] = float(ctx.timing_totals.get(node_id, 0.0)) + elapsed
		ctx.op_calls[node_id] = int(ctx.op_calls.get(node_id, 0)) + 1
		if result is Dictionary:
			out = result
	else:
		ctx.warn("节点 %s 缺少算子实现：%s" % [node_id, String(def.op)])
	# 出区段就把画布还原：区段内的兄弟节点看到的是外层画布，不会互相串档。
	if want_canvas != saved_canvas:
		ctx.canvas = saved_canvas
	ctx.eval_scale = saved_eval_scale
	ctx.evaluating.erase(node_id)
	ctx.outputs[node_id] = out
	_capture_preview(node_id, def, out)
	if static_cacheable:
		# 读数可能为空（纯图像节点），也可能是 Array；统一深拷贝一份存进来。
		var cached_samples: Array = []
		var raw_samples: Variant = ctx.node_values.get(node_id, [])
		if raw_samples is Array:
			cached_samples = (raw_samples as Array).duplicate(true)
		_static_cache[node_id] = {
			"out": out,
			"preview": ctx.previews.get(node_id),
			"params": params.duplicate(true),
			"values": cached_samples,
			# 每节点签名而不是整份文档签名：这是「改一个参数只废下游」的关键。
			"sig": _node_sig(node_id),
			"scale": _scale_of(node_id) * base_scale,
			"frame_key": _frame_key,
		}
	return out


func _resolve_inputs(node_data: Dictionary, def: FxNodeDef, scale: float = 1.0) -> Dictionary:
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
		# 跨区段取图：上游在它自己那一档算出了小图（或大图），这里换成**本档的空间尺寸**。
		# 尺寸按倍率比例还原，所以「放大回全尺寸」不需要知道原始画布 ——
		# 降 0.5 再乘 2 就回来了，中间经过几段也不会累积误差（每段都按整数四舍五入）。
		if value is Image:
			value = _rescale_between(value, _scale_of(upstream_id), scale)
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


## 把图从 `from_scale` 的求值空间换到 `to_scale` 的空间。
## 同档直接返回原引用（零成本，这是「没声明就不该有任何变化」的保证）。
##
## 缩小用 LANCZOS：代理分辨率只允许**一次**降采样，BILINEAR 在细线条上会走样，
## 而这一步的代价远小于它省下的全分辨率算子。放大用 BILINEAR（不产生振铃）。
static func _rescale_between(image: Image, from_scale: float, to_scale: float) -> Image:
	if is_equal_approx(from_scale, to_scale):
		return image
	var ratio := to_scale / maxf(from_scale, 0.0001)
	if ratio <= 0.0001:
		return image
	var width := maxi(1, int(round(float(image.get_width()) * ratio)))
	var height := maxi(1, int(round(float(image.get_height()) * ratio)))
	if width == image.get_width() and height == image.get_height():
		return image
	var copy: Image = image.duplicate()
	copy.resize(width, height,
		Image.INTERPOLATE_LANCZOS if ratio < 1.0 else Image.INTERPOLATE_BILINEAR)
	return copy


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
	# 像素单位的参数按求值倍率换算：0.5 档下 radius=10 必须**看起来还是 10 的糊度**，
	# 而不是实际等于 20。判据是参数自己声明的 `unit: "px"`（nodes.json 早就有这个字段），
	# 基座不认识任何具体参数名 —— 插件新增像素参数只要打上这个单位就自动正确。
	# 少了这一步，降档就不是「画质略降」，而是「效果变了」，那比不降还糟。
	if ctx.eval_scale < 0.999:
		for p in def.params:
			if String(p.get("unit", "")) != "px":
				continue
			var pid := String(p.get("id", ""))
			if params.has(pid):
				params[pid] = _scale_px_param(params[pid], ctx.eval_scale,
					String(p.get("kind", "float")))
	return params


## 像素单位的参数按倍率缩放。整数类型四舍五入并夹到 0 以上 ——
## 半径 1 在 0.5 档下只能变 0（再小就没像素可采），这是降档的固有代价，不是 bug。
static func _scale_px_param(value: Variant, scale: float, kind: String) -> Variant:
	match kind:
		"int":
			return maxi(0, int(round(float(value) * scale)))
		"vec2":
			if value is Vector2:
				return (value as Vector2) * scale
			if value is Array and (value as Array).size() >= 2:
				return Vector2(float((value as Array)[0]) * scale,
					float((value as Array)[1]) * scale)
			return value
	return float(value) * scale


# ================= 预览 =================

func _first_image(out: Dictionary, def: FxNodeDef) -> Image:
	for p in def.outputs:
		var port_id := String(p.get("id", ""))
		if StringName(p.get("type", "")) == FxPortType.IMAGE and out.get(port_id) is Image:
			return out[port_id] as Image
	return null


func _capture_preview(node_id: String, def: FxNodeDef, out: Dictionary) -> void:
	# 数值读数先收集，且**不受** capture_previews 影响：
	# 那个开关省的是「缩小一张图」的钱，读几个 Variant 几乎不花钱。
	# 旧实现把两者绑在一起，于是播放期一关小图，数值节点卡片就整片空白。
	var samples := _value_samples(out, def)
	if not samples.is_empty():
		ctx.node_values[node_id] = samples
	if not ctx.capture_previews:
		return
	# 播放时 quality.preview_scope 会把白名单缩到「输出 + 选中」，但用户**展开**
	# 的旁支节点仍然该有预览 —— 预览根是显式请求，不受这层裁剪影响。
	# 旧实现在这里一律挡掉，于是「预览有时候有、有时候没有」。
	if not preview_nodes.is_empty() and not preview_nodes.has(node_id) \
			and not preview_roots.has(node_id):
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


## 结构化读数：`[{port, type, value, text}]`。
##
## 为什么不是一行字符串：界面上要**按类型画**——数值画曲线、向量画坐标、颜色画色块、
## 布尔画灯。一行文本只能「读」，看不出趋势，也分不出这是什么。
## 类型取自端口声明（插件自己给的），比 Variant 更可信：int 藏在 number 端口里时
## 仍应画成曲线，而不是被当成整数文本。
##
## 只收「能放进卡片」的值：Image 由预览通道负责，Object/Dictionary 跳过；
## 最多 4 项，免得 stats 这类大字典把节点卡片撑开。
static func _value_samples(out: Dictionary, def: FxNodeDef) -> Array:
	var list: Array = []
	if def == null:
		return list
	for p in def.outputs:
		var port := String(p.get("id", ""))
		if not out.has(port):
			continue
		var value: Variant = out[port]
		if value is Image or value is Object or value is Dictionary:
			continue
		list.append({
			"port": port,
			"type": String(p.get("type", "")),
			"value": value,
			"text": _scalar_text(value),
		})
		if list.size() >= 4:
			break
	return list


## 把单个输出值压成一行可读文本（结构化读数里的 `text` 字段、tooltip 也用这份）。
static func _scalar_text(value: Variant) -> String:
	if value is float or value is int:
		return str(snappedf(float(value), 0.001))
	if value is bool:
		return "true" if bool(value) else "false"
	if value is Vector2:
		var v: Vector2 = value
		return "(%.3f, %.3f)" % [v.x, v.y]
	if value is Color:
		return "#" + (value as Color).to_html(false)
	if value is String:
		return (value as String).substr(0, 24)
	if value is Array:
		var arr: Array = value
		var items: Array[String] = []
		for i in range(mini(arr.size(), 3)):
			items.append(_scalar_text(arr[i]))
		var tail := "…" if arr.size() > 3 else ""
		return "[%s%s]" % [", ".join(PackedStringArray(items)), tail]
	return str(value)
