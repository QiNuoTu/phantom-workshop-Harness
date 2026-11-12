class_name FxOpRegistry
extends RefCounted
## 算子注册表：op_id → Callable。节点定义只存字符串 id，不引用脚本路径。
##
## 算子全部由插件贡献（FxPlugin.ops()）。基座这里不 merge 任何具体模块，
## 执行器只问 get_op(def.op)，永远不需要知道具体节点类型。

static var _ops: Dictionary = {}
static var _time_dependent: Dictionary = {}
static var _built: bool = false


static func ensure_built() -> void:
	# 不再内置任何算子：没有插件时就是空表，节点定义也不会存在。
	_built = true


## 插件宿主接管注册表：清空内置集合，后续全部由插件注册。
static func clear() -> void:
	_ops.clear()
	_time_dependent.clear()
	_built = true


static func get_op(id: Variant) -> Callable:
	ensure_built()
	return _ops.get(StringName(String(id)), Callable())


static func has_op(id: Variant) -> bool:
	ensure_built()
	return _ops.has(StringName(String(id)))


static func is_time_dependent(id: Variant) -> bool:
	ensure_built()
	return _time_dependent.has(StringName(String(id)))


## 插件注册算子时一并声明时间相关性。
static func register_ops(ops: Dictionary, time_dependent: Array = []) -> void:
	ensure_built()
	for key in ops.keys():
		_ops[StringName(String(key))] = ops[key]
	for key in time_dependent:
		_time_dependent[StringName(String(key))] = true


static func register_time_dependent(id: Variant) -> void:
	_time_dependent[StringName(String(id))] = true


static func ids() -> Array[StringName]:
	ensure_built()
	var out: Array[StringName] = []
	for key in _ops.keys():
		out.append(StringName(key))
	out.sort()
	return out
