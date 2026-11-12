class_name FxDocumentStore
extends FxContext
## 播放专用的轻量时间信号：只给时间轴/状态栏这类「画一个播放头」的消费者。
## set_time() 的 notify() 会把 coeffect 广播给所有 fiber，103 节点工程实测
## 每帧约 118ms；播放时每次推进都走那条路，界面必然卡死。
signal time_ticked(t: float)
## 文档上下文：把“文档 / 选中节点 / 当前时间”作为 coeffect 键放进统一上下文，
## 并把每一次修改都实现为**可逆效果**。
##
## 论文对应：
##   · 每次 mutate 前抓一份 context 快照；逆操作 = 把快照就地写回。
##     这正是 witnessed effect（Definition 8）：逆操作只在施加效果的状态上被要求成立。
##   · 快照就地 clear/merge，而不是替换 Dictionary 对象 —— 这样节点视图持有的
##     node_data 引用不会因为 undo 失效。
##   · undo/redo 是逆操作栈的两次 LIFO 应用；节点拖拽用 batch 把一串移动合成一次效果。
##
## 职责边界（这一条决定了哪些代码不该出现在本文件里）：
##   · 基座只做三件事：撤销栈、coeffect 键通知、批量合成；
##   · 文档长什么样、节点怎么加、图层数组怎么展开，都是图领域语义，
##     一律问 FxGraphFacade.access()（provider 由 core.graph 贡献）；
##   · 把 plugins/ 全删掉时这里仍能装载/撤销普通字典，只是没有任何图能力 ——
##     基座不认识 FxGraphDoc、FxCatalog 这类名字，也不需要它们存在。
##
## keys 约定（组件在 inject 里声明）：
##   doc            文档修订号
##   selection      选中节点 id（"" = 无选中）
##   time           当前时间（秒）
##   structure      节点/连线集合变化（需要重建视图）
##   node:<id>      某节点数据变化
##   param:<id>:<path> 某参数变化

var doc: Dictionary = {}
var selected_id: String = ""
var current_time: float = 0.0
## 轨道 solo / mute：纯视图状态，跟 selection/time 一样不进撤销栈。
## key 统一是 "node_id:path"（例如 "blur:radius"）。
var muted_tracks: Dictionary = {}
var solo_tracks: Dictionary = {}

var _revision: int = 0
## 布局修订号：位置 / 尺寸 / 选中 / 播放头这类**不改变任何一帧像素**的修改单独计数。
## 为什么必须分开：缩放、拖节点、点一下节点都会产生一次「文档被写过」，
## 但画面一模一样。旧实现把它们算进内容修订号，于是渲染服务换桶重算、
## 标签闪一下、预渲染从零重来 —— 用户看到的就是「数据没变也在重建」。
var _layout_revision: int = 0
## 文档世代：每次 attach（换工程/打开工程）单调 +1，永不重置。
## revision() 会在 attach 时归零，不能单独作为「文档身份」用 —— 渲染服务的
## 求帧快照以前就靠它做失效键，结果打开新工程后仍复用旧文档快照，
## 把启动时的 128×128 空图当成当前帧发布并写进缓存。
var _generation: int = 0
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _merge_key: String = ""
var _merge_ms: int = 0
var _batching: bool = false
var _batch_before: Dictionary = {}


## 当前生效的图能力实现。代理按注册表版本缓存，停用 core.graph 后自动回落空实现。
func api() -> FxGraphAccess:
	return FxGraphFacade.access()


## 装载新文档：历史清空，全部键重置。
## 文档修订号：任何一次写入（含纯布局）都会 +1。只用来回答「文档对象变过吗」。
func revision() -> int:
	return _revision + _layout_revision


## 内容修订号：只统计会改变渲染结果 / 导出结果的修改。
## 拖动节点、缩放视图、改选中、推进播放头都不计入 —— 它们不影响任何一帧像素。
## 渲染服务的求帧快照、执行器静态缓存、帧缓存指纹都以它为键。
func content_revision() -> int:
	return _revision


