class_name FxGraphDoc
extends RefCounted
## 图文档：纯 JSON 安全的字典，**不持有任何节点实例或 UI 对象**。
##
## 文档结构（.fxgraph）：
## {
##   "format": "phantom.graph", "version": 1,
##   "meta": {"name", "canvas": {width,height,background},
##            "timeline": {fps,duration,loop}, "seed"},
##   "nodes": [{"id","type","pos":[x,y],"params":{},"collapsed"}],
##   "edges": [{"from","from_port","to","to_port"}],
##   "frames": [{"id","title","rect":[x,y,w,h],"nodes":[id]}],
##   "output": "node_id"
## }
##
## 所有函数都是静态的：文档就是数据，存盘/读盘/校验/连线都不需要实例，
## 也方便无头测试与将来做批处理。TimelineOps 直接依赖这里的 node(doc, id)。

const FORMAT := "phantom.graph"
const VERSION := 1
const MAX_CANVAS := 4096

## 连线结果。不用 Godot 的 Error 枚举：图连线需要区分“端口不存在 / 类型不兼容 / 成环”，
## 这三个错误对用户的意义完全不同，界面要给不同的提示。
const LINK_OK := 0
const LINK_NO_NODE := 1
const LINK_NO_PORT := 2
const LINK_TYPE := 3
const LINK_CYCLE := 4


static func create(name: String = "未命名") -> Dictionary:
	return {
		"format": FORMAT,
		"version": VERSION,
		"meta": {
			"name": name,
			"canvas": {"width": 128, "height": 128, "background": "#00000000"},
			"timeline": {"fps": 30, "duration": 1.0, "loop": true},
			"seed": 1,
		},
		"nodes": [],
		"edges": [],
		"frames": [],
		"output": "",
	}


## 任意输入 → 结构完整的文档。容错优先：坏节点/坏连线被丢弃，不抛错。
static func normalize(raw: Variant) -> Dictionary:
	var doc := create()
	if not raw is Dictionary:
		return doc
	var source: Dictionary = raw
	doc["format"] = String(source.get("format", FORMAT))
	doc["version"] = int(source.get("version", VERSION))

	var meta: Dictionary = doc["meta"]
	if source.get("meta") is Dictionary:
		for key in (source["meta"] as Dictionary).keys():
			meta[key] = (source["meta"] as Dictionary)[key]
	if not meta.get("canvas") is Dictionary:
		meta["canvas"] = {"width": 128, "height": 128, "background": "#00000000"}
	else:
		var canvas: Dictionary = meta["canvas"]
		canvas["width"] = clampi(int(canvas.get("width", 128)), 1, MAX_CANVAS)
		canvas["height"] = clampi(int(canvas.get("height", 128)), 1, MAX_CANVAS)
		canvas["background"] = String(canvas.get("background", "#00000000"))
	if not meta.get("timeline") is Dictionary:
		meta["timeline"] = {"fps": 30, "duration": 1.0, "loop": true}
	else:
		var timeline: Dictionary = meta["timeline"]
		timeline["fps"] = clampi(int(timeline.get("fps", 30)), 1, 120)
		timeline["duration"] = clampf(float(timeline.get("duration", 1.0)), 0.01, 3600.0)
		timeline["loop"] = bool(timeline.get("loop", true))
	meta["seed"] = int(meta.get("seed", 1))

	var nodes: Array = []
	var seen: Dictionary = {}
	for item in source.get("nodes", []):
		if not item is Dictionary:
			continue
		var src_node: Dictionary = item
		var id := String(src_node.get("id", ""))
		if id.is_empty() or seen.has(id):
			continue
		seen[id] = true
		var node: Dictionary = src_node.duplicate(true)
		node["id"] = id
		node["type"] = String(src_node.get("type", ""))
		node["pos"] = pair_of(src_node.get("pos", [0, 0]))
		if not node.get("params") is Dictionary:
			node["params"] = {}
		node["collapsed"] = bool(src_node.get("collapsed", false))
		nodes.append(node)
	doc["nodes"] = nodes

	var edges: Array = []
	for item in source.get("edges", []):
		if not item is Dictionary:
			continue
		var edge: Dictionary = item.duplicate(true)
		var from := String(edge.get("from", ""))
		var to := String(edge.get("to", ""))
		var from_port := String(edge.get("from_port", ""))
		var to_port := String(edge.get("to_port", ""))
		if not seen.has(from) or not seen.has(to) or from == to:
			continue
		if from_port.is_empty() or to_port.is_empty():
			continue
		edge["from"] = from
		edge["to"] = to
		edge["from_port"] = from_port
		edge["to_port"] = to_port
		if _has_edge(edges, from, from_port, to, to_port):
			continue
		edges.append(edge)
	doc["edges"] = edges

	var frames: Array = []
	for item in source.get("frames", []):
		if not item is Dictionary:
			continue
		var frame: Dictionary = item.duplicate(true)
		frame["id"] = String(frame.get("id", "frame_%d" % frames.size()))
		frame["title"] = String(frame.get("title", "区域"))
		frame["rect"] = rect_of(frame.get("rect", [0, 0, 200, 120]))
		var attached: Array = []
		for node_id in frame.get("nodes", []):
			if seen.has(String(node_id)):
				attached.append(String(node_id))
		frame["nodes"] = attached
		frames.append(frame)
	doc["frames"] = frames

	var output := String(source.get("output", ""))
	doc["output"] = output if seen.has(output) else ""
	return doc


