class_name FxGraphAccessCore
extends FxGraphAccess
## core.graph 提供的图能力实现：把解释器核心的静态类封装进 FxGraphAccess 契约。
## 只有这个文件认识 FxCatalog / FxPortType / FxGraphDoc；蓝图层完全不认识。


func _init() -> void:
	id = "core.graph"
	label = "内置图求值器（FxGraphRunner）"


func catalog_all() -> Array[FxNodeDef]:
	return FxCatalog.all()


func catalog_def(node_type: String) -> FxNodeDef:
	return FxCatalog.def(node_type)


func catalog_has_def(node_type: String) -> bool:
	return FxCatalog.has_def(node_type)


func catalog_ports(which: Variant, params: Dictionary = {}) -> Dictionary:
	return FxCatalog.ports(which, params)


func catalog_find_port(ports: Array, port_id: String) -> Dictionary:
	return FxCatalog.find_port(ports, port_id)


func port_order() -> Array:
	return FxPortType.ORDER


func port_any() -> StringName:
	return FxPortType.ANY


func port_exec() -> StringName:
	return FxPortType.EXEC


func port_image() -> StringName:
	return FxPortType.IMAGE


func port_normalize(type: Variant) -> StringName:
	return FxPortType.normalize(type)


func port_id_of(type: Variant) -> int:
	return FxPortType.id_of(type)


func port_color_of(type: Variant) -> Color:
	return FxPortType.color_of(type)


func port_label_of(type: Variant) -> String:
	return FxPortType.label_of(type)


func port_can_connect(from_type: Variant, to_type: Variant) -> bool:
	return FxPortType.can_connect(from_type, to_type)


func as_number(value: Variant, fallback: float = 0.0) -> float:
	return FxPortType.as_number(value, fallback)


func as_int(value: Variant, fallback: int = 0) -> int:
	return FxPortType.as_int(value, fallback)


func as_bool(value: Variant, fallback: bool = false) -> bool:
	return FxPortType.as_bool(value, fallback)


func as_string(value: Variant, fallback: String = "") -> String:
	return FxPortType.as_string(value, fallback)


func as_color(value: Variant, fallback: Color = Color.WHITE) -> Color:
	return FxPortType.as_color(value, fallback)