## 文档内容身份：世代 + 内容修订号。换工程、改参数都会变，且不会因 attach 归零而撞号。
## 渲染服务用它做求帧快照键、执行器静态缓存签名、以及结果回传的校验标签。
func content_key() -> int:
	return _generation * 1048576 + _revision


func attach(new_doc: Dictionary) -> void:
	doc = api().doc_normalize(new_doc)
	selected_id = ""
	current_time = 0.0
	muted_tracks.clear()
	solo_tracks.clear()
	_revision = 0
	_layout_revision = 0
	_generation += 1
	_undo.clear()
	_redo.clear()
	_merge_key = ""
	values["doc"] = _revision
	values["selection"] = ""
	values["time"] = 0.0
	notify(["doc", "selection", "time", "structure"])


static func track_key(node_id: String, path: String) -> String:
	return "%s:%s" % [node_id, path]


func set_track_muted(key: String, muted: bool) -> void:
	if muted:
		muted_tracks[key] = true
	else:
		muted_tracks.erase(key)
	notify(["tracks"])


func set_track_solo(key: String, solo: bool) -> void:
	if solo:
		solo_tracks[key] = true
	else:
		solo_tracks.erase(key)
	notify(["tracks"])


func clear_track_states() -> void:
	muted_tracks.clear()
	solo_tracks.clear()
	notify(["tracks"])


## 有任意 solo 时只让 solo 轨道参与动画；否则除了被 mute 的都参与。
func is_track_animated(key: String) -> bool:
	if not solo_tracks.is_empty():
		return solo_tracks.has(key)
	return not muted_tracks.has(key)


func track_state(key: String) -> Dictionary:
	return {
		"muted": muted_tracks.has(key),
		"solo": solo_tracks.has(key),
		"animated": is_track_animated(key),
	}


## 所有文档修改的唯一入口。mutator 直接改 doc；失败/成环由图实现自己保证。
## merge_key 非空时，600ms 内同一 key 的连续修改共用最早快照（滑块拖动只留一个撤销点）。
##
## 「写了个寂寞」必须彻底静默：写前写后完全相等 → 不记撤销、不动修订号、不广播。
## 这条闸门挡住的不是一个假想情况 —— GraphEdit 在缩放、点击等手势里也会发
## 节点移动结束，旧实现每次都留下一份空快照并把整条渲染链叫醒一遍。
func mutate(mutator: Callable, keys: Array = ["structure"], merge_key: String = "") -> void:
	if _batching:
		mutator.call(doc)
		return
	var before := doc.duplicate(true)
	mutator.call(doc)
	if before == doc:
		return
	_record(before, merge_key)
	var view_only := _view_only_keys(keys)
	_bump("doc", view_only)
	var out: Array = keys.duplicate()
	if not out.has("doc"):
		out.append("doc")
	if not selected_id.is_empty() and api().doc_node(doc, selected_id).is_empty():
		selected_id = ""
		values["selection"] = ""
		if not out.has("selection"):
			out.append("selection")
	notify(out)


## 节点拖拽等“一次手势”先 begin_batch，结束后 commit 成单个效果。
func begin_batch() -> void:
	if _batching:
		return
	_batching = true
	_batch_before = doc.duplicate(true)


func commit_batch(keys: Array = ["structure"]) -> void:
	if not _batching:
		return
	_batching = false
	# 一整段手势（拖节点 / 拖动缩放）结束后文档可能**一个字节都没变**。
	# 这时不压撤销点、不改修订号：否则每点一下节点都会多一个空撤销步，
	# 渲染侧也会被当成内容变更。
	if _batch_before == doc:
		return
	_record(_batch_before, "")
	_bump("doc", _view_only_keys(keys))
	var out: Array = keys.duplicate()
	if not out.has("doc"):
		out.append("doc")
	notify(out)


func cancel_batch() -> void:
	if not _batching:
		return
	_batching = false
	# 回滚到「什么都没发生过」= 文档与快照相同：不写回、不通知。
	# 只要真的改过东西，才需要恢复快照并广播。
	if _batch_before == doc:
		_batch_before.clear()
		return
	_restore_doc(_batch_before)
	notify(["doc"])


