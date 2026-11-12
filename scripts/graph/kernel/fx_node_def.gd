class_name FxNodeDef
extends RefCounted
## 一个节点类型的完整定义（端口 / 参数 / 算子 id）——微内核里的**纯数据契约**。
##
## 定义来自插件贡献的 nodes*.json；实现是 op_id 指向的 Callable。
## 这个类不认识任何具体节点、算子、端口表或执行器，因此蓝图层可以静态类型化它，
## 却不必与解释器核心（core.graph）产生编译期耦合。
## 新增一种节点 = 加一条 JSON + 注册一个算子，两个文件之外零改动。

var id: StringName = &""
var label: String = ""
var category: String = ""
var description: String = ""
var op: StringName = &""
var inputs: Array[Dictionary] = []
var outputs: Array[Dictionary] = []
var params: Array[Dictionary] = []
var port_provider: StringName = &""
var is_output: bool = false
var has_exec_in: bool = false
var has_exec_out: bool = false
var cacheable: bool = true
## 即使没有下游连线也要每帧求值（输出预览之类的「汇点」节点用）。
## 执行器在跑完输出节点后统一补跑这些节点，因此它们可以是图的旁支。
var evaluate_always: bool = false
## 这个节点的算子必须在**主线程**求值（GPU 资源、有状态的系统调用等）。
## 图里只要有一个这样的节点，渲染服务就不把这一帧交给工作线程。
var gpu: bool = false

## ---- 视觉表示（可选，全部有回退） ----
## `icon`：节点自己的纹理，相对**所属插件目录**（也可写 res:// / user:// 绝对路径）。
## 没有纹理时面板会退到「真实渲染样张」，再退到按分类生成的颜色块 —— 三级回退。
var icon: String = ""
## `icon_anim`：把上面那张图当精灵表播动画，{cols, rows, fps}。
## 留空就是静帧；缺字段按 1 列 1 行 8fps 处理。
var icon_anim: Dictionary = {}
## 这个定义来自哪个插件（由 FxCatalog 在加载时按账本反查填好），
## 让面板能显示「归属」，而 UI 不用认识注册表。
var owner_plugin: String = ""
## 节点定义文件路径（res://plugins/<id>/nodes*.json），图标相对解析的基准。
var source_file: String = ""


static func from_dict(raw: Dictionary, fallback_category: String = "") -> FxNodeDef:
	var d := FxNodeDef.new()
	d.id = StringName(String(raw.get("id", "")))
	d.label = String(raw.get("label", String(d.id)))
	d.category = String(raw.get("category", fallback_category))
	d.description = String(raw.get("desc", raw.get("description", "")))
	d.op = StringName(String(raw.get("op", "")))
	d.port_provider = StringName(String(raw.get("port_provider", "")))
	d.is_output = bool(raw.get("is_output", false))
	d.evaluate_always = bool(raw.get("evaluate_always", false))
	d.gpu = bool(raw.get("gpu", false))
	d.icon = String(raw.get("icon", ""))
	var anim: Variant = raw.get("icon_anim", raw.get("icon_sheet", {}))
	if anim is Dictionary and not (anim as Dictionary).is_empty():
		d.icon_anim = (anim as Dictionary).duplicate(true)
	elif d.icon.ends_with(".gif"):
		# 没写参数但给的是动图：按单行精灵表（宽图切帧）猜一个能播的参数。
		d.icon_anim = {"cols": 0, "rows": 1, "fps": 8}
	for item in raw.get("inputs", []):
		if item is Dictionary:
			d.inputs.append(_norm_port(item))
	for item in raw.get("outputs", []):
		if item is Dictionary:
			d.outputs.append(_norm_port(item))
	for item in raw.get("params", []):
		if item is Dictionary:
			d.params.append(_norm_param(item))
	d.has_exec_in = _has_type(d.inputs, &"exec")
	d.has_exec_out = _has_type(d.outputs, &"exec")
	# 有执行入口的节点由执行流驱动；拉取式求值会把副作用跑两遍，默认不缓存。
	d.cacheable = bool(raw.get("cache", not d.has_exec_in))
	return d


static func _norm_port(raw: Dictionary) -> Dictionary:
	var id := String(raw.get("id", ""))
	var type_name := StringName(String(raw.get("type", "any")))
	if type_name == &"":
		type_name = &"any"
	return {
		"id": id,
		"label": String(raw.get("label", id)),
		"type": type_name,
		"required": bool(raw.get("required", false)),
		"multi": bool(raw.get("multi", false)),
		"bindable": bool(raw.get("bindable", false)),
		"param": bool(raw.get("param", false)),
	}


static func _norm_param(raw: Dictionary) -> Dictionary:
	var id := String(raw.get("id", ""))
	# 参数默认**可连线**：只要能被一个值表达，就应该能接受上游。
	# 结构性的参数（图层数组、分支步数）自己写 "bindable": false。
	var out: Dictionary = raw.duplicate(true)
	out["id"] = id
	out["label"] = String(raw.get("label", id))
	out["kind"] = String(raw.get("kind", "float"))
	out["default"] = raw.get("default", 0.0)
	out["bindable"] = bool(raw.get("bindable", true))
	return out


static func _has_type(ports: Array[Dictionary], type: StringName) -> bool:
	for p in ports:
		if StringName(p.get("type", "")) == type:
			return true
	return false


func input_port(id: String) -> Dictionary:
	return _find(inputs, id)


func output_port(id: String) -> Dictionary:
	return _find(outputs, id)


func param(id: String) -> Dictionary:
	return _find(params, id)


func _find(list: Array[Dictionary], id: String) -> Dictionary:
	for item in list:
		if String(item.get("id", "")) == id:
			return item
	return {}


## 面板与节点副标题用的一句话摘要。
func summary() -> String:
	return "%s · %d 入 / %d 出" % [category, inputs.size(), outputs.size()]


## 默认参数（深拷贝，调用方可随意改）。
func default_params() -> Dictionary:
	var out: Dictionary = {}
	for p in params:
		var value: Variant = p.get("default", 0.0)
		out[String(p["id"])] = value.duplicate(true) if value is Array or value is Dictionary else value
	return out