static func duplicate_doc(doc: Dictionary) -> Dictionary:
	return doc.duplicate(true)


# ================= 查询 =================

static func node(doc: Dictionary, node_id: Variant) -> Dictionary:
	var id := String(node_id)
	for item in doc.get("nodes", []):
		if item is Dictionary and String(item.get("id", "")) == id:
			return item
	return {}


static func node_index(doc: Dictionary, node_id: Variant) -> int:
	var id := String(node_id)
	var nodes: Array = doc.get("nodes", [])
	for i in range(nodes.size()):
		var item: Dictionary = nodes[i]
		if String(item.get("id", "")) == id:
			return i
	return -1


static func output_id(doc: Dictionary) -> String:
	return String(doc.get("output", ""))


static func canvas(doc: Dictionary) -> Vector2i:
	var meta: Dictionary = doc.get("meta", {})
	var c: Dictionary = meta.get("canvas", {})
	return Vector2i(
		clampi(int(c.get("width", 128)), 1, MAX_CANVAS),
		clampi(int(c.get("height", 128)), 1, MAX_CANVAS)
	)


static func canvas_background(doc: Dictionary) -> Color:
	var meta: Dictionary = doc.get("meta", {})
	var c: Dictionary = meta.get("canvas", {})
	return Color.from_string(String(c.get("background", "#00000000")), Color(0, 0, 0, 0))


static func timeline(doc: Dictionary) -> Dictionary:
	var meta: Dictionary = doc.get("meta", {})
	var t: Dictionary = meta.get("timeline", {})
	return {
		"fps": clampi(int(t.get("fps", 30)), 1, 120),
		"duration": clampf(float(t.get("duration", 1.0)), 0.01, 3600.0),
		"loop": bool(t.get("loop", true)),
	}


static func meta_value(doc: Dictionary, key: String, fallback: Variant = null) -> Variant:
	var meta: Dictionary = doc.get("meta", {})
	return meta.get(key, fallback)


static func set_canvas(doc: Dictionary, width: int, height: int) -> void:
	var meta: Dictionary = doc.get("meta", {})
	var c: Dictionary = meta.get("canvas", {})
	c["width"] = clampi(width, 1, MAX_CANVAS)
	c["height"] = clampi(height, 1, MAX_CANVAS)
	c["background"] = String(c.get("background", "#00000000"))
	meta["canvas"] = c
	doc["meta"] = meta


static func set_timeline(doc: Dictionary, fps: int, duration: float, loop: bool = true) -> void:
	var meta: Dictionary = doc.get("meta", {})
	var t: Dictionary = meta.get("timeline", {})
	t["fps"] = clampi(fps, 1, 120)
	t["duration"] = clampf(duration, 0.01, 3600.0)
	t["loop"] = loop
	meta["timeline"] = t
	doc["meta"] = meta