## 丢弃这一批**但不回滚、不广播**：调用方确认自己一个字段都没改过时用。
## cancel_batch() 会写回快照并通知，对于「点一下节点就结束的假拖拽」是不必要的噪声，
## 还会让渲染侧收到一次 doc 通知。
func discard_batch() -> void:
	_batching = false
	_batch_before.clear()


func _bump(key: String, view_only: bool = false) -> void:
	if view_only:
		_layout_revision += 1
	else:
		_revision += 1
	values[key] = revision()


## 这次写入是不是「纯视图」：只动了位置/尺寸/选中/播放头这类不进画面的字段。
## 注意 doc 是中性别名（mutate / commit_batch 一定会追加上去），不能拿它下判断 ——
## 否则一次普通的参数写入（keys 只有 doc）会被误判成纯视图，内容身份不再变化。
const VIEW_KEYS := ["positions", "size", "selection", "time"]

static func _view_only_keys(keys: Array) -> bool:
	var saw_view := false
	for key in keys:
		var text := String(key)
		if text == "doc":
			continue
		if VIEW_KEYS.has(text):
			saw_view = true
			continue
		return false
	return saw_view


func _record(before: Dictionary, merge_key: String) -> void:
	var now := Time.get_ticks_msec()
	if merge_key != "" and _merge_key == merge_key and now - _merge_ms < 600 \
			and not _undo.is_empty():
		_merge_ms = now
		return
	_undo.append(before)
	if _undo.size() > 160:
		_undo.pop_front()
	_redo.clear()
	_merge_key = merge_key
	_merge_ms = now


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo() -> void:
	if _undo.is_empty():
		return
	_redo.append(doc.duplicate(true))
	var snapshot: Dictionary = _undo.pop_back()
	_merge_key = ""
	_restore_doc(snapshot)
	_bump("doc")
	notify(["doc", "structure", "selection"])


func redo() -> void:
	if _redo.is_empty():
		return
	_undo.append(doc.duplicate(true))
	var snapshot: Dictionary = _redo.pop_back()
	_merge_key = ""
	_restore_doc(snapshot)
	_bump("doc")
	notify(["doc", "structure", "selection"])


func _restore_doc(snapshot: Dictionary) -> void:
	doc.clear()
	doc.merge(snapshot.duplicate(true), true)
	var selected_still_exists := not selected_id.is_empty() \
		and not api().doc_node(doc, selected_id).is_empty()
	if not selected_still_exists:
		selected_id = ""
		values["selection"] = ""
	values["time"] = current_time


func set_selection(node_id: String) -> void:
	var clean := node_id
	if not clean.is_empty() and api().doc_node(doc, clean).is_empty():
		clean = ""
	if clean == selected_id:
		return
	selected_id = clean
	values["selection"] = clean
	notify(["selection"])


## 播放期时间推进：只改数值 + 发一个轻量信号，不做全量 coeffect 广播。
## 文档参数、节点视图、撤销栈都不依赖播放头，没必要每帧把它们全唤醒一遍。
## 交互（拖时间轴、按左右键）继续用 set_time()，语义完整。
func set_time_silent(t: float) -> void:
	var duration := float(api().doc_timeline(doc).get("duration", 1.0))
	var clamped := clampf(t, 0.0, duration)
	if absf(clamped - current_time) < 0.00001:
		return
	current_time = clamped
	values["time"] = clamped
	time_ticked.emit(clamped)


func set_time(t: float) -> void:
	var duration := float(api().doc_timeline(doc).get("duration", 1.0))
	var clamped := clampf(t, 0.0, duration)
	if absf(clamped - current_time) < 0.00001:
		return
	current_time = clamped
	values["time"] = clamped
	notify(["time"])


# ================= 常用效果 =================
#
# 这一节都只是一行转发：真正的图语义在图访问实现里（当前是 core.graph）。
# 保留方法名是为了调用方稳定 —— 面板、命令、测试都按这些名字写。

