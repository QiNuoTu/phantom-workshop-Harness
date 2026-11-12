class_name FxNative
extends RefCounted
## GDExtension 桥：把 C++ 算子的**窄 ABI** 适配成执行器认识的 Callable。
##
## 为什么需要这一层：GDExtension 里注册的类只能继承 native class（Object /
## RefCounted / Node …），既没法继承 GDScript 的 `FxPlugin`，也没法直接拿到
## `FxEvalContext` 这种脚本类型。所以桥这一层只交换**基础类型**：
##
##     C++ 侧：  fx_exec(inputs: Dictionary, params: Dictionary, env: Dictionary) -> Dictionary
##     桥接侧：  func(ctx, node, def, inputs, params) -> Dictionary
##
## `env` 是求值上下文的只读镜像（画布、时间、质量、策略选项…）。C++ 不需要
## 认识任何 GDScript 类，也不需要 include 本项目的头文件——这是"插件可独立
## 编译、独立分发"的前提。`env["abi"]` 就是这份字典的版本号。
##
## 硬性约定：
##   · C++ 侧**不得持有跨帧可变状态**（工作线程会反复调用同一个实例）；
##     真要缓存，用 `env["node"]` 做键、自己加锁，并声明 `thread_safe: false`。
##   · 原生库一旦加载**不会卸载**（GDExtension 的进程级限制）；停用插件只撤回
##     算子贡献，DLL 仍在内存里。这是如实告知的代价，不是 bug。

## `env` 字典的版本。C++ 侧可据此判断字段是否存在，加字段必须升版本。
const ABI_VERSION := 1

## 已调用过 load_extension 的路径 → 结果，避免重复加载。
static var _loaded: Dictionary = {}
## 类名 → 实例。注册表里的 Callable 会长期引用它们，这里也留一份便于诊断。
static var _instances: Dictionary = {}
## 声明了非线程安全的算子 id → true。有任意一条就整体回退主线程渲染。
static var _unsafe: Dictionary = {}


## 加载一个 `.gdextension`。`path` 可以是 res:// 或绝对路径（外部插件目录）。
## 返回 {ok: bool, message: String}——失败交给调用方记到插件账本里。
static func load_library(path: String) -> Dictionary:
	if path.strip_edges().is_empty():
		return {"ok": false, "message": "原生库路径为空"}
	if _loaded.has(path):
		return _loaded[path]
	var report := {"ok": true, "message": ""}
	if not FileAccess.file_exists(path):
		report = {"ok": false, "message": "找不到 %s" % path}
	elif not Engine.has_singleton("GDExtensionManager"):
		report = {"ok": false, "message": "当前引擎不带 GDExtensionManager"}
	else:
		var status := GDExtensionManager.load_extension(path)
		if status != GDExtensionManager.LOAD_STATUS_OK \
				and status != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			report = {"ok": false, "message": _load_status_text(status, path)}
	_loaded[path] = report
	return report


## 把 GDExtension 注册的类绑定成算子。`class` 是 C++ 侧
## `GDREGISTER_CLASS` 注册的名字；类必须在库加载之后可用。
static func bind(cls: StringName, op_id: String, thread_safe: bool = true,
		owner: String = "") -> Callable:
	var native := instance(cls)
	if native == null:
		push_error("FxNative：找不到原生类 %s（算子 %s）" % [cls, op_id])
		return Callable()
	return bind_object(native, op_id, thread_safe, owner)


## 已经拿到对象时的绑定入口。测试用纯 GDScript 的「假原生」也能跑同一条路径。
static func bind_object(native: Object, op_id: String, thread_safe: bool = true,
		owner: String = "") -> Callable:
	if native == null or not native.has_method("fx_exec"):
		push_error("FxNative：%s 没有实现 fx_exec" % [op_id])
		return Callable()
	if not thread_safe:
		# 记下归属插件：停用它时要能把这个标记收回去，否则线程永远不回来。
		_unsafe[op_id] = owner
	# 闭包只捕获原生对象本身，不捕获任何插件实例 → 注册表持有它是安全的。
	# ctx 刻意按 Object 取：内核不能引用插件里的 FxEvalContext，只能鸭子类型读字段。
	return func(ctx: Object, node: Dictionary, def: FxNodeDef,
			inputs: Dictionary, params: Dictionary) -> Dictionary:
		if not is_instance_valid(native):
			return {}
		var env := env_of(ctx, node, def)
		var out: Variant = native.call("fx_exec", inputs, params, env)
		if out is Dictionary:
			return out as Dictionary
		if out != null:
			push_error("FxNative：%s 的 fx_exec 必须返回 Dictionary，实际是 %s"
				% [op_id, type_string(typeof(out))])
		return {}