# ================= 编辑 =================

## 加节点。id 为空时按类型尾段自动生成唯一 id（blur_1 / checker_1 …）。
static func add_node(doc: Dictionary, type: String, node_id: String = "",
		pos: Vector2 = Vector2.ZERO, params: Dictionary = {}) -> Dictionary:
	var id := node_id.strip_edges()
	if id.is_empty():
		var prefix := type.get_slice(".", 1) if type.contains(".") else type
		id = unique_id(doc, prefix)
	var node_data := {
		"id": id,
		"type": type,
		"pos": [pos.x, pos.y],
		"params": params.duplicate(true),
		"collapsed": false,
	}
	(doc["nodes"] as Array).append(node_data)
	return node_data


static func remove_node(doc: Dictionary, node_id: String) -> void:
	var nodes: Array = doc.get("nodes", [])
	var index := node_index(doc, node_id)
	if index < 0:
		return
	nodes.remove_at(index)
	var kept: Array = []
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		if String(edge.get("from", "")) != node_id and String(edge.get("to", "")) != node_id:
			kept.append(edge)
	doc["edges"] = kept
	if String(doc.get("output", "")) == node_id:
		doc["output"] = ""
	for frame in doc.get("frames", []):
		var attached: Array = (frame as Dictionary).get("nodes", [])
		var remaining: Array = []
		for attached_id in attached:
			if String(attached_id) != node_id:
				remaining.append(attached_id)
		(frame as Dictionary)["nodes"] = remaining


static func unique_id(doc: Dictionary, prefix: String) -> String:
	var base := prefix.strip_edges()
	if base.is_empty():
		base = "node"
	base = base.replace(".", "_").replace(" ", "_")
	var i := 1
	while not node(doc, "%s_%d" % [base, i]).is_empty():
		i += 1
	return "%s_%d" % [base, i]


## 连接两个端口。替换目标端口上已有的连接；会拒绝类型不合法与成环。
## 返回 LINK_* 常量；失败时不改变文档。
static func connect_ports(doc: Dictionary, from: String, from_port: String,
		to: String, to_port: String) -> int:
	if from == to:
		return LINK_NO_NODE
	var from_node := node(doc, from)
	var to_node := node(doc, to)
	if from_node.is_empty() or to_node.is_empty():
		return LINK_NO_NODE
	var from_def := FxCatalog.def(from_node.get("type", ""))
	var to_def := FxCatalog.def(to_node.get("type", ""))
	if from_def == null or to_def == null:
		return LINK_NO_NODE
	var from_ports: Dictionary = FxCatalog.ports(from_def, from_node.get("params", {}))
	var to_ports: Dictionary = FxCatalog.ports(to_def, to_node.get("params", {}))
	var from_spec := FxCatalog.find_port(from_ports.get("outputs", []), from_port)
	var to_spec := FxCatalog.find_port(to_ports.get("inputs", []), to_port)
	if from_spec.is_empty() or to_spec.is_empty():
		return LINK_NO_PORT
	if not FxPortType.can_connect(from_spec.get("type", ""), to_spec.get("type", "")):
		return LINK_TYPE

	var edges: Array = doc.get("edges", [])
	var replaced: Dictionary = {}
	for i in range(edges.size()):
		var edge: Dictionary = edges[i]
		if String(edge.get("to", "")) == to and String(edge.get("to_port", "")) == to_port:
			replaced = edge
			edges.remove_at(i)
			break
	edges.append({
		"from": from,
		"from_port": from_port,
		"to": to,
		"to_port": to_port,
	})
	if has_cycle(doc):
		edges.pop_back()
		if not replaced.is_empty():
			edges.append(replaced)
		return LINK_CYCLE
	return LINK_OK


static func disconnect_ports(doc: Dictionary, from: String, from_port: String,
		to: String, to_port: String) -> void:
	var edges: Array = doc.get("edges", [])
	var kept: Array = []
	for item in edges:
		var edge: Dictionary = item
		var match_all := String(edge.get("from", "")) == from \
			and String(edge.get("from_port", "")) == from_port \
			and String(edge.get("to", "")) == to \
			and String(edge.get("to_port", "")) == to_port
		if not match_all:
			kept.append(edge)
	doc["edges"] = kept