func apply_param(node_id: String, param_id: String, value: Variant, structural: bool = false) -> void:
	var keys: Array = ["node:%s" % node_id, "param:%s:%s" % [node_id, param_id]]
	if structural:
		keys.append("structure")
	mutate(func(d: Dictionary) -> void:
		var node_data := api().doc_node(d, node_id)
		if node_data.is_empty():
			return
		var params: Dictionary = node_data.get("params", {})
		params[param_id] = value.duplicate(true) if value is Array or value is Dictionary else value
		node_data["params"] = params
	, keys, "param:%s:%s" % [node_id, param_id])


## 按路径写参数（时间轴编辑 "layers.0.opacity" 这类嵌套轨道用）。
func apply_path(node_id: String, path: String, value: Variant, structural: bool = false,
		merge_key: String = "") -> void:
	var keys: Array = ["node:%s" % node_id, "param:%s:%s" % [node_id, path]]
	if structural:
		keys.append("structure")
	var merged := merge_key if not merge_key.is_empty() else "param:%s:%s" % [node_id, path]
	mutate(func(d: Dictionary) -> void:
		api().doc_apply_path(d, node_id, path, value)
	, keys, merged)


func add_node(type: String, node_id: String = "", pos: Vector2 = Vector2.ZERO,
		params: Dictionary = {}) -> Dictionary:
	# GDScript 的 lambda 按值捕获局部变量；用单元素数组做引用槽，才能把结果带出来。
	var holder: Array = [{}]
	mutate(func(d: Dictionary) -> void:
		holder[0] = api().doc_add_node(d, type, node_id, pos, params)
	, ["structure"], "")
	return holder[0] as Dictionary


func remove_node(node_id: String) -> void:
	mutate(func(d: Dictionary) -> void:
		api().doc_remove_node(d, node_id)
	, ["structure"], "")


func remove_nodes(node_ids: Array) -> void:
	mutate(func(d: Dictionary) -> void:
		for node_id in node_ids:
			api().doc_remove_node(d, String(node_id))
	, ["structure"], "")


func connect_ports(from: String, from_port: String, to: String, to_port: String) -> int:
	var api_ref := api()
	var holder: Array = [api_ref.link_no_node()]
	# mutate 对「什么都没改」的写入已经是静默的（不会压撤销点），
	# 所以这里必须先记住栈深，只有真的压了才回退 —— 否则会把上一次真实操作的
	# 撤销点误删掉（表现为「撤销按钮突然失效/退到更早一步」）。
	var depth := _undo.size()
	mutate(func(d: Dictionary) -> void:
		holder[0] = api_ref.doc_connect(d, from, from_port, to, to_port)
	, ["structure"], "")
	var result := int(holder[0])
	if result != api_ref.link_ok():
		if _undo.size() > depth:
			_undo.pop_back()
		notify(["doc"])
	return result


func disconnect_ports(from: String, from_port: String, to: String, to_port: String) -> void:
	mutate(func(d: Dictionary) -> void:
		api().doc_disconnect(d, from, from_port, to, to_port)
	, ["structure"], "")


func set_output(node_id: String) -> void:
	mutate(func(d: Dictionary) -> void:
		api().doc_set_output(d, node_id)
	, ["structure", "node:%s" % node_id], "")


func set_canvas(width: int, height: int) -> void:
	mutate(func(d: Dictionary) -> void:
		api().set_doc_canvas(d, Vector2i(width, height))
	, ["canvas"], "canvas")


func set_timeline(fps: int, duration: float, loop: bool) -> void:
	mutate(func(d: Dictionary) -> void:
		api().doc_set_timeline(d, fps, duration, loop)
	, ["timeline"], "timeline")


## 文档元信息（名称/备注等）。走可逆效果，和参数一样可以撤销。
func set_doc_meta(key: String, value: Variant) -> void:
	mutate(func(d: Dictionary) -> void:
		var meta: Dictionary = d.get("meta", {})
		meta[key] = value
		d["meta"] = meta
	, ["doc"], "meta:%s" % key)


func set_node_position(node_id: String, pos: Vector2) -> void:
	api().doc_set_node_pos(doc, node_id, pos)


func param_value(node_id: String, param_id: String, fallback: Variant = null) -> Variant:
	var node_data := api().doc_node(doc, node_id)
	if node_data.is_empty():
		return fallback
	return (node_data.get("params", {}) as Dictionary).get(param_id, fallback)