func as_vec2(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	return FxPortType.as_vec2(value, fallback)


func doc_node(doc: Dictionary, node_id: Variant) -> Dictionary:
	return FxGraphDoc.node(doc, node_id)


func doc_output_id(doc: Dictionary) -> String:
	return FxGraphDoc.output_id(doc)


func doc_timeline(doc: Dictionary) -> Dictionary:
	return FxGraphDoc.timeline(doc)


func doc_canvas(doc: Dictionary) -> Vector2i:
	return FxGraphDoc.canvas(doc)


func doc_res_scale(doc: Dictionary, node_id: String) -> float:
	return FxGraphDoc.res_scale_of(FxGraphDoc.node(doc, node_id))


func set_doc_canvas(doc: Dictionary, size: Vector2i) -> bool:
	var width := clampi(size.x, 1, 4096)
	var height := clampi(size.y, 1, 4096)
	FxGraphDoc.set_canvas(doc, width, height)
	return true


func doc_meta(doc: Dictionary, key: String, fallback: Variant = null) -> Variant:
	return FxGraphDoc.meta_value(doc, key, fallback)


func doc_edge_into(doc: Dictionary, node_id: String, port_id: String) -> Dictionary:
	return FxGraphDoc.edge_into(doc, node_id, port_id)


func doc_new(name: String = "未命名") -> Dictionary:
	return FxGraphDoc.create(name)


func doc_add_node(doc: Dictionary, node_type: String, node_id: String,
		pos: Vector2, params: Dictionary) -> Dictionary:
	var created := FxGraphDoc.add_node(doc, node_type, node_id, pos, params)
	# 「第一个输出节点自动成为最终输出」是图语义，留在图容器里；
	# 基座的文档存储只负责撤销与通知，不再认识 is_output。
	var def := FxCatalog.def(node_type)
	if def != null and def.is_output and FxGraphDoc.output_id(doc).is_empty():
		doc["output"] = String(created.get("id", ""))
	return created


func doc_normalize(doc: Dictionary) -> Dictionary:
	return FxGraphDoc.normalize(doc)


func doc_remove_node(doc: Dictionary, node_id: String) -> void:
	FxGraphDoc.remove_node(doc, node_id)


func doc_disconnect(doc: Dictionary, from: String, from_port: String,
		to: String, to_port: String) -> void:
	FxGraphDoc.disconnect_ports(doc, from, from_port, to, to_port)


func doc_apply_path(doc: Dictionary, node_id: String, path: String, value: Variant) -> bool:
	var node_data := FxGraphDoc.node(doc, node_id)
	if node_data.is_empty():
		return false
	# 绑定型参数（节点声明 `binds`，例如输出节点的画布宽/高）不是节点自己的数据，
	# 而是文档里某一处值的视图：写它 = 写那一处，节点上永远不留值。
	# 这一层是**模型级**的拦截 —— 界面、脚本、探针、任何写入方都走这里，
	# 所以「两个来源」不可能再从别的入口长回来。
	if _apply_binding(doc, node_data, path, value):
		return true
	var params: Dictionary = node_data.get("params", {})
	FxCatalog.apply_path(params, path, value)
	node_data["params"] = params
	return true


## 处理绑定型参数。返回 true 表示「这次写入已经被绑定接管，不要再写进节点」。
##
## 0 是「跟随」的哨兵值：它不表达任何尺寸，只表示「别在这里覆盖」——
## 直接吞掉，也不写进节点（写进去就又变成第二个来源）。
func _apply_binding(doc: Dictionary, node_data: Dictionary, path: String,
		value: Variant) -> bool:
	# 嵌套路径（layers.0.opacity 这类）不可能是绑定：绑定只声明在顶层参数上。
	if path.is_empty() or path.contains("."):
		return false
	var def := FxCatalog.def(node_data.get("type", ""))
	if def == null:
		return false
	var binds := String(def.param(path).get("binds", ""))
	if binds.is_empty():
		return false
	var size := int(as_number(value, 0.0))
	if size <= 0:
		return true
	var canvas := FxGraphDoc.canvas(doc)
	var next := canvas
	match binds:
		"canvas.width":
			next = Vector2i(size, canvas.y)
		"canvas.height":
			next = Vector2i(canvas.x, size)
		_:
			return true
	if next != canvas:
		set_doc_canvas(doc, next)
	return true


func doc_set_timeline(doc: Dictionary, fps: int, duration: float, loop: bool) -> void:
	FxGraphDoc.set_timeline(doc, fps, duration, loop)


func doc_set_node_pos(doc: Dictionary, node_id: String, pos: Vector2) -> void:
	var node_data := FxGraphDoc.node(doc, node_id)
	if node_data.is_empty():
		return
	node_data["pos"] = [pos.x, pos.y]


func doc_connect(doc: Dictionary, from: String, from_port: String,
		to: String, to_port: String) -> int:
	return FxGraphDoc.connect_ports(doc, from, from_port, to, to_port)


func doc_set_output(doc: Dictionary, node_id: String) -> void:
	doc["output"] = node_id


func doc_save(doc: Dictionary, path: String) -> int:
	return FxGraphDoc.save(doc, path)


func doc_load(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var raw: Variant = JSON.parse_string(text)
	if not raw is Dictionary:
		return {}
	return FxGraphDoc.normalize(raw)


## 与子图算子共用同一条解析链，避免「能渲染但编辑器打不开」这种错位。
func doc_resolve_path(raw: String) -> String:
	return FxOpsSubgraph.resolve_path(raw)


## 子图 / 子图输入 / 子图输出以外都不下钻。判据是端口生成器而不是类型 id：
## 以后有别的「把文档当节点」的类型，只要挂 subgraph provider 就自动可进。
func catalog_openable(node_type: String) -> bool:
	var def := FxCatalog.def(node_type)
	return def != null and String(def.port_provider) == "subgraph"


func catalog_ensure() -> void:
	FxCatalog.ensure_loaded()


func catalog_refresh() -> void:
	FxCatalog.apply_registry()


## 算子表是本插件对账本的缓存：卸载前由基座请我们清掉，避免旧 Callable 活过插件。
func reset_runtime_tables() -> void:
	FxOpRegistry.clear()


func link_ok() -> int:
	return FxGraphDoc.LINK_OK


func link_no_node() -> int:
	return FxGraphDoc.LINK_NO_NODE


func link_type() -> int:
	return FxGraphDoc.LINK_TYPE


func link_cycle() -> int:
	return FxGraphDoc.LINK_CYCLE