static func edge_into(doc: Dictionary, node_id: String, port_id: String) -> Dictionary:
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		if String(edge.get("to", "")) == node_id and String(edge.get("to_port", "")) == port_id:
			return edge
	return {}


static func edges_into(doc: Dictionary, node_id: String, port_id: String) -> Array:
	var out: Array = []
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		if String(edge.get("to", "")) == node_id and String(edge.get("to_port", "")) == port_id:
			out.append(edge)
	return out


static func edges_from(doc: Dictionary, node_id: String, port_id: String) -> Array:
	var out: Array = []
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		if String(edge.get("from", "")) == node_id and String(edge.get("from_port", "")) == port_id:
			out.append(edge)
	return out


static func _has_edge(edges: Array, from: String, from_port: String,
		to: String, to_port: String) -> bool:
	for item in edges:
		var edge: Dictionary = item
		if String(edge.get("from", "")) == from \
				and String(edge.get("from_port", "")) == from_port \
				and String(edge.get("to", "")) == to \
				and String(edge.get("to_port", "")) == to_port:
			return true
	return false


# ================= 校验 =================

## 结构 + 端口 + 必需输入 + 输出 + 环。返回人类可读的错误列表，空数组 = 健康。
static func validate(doc: Dictionary, _unused: Variant = null) -> Array[String]:
	var errors: Array[String] = []
	if String(doc.get("format", "")) != FORMAT:
		errors.append("文档格式不是 %s" % FORMAT)
	if int(doc.get("version", 0)) > VERSION:
		errors.append("文档版本 %d 高于当前支持的 %d" % [int(doc.get("version", 0)), VERSION])
	var seen: Dictionary = {}
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		if id.is_empty():
			errors.append("存在缺少 id 的节点")
			continue
		if seen.has(id):
			errors.append("节点 id 重复：%s" % id)
		seen[id] = true
		var d := FxCatalog.def(node_data.get("type", ""))
		if d == null:
			errors.append("节点 %s 的类型不存在：%s" % [id, String(node_data.get("type", ""))])
			continue
		var ports: Dictionary = FxCatalog.ports(d, node_data.get("params", {}))
		for p in ports.get("inputs", []):
			if bool((p as Dictionary).get("required", false)) \
					and edge_into(doc, id, String((p as Dictionary).get("id", ""))).is_empty():
				errors.append("节点 %s 的必需输入 %s 未连接" % [id, String((p as Dictionary).get("id", ""))])
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		var from := String(edge.get("from", ""))
		var to := String(edge.get("to", ""))
		var from_node := node(doc, from)
		var to_node := node(doc, to)
		if from_node.is_empty() or to_node.is_empty():
			errors.append("连线指向不存在的节点：%s → %s" % [from, to])
			continue
		var from_def := FxCatalog.def(from_node.get("type", ""))
		var to_def := FxCatalog.def(to_node.get("type", ""))
		if from_def == null or to_def == null:
			continue
		var from_ports: Dictionary = FxCatalog.ports(from_def, from_node.get("params", {}))
		var to_ports: Dictionary = FxCatalog.ports(to_def, to_node.get("params", {}))
		var from_spec := FxCatalog.find_port(from_ports.get("outputs", []), String(edge.get("from_port", "")))
		var to_spec := FxCatalog.find_port(to_ports.get("inputs", []), String(edge.get("to_port", "")))
		if from_spec.is_empty() or to_spec.is_empty():
			errors.append("连线端口不存在：%s.%s → %s.%s"
				% [from, String(edge.get("from_port", "")), to, String(edge.get("to_port", ""))])
			continue
		if not FxPortType.can_connect(from_spec.get("type", ""), to_spec.get("type", "")):
			errors.append("端口类型不兼容：%s(%s) → %s(%s)"
				% [from, String(from_spec.get("type", "")), to, String(to_spec.get("type", ""))])
	var output := output_id(doc)
	if output.is_empty():
		errors.append("未指定输出节点")
	else:
		var output_node := node(doc, output)
		if output_node.is_empty():
			errors.append("输出节点不存在：%s" % output)
		else:
			var d := FxCatalog.def(output_node.get("type", ""))
			if d == null or not d.is_output:
				errors.append("节点 %s 不是输出类型" % output)
	if has_cycle(doc):
		errors.append("图存在环（数据流与执行流都不允许成环，循环请用 flow.for）")
	return errors