## 求值上下文的只读镜像。**只放基础类型**：Dictionary / Array / String /
## int / float / bool / Vector2i / Color，保证 C++ 侧零依赖。
## ctx 是 `FxEvalContext`（插件侧类型），这里按 Object 读——内核不认识插件。
static func env_of(ctx: Object, node: Dictionary = {}, def: FxNodeDef = null) -> Dictionary:
	var canvas := Vector2i.ZERO
	var t := 0.0
	var fps := 30.0
	var quality := 1
	var operator_quality := 1.0
	var options: Dictionary = {}
	if ctx != null:
		canvas = ctx.get("canvas") as Vector2i
		t = float(ctx.get("t"))
		fps = maxf(float(ctx.get("fps")), 0.0001)
		quality = int(ctx.get("quality"))
		operator_quality = float(ctx.get("operator_quality"))
		var raw_options: Variant = ctx.get("options")
		if raw_options is Dictionary:
			options = raw_options as Dictionary
	return {
		"abi": ABI_VERSION,
		"node": String(node.get("id", "")),
		"type": String(node.get("type", "")),
		"op": String(def.op) if def != null else "",
		"canvas": canvas,
		"time": t,
		"fps": fps,
		"frame": int(round(t * fps)),
		"quality": quality,
		"operator_quality": operator_quality,
		"options": options,
	}


## 取（并保活）一个原生类的实例。同一个类只实例化一次。
static func instance(cls: StringName) -> Object:
	if _instances.has(cls):
		var kept: Variant = _instances[cls]
		if is_instance_valid(kept):
			return kept as Object
		_instances.erase(cls)
	var created: Object = null
	if ClassDB.class_exists(cls):
		created = ClassDB.instantiate(cls)
	else:
		var text := String(cls)
		if text.ends_with(".gd") and ResourceLoader.exists(text):
			var script: Script = load(text)
			if script != null and script.can_instantiate():
				created = script.new()
	if created != null:
		_instances[cls] = created
	return created


## 有算子声明了非线程安全时，渲染服务必须回到主线程。
static func thread_safe() -> bool:
	return _unsafe.is_empty()


## 插件被停用时收回它登记的非线程安全标记（DLL 仍留在内存里）。
static func release(owner: String) -> void:
	if owner.is_empty():
		return
	for key in _unsafe.keys():
		if String(_unsafe[key]) == owner:
			_unsafe.erase(key)


static func unsafe_ops() -> Array[String]:
	var out: Array[String] = []
	for key in _unsafe.keys():
		out.append(String(key))
	out.sort()
	return out


## 已注册的原生算子数量（诊断用）。
static func bound_count() -> int:
	return _instances.size()


static func loaded_libraries() -> Array[String]:
	var out: Array[String] = []
	for key in _loaded.keys():
		out.append(String(key))
	out.sort()
	return out


## 插件全量重扫 / 退出时清账。**不卸载 DLL**（做不到），只丢引用与标记。
static func reset() -> void:
	_instances.clear()
	_unsafe.clear()
	_loaded.clear()


static func _load_status_text(status: int, path: String) -> String:
	# 只依赖 LOAD_STATUS_OK / FAILED / ALREADY_LOADED / NOT_LOADED 这四个枚举；
	# 其它状态名在不同 4.x 版本间会改名，不写死。
	match status:
		GDExtensionManager.LOAD_STATUS_OK:
			return ""
		GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			return "已经加载过 %s" % path
		GDExtensionManager.LOAD_STATUS_NOT_LOADED:
			return "没有加载起来：%s" % path
		_:
			return "加载失败（架构不符 / 依赖缺失 / 引擎版本不兼容）：%s" % path
