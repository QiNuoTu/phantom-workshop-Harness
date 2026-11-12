class_name FxGraphAccess
extends RefCounted
## 蓝图层访问「图领域」的**唯一契约**（论文 §6.1 系统边界 + §6.2 服务代理）。
##
## 为什么需要它：GDScript 的 `class_name` 是编译期全局符号。蓝图插件若直接写
## `FxCatalog.def()` / `FxPortType.can_connect()`，即使物理上分属两个插件，
## 仍然与解释器核心强耦合：换一个执行器实现、或者停用 core.graph，蓝图都要改或崩。
##
## 这一层把「解释器所在位置」重化成一个 coeffect：蓝图层只依赖这个抽象契约，
## 由 core.graph 用 graph_access() 贡献具体实现，FxGraphFacade 做多路代理。
## 默认实现全部返回安全空值 —— 没有任何解释器实现时蓝图仍能实例化，只是空画布。
##
## 契约里只出现微内核的纯数据类型（FxNodeDef / Dictionary / Array / Color），
## 不出现 FxCatalog、FxPortType、FxGraphDoc、FxGraphRunner 中的任何一个。

var id: String = "null"
var label: String = "无图解释器"


func describe() -> String:
	return label


# ---- 节点目录 ----

func catalog_all() -> Array[FxNodeDef]:
	return []


func catalog_def(_node_type: String) -> FxNodeDef:
	return null


func catalog_has_def(_node_type: String) -> bool:
	return false


func catalog_ports(_which: Variant, _params: Dictionary = {}) -> Dictionary:
	return {"inputs": [], "outputs": []}


func catalog_find_port(_ports: Array, _port_id: String) -> Dictionary:
	return {}


# ---- 端口类型表 ----

func port_order() -> Array:
	return [&"any"]


func port_any() -> StringName:
	return &"any"


func port_exec() -> StringName:
	return &"exec"


func port_image() -> StringName:
	return &"image"


func port_normalize(type: Variant) -> StringName:
	return StringName(String(type))


func port_id_of(_type: Variant) -> int:
	return 0


func port_color_of(_type: Variant) -> Color:
	return Color(0.6, 0.64, 0.7)


func port_label_of(_type: Variant) -> String:
	return "任意"


func port_can_connect(_from_type: Variant, _to_type: Variant) -> bool:
	return false


# ---- 值转换（参数控件用，避免蓝图层直接引用端口表） ----

func as_number(value: Variant, fallback: float = 0.0) -> float:
	return float(value) if value is float or value is int else fallback


func as_int(value: Variant, fallback: int = 0) -> int:
	return int(value) if value is float or value is int else fallback


func as_bool(value: Variant, fallback: bool = false) -> bool:
	return bool(value) if value is bool else fallback


func as_string(value: Variant, fallback: String = "") -> String:
	return String(value) if value is String else fallback


func as_color(value: Variant, fallback: Color = Color.WHITE) -> Color:
	return value if value is Color else fallback


func as_vec2(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	return value if value is Vector2 else fallback


# ---- 文档结构 ----

func doc_node(_doc: Dictionary, _node_id: Variant) -> Dictionary:
	return {}


func doc_output_id(_doc: Dictionary) -> String:
	return ""


func doc_timeline(_doc: Dictionary) -> Dictionary:
	return {"fps": 30, "duration": 1.0, "loop": true}


## 画布尺寸是图文档的公开属性：节点通过 ctx.canvas 读取，编辑器通过这里设置。
func doc_canvas(_doc: Dictionary) -> Vector2i:
	return Vector2i(128, 128)


func set_doc_canvas(_doc: Dictionary, _size: Vector2i) -> bool:
	return false


func doc_meta(_doc: Dictionary, _key: String, fallback: Variant = null) -> Variant:
	return fallback


## 指向某个输入端口的连线（没有则空字典）。视图用它决定折叠时保留哪些行。
func doc_edge_into(_doc: Dictionary, _node_id: String, _port_id: String) -> Dictionary:
	return {}


# ---- 文档构建 / 存取（工程嵌套与节点打包要用） ----

## 新建一张空图文档（带默认 meta）。
func doc_new(_name: String = "未命名") -> Dictionary:
	return {}


## 往指定文档加节点（不动当前文档）；返回新节点的数据。
func doc_add_node(_doc: Dictionary, _node_type: String, _node_id: String,
		_pos: Vector2, _params: Dictionary) -> Dictionary:
	return {}


func doc_connect(_doc: Dictionary, _from: String, _from_port: String,
		_to: String, _to_port: String) -> int:
	return 4


func doc_set_output(_doc: Dictionary, _node_id: String) -> void:
	pass


## 装载前的规整：provider 负责把任意输入夹成合法文档，基座只管收下。
func doc_normalize(doc: Dictionary) -> Dictionary:
	return doc.duplicate(true)


func doc_remove_node(_doc: Dictionary, _node_id: String) -> void:
	pass


func doc_disconnect(_doc: Dictionary, _from: String, _from_port: String,
		_to: String, _to_port: String) -> void:
	pass


## 按路径写参数（"layers.0.opacity" 这类嵌套轨道）：图层/数组的展开规则属于图语义，
## 基座不复制一份，直接问 provider。
func doc_apply_path(_doc: Dictionary, _node_id: String, _path: String, _value: Variant) -> bool:
	return false


func doc_set_timeline(_doc: Dictionary, _fps: int, _duration: float, _loop: bool) -> void:
	pass


func doc_set_node_pos(_doc: Dictionary, _node_id: String, _pos: Vector2) -> void:
	pass


func doc_save(_doc: Dictionary, _path: String) -> int:
	return 1


func doc_load(_path: String) -> Dictionary:
	return {}


## 把节点参数里的路径解析成真实可读的路径（相对资源根、`res://`、`user://` 都认）。
## 解析不出来返回空串 —— 调用方据此区分「没填」和「填了但找不到」。
func doc_resolve_path(raw: String) -> String:
	var key := raw.strip_edges()
	if key.is_empty():
		return ""
	return key if FileAccess.file_exists(key) else ""


## 这个节点类型能不能「进去编辑」：子图这类把另一份文档当节点用的类型返回 true。
## 编辑器用它决定双击是否下钻，因此不需要认识任何具体类型 id。
func catalog_openable(_node_type: String) -> bool:
	return false


## 目录就绪（首次扫描插件、把节点定义灌进实现里）。外壳启动时调一次。
func catalog_ensure() -> void:
	pass


## 插件增删后重建目录与应用算子表。
func catalog_refresh() -> void:
	pass


# ---- 连线错误码 ----

func link_ok() -> int:
	return 0


func link_no_node() -> int:
	return 1


func link_type() -> int:
	return 3


func link_cycle() -> int:
	return 4