## 删掉端口已经不存在的连线（图层增删、动态端口收缩之后调用）。
## 只做结构清理，不碰仍然合法的边；返回删除条数。
static func prune_edges(doc: Dictionary) -> int:
	var kept: Array = []
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		var from_node := node(doc, String(edge.get("from", "")))
		var to_node := node(doc, String(edge.get("to", "")))
		if from_node.is_empty() or to_node.is_empty():
			continue
		var from_def := FxCatalog.def(from_node.get("type", ""))
		var to_def := FxCatalog.def(to_node.get("type", ""))
		if from_def == null or to_def == null:
			continue
		var from_ports: Dictionary = FxCatalog.ports(from_def, from_node.get("params", {}))
		var to_ports: Dictionary = FxCatalog.ports(to_def, to_node.get("params", {}))
		var from_spec := FxCatalog.find_port(from_ports.get("outputs", []), String(edge.get("from_port", "")))
		var to_spec := FxCatalog.find_port(to_ports.get("inputs", []), String(edge.get("to_port", "")))
		if from_spec.is_empty() or to_spec.is_empty():
			continue
		if not FxPortType.can_connect(from_spec.get("type", ""), to_spec.get("type", "")):
			continue
		kept.append(edge)
	var removed := (doc.get("edges", []) as Array).size() - kept.size()
	doc["edges"] = kept
	return removed


static func has_cycle(doc: Dictionary) -> bool:
	var adjacency: Dictionary = {}
	for item in doc.get("nodes", []):
		adjacency[String((item as Dictionary).get("id", ""))] = []
	for item in doc.get("edges", []):
		var edge: Dictionary = item
		var from := String(edge.get("from", ""))
		if adjacency.has(from):
			(adjacency[from] as Array).append(String(edge.get("to", "")))
	var state: Dictionary = {}
	for id in adjacency.keys():
		if int(state.get(id, 0)) == 0 and _dfs_cycle(String(id), adjacency, state):
			return true
	return false


static func _dfs_cycle(node_id: String, adjacency: Dictionary, state: Dictionary) -> bool:
	state[node_id] = 1
	for next_id in adjacency.get(node_id, []):
		var mark := int(state.get(String(next_id), 0))
		if mark == 1:
			return true
		if mark == 0 and _dfs_cycle(String(next_id), adjacency, state):
			return true
	state[node_id] = 2
	return false


# ================= 存盘 =================

static func save(doc: Dictionary, path: String) -> Error:
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(doc, "\t"))
	file.close()
	return OK


static func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("FxGraphDoc：文件不存在 %s" % path)
		return create()
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_warning("FxGraphDoc：文件为空 %s" % path)
		return create()
	var raw: Variant = JSON.parse_string(text)
	if not raw is Dictionary:
		push_error("FxGraphDoc：不是合法 JSON 对象 %s" % path)
		return create()
	return normalize(raw)


# ================= 小工具 =================

static func pair_of(value: Variant) -> Array:
	if value is Vector2:
		return [value.x, value.y]
	if value is Array:
		var arr: Array = value
		if arr.size() >= 2:
			return [float(arr[0]), float(arr[1])]
	if value is Dictionary:
		var d: Dictionary = value
		return [float(d.get("x", 0.0)), float(d.get("y", 0.0))]
	return [0.0, 0.0]


static func rect_of(value: Variant) -> Array:
	if value is Rect2:
		return [value.position.x, value.position.y, value.size.x, value.size.y]
	if value is Array:
		var arr: Array = value
		if arr.size() >= 4:
			return [float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3])]
	return [0.0, 0.0, 200.0, 120.0]
