class_name FxCatalog
extends RefCounted
## 节点类型目录：读插件贡献的节点定义 JSON，聚合成唯一的节点定义表。
##
## 这个类同时承担两件与“路径”有关的公共服务：
##   · value_at / apply_path：按 "layers.0.opacity" 这样的路径读写嵌套参数，
##     时间轴（TimelineOps）与参数面板共用，避免两边各写一套解析；
##   · ports()：把静态端口 + 可绑定参数端口 + 动态端口合成最终端口表，
##     执行器与编辑器都只认它，端口不会两边不一致。
##
## 目录是静态的：整个应用只有一份节点类型表，UI 不持有自己的副本。

static var _defs: Dictionary = {}
static var _order: Array[StringName] = []
static var _loaded: bool = false
static var _loading: bool = false
## 由插件账本填进来的节点定义文件列表（唯一来源）。
static var _sources: Array[String] = []


static func ensure_loaded() -> void:
	if _loaded or _loading:
		return
	_loading = true
	# 插件优先：宿主把结果写进中立注册表，这里只负责应用。
	if not FxRegistry.ready and not _ensure_plugins():
		reload()
	_loaded = true
	_loading = false
	apply_registry()


## 把注册表里的节点文件/算子/参数控件应用到目录与全局注册表。
## 插件重扫后由编辑器再调一次。
static func apply_registry() -> void:
	if not FxRegistry.ready:
		return
	set_sources(FxRegistry.node_files)
	reload()
	FxOpRegistry.clear()
	FxOpRegistry.register_ops(FxRegistry.ops, FxRegistry.time_ops)
	for kind in FxRegistry.param_kinds.keys():
		FxWidgetRegistry.register(String(kind), FxRegistry.param_kinds[kind])


static func set_sources(paths: Array) -> void:
	_sources.clear()
	for path in paths:
		_sources.append(String(path))


static func sources() -> Array[String]:
	return _sources.duplicate()


## 宿主脚本用实例方式加载：避免 FxCatalog ↔ FxPluginHost 的静态初始化环。
static func _ensure_plugins() -> bool:
	var script: Script = load("res://scripts/graph/plugins/fx_plugin_host.gd")
	if script == null:
		return false
	var host: Variant = script.new()
	if host == null:
		return false
	host.load_all()
	return FxRegistry.ready


static func reload() -> void:
	_defs.clear()
	_order.clear()
	_loaded = true
	# 基座不内置节点：节点定义**只能**由插件贡献。没有贡献就是空目录，
	# 这是正常状态（删掉 plugins/ 软件照样启动），不是错误也不是警告。
	var files: Array = _sources.duplicate()
	files.sort()
	var json_count := 0
	for file_path in files:
		if String(file_path).ends_with(".json"):
			json_count += 1
	# 启动报告按文件逐条推进（非启动期 expect/step 都是空操作）。
	FxBoot.expect(json_count)
	# 归属反查：账本里每条 node_file 贡献都记着是哪个插件交的。
	# 只读账本、不反向依赖宿主，UI 想显示「这个节点来自哪个插件」时直接读 def.owner_plugin。
	var owners := _node_file_owners()
	for file_path in files:
		var path := String(file_path)
		if not path.ends_with(".json"):
			continue
		var name := path.get_file()
		FxBoot.step("节点定义 %s/%s" % [path.get_base_dir().get_file(), name])
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			_catalog_error("无法读取 %s" % path)
			continue
		var raw: Variant = JSON.parse_string(text)
		if not raw is Dictionary:
			_catalog_error("%s 不是合法 JSON 对象" % path)
			continue
		var source: Dictionary = raw
		var category := String(source.get("category", name.get_basename()))
		for item in source.get("nodes", []):
			if not item is Dictionary:
				continue
			var d := FxNodeDef.from_dict(item, category)
			if d.id == &"":
				_catalog_error("%s 中有节点缺少 id" % path)
				continue
			d.source_file = path
			d.owner_plugin = String(owners.get(path, ""))
			if _defs.has(d.id):
				_catalog_error("节点类型重复 %s（%s）" % [d.id, path])
				continue
			_defs[d.id] = d
			_order.append(d.id)


## 节点定义文件 → 提供它的插件 id。账本是唯一真源，因此插件停用后归属自动消失。
static func _node_file_owners() -> Dictionary:
	var out: Dictionary = {}
	if not FxRegistry.ready:
		return out
	for entry in FxRegistry.ledger:
		if String(entry.get("kind", "")) != "node_file":
			continue
		var path := String(entry.get("value", ""))
		if path.is_empty() or out.has(path):
			continue
		out[path] = String(entry.get("owner", ""))
	return out


## 节点定义出错：启动期进启动报告（界面能显示「哪个文件坏了」），
## 平时只推错误，避免重复扫描把报告堆满。
static func _catalog_error(text: String) -> void:
	push_error("FxCatalog：" + text)
	if FxBoot.active():
		FxBoot.error("节点定义", text)


static func def(id: Variant) -> FxNodeDef:
	ensure_loaded()
	return _defs.get(StringName(String(id)), null) as FxNodeDef


static func has_def(id: Variant) -> bool:
	return def(id) != null


static func all() -> Array[FxNodeDef]:
	ensure_loaded()
	var out: Array[FxNodeDef] = []
	for id in _order:
		var d: FxNodeDef = _defs.get(id, null)
		if d != null:
			out.append(d)
	return out


static func categories() -> Array[String]:
	ensure_loaded()
	var out: Array[String] = []
	for id in _order:
		var d: FxNodeDef = _defs.get(id, null)
		if d != null and not out.has(d.category):
			out.append(d.category)
	return out


static func in_category(category: String) -> Array[FxNodeDef]:
	ensure_loaded()
	var out: Array[FxNodeDef] = []
	for id in _order:
		var d: FxNodeDef = _defs.get(id, null)
		if d != null and d.category == category:
			out.append(d)
	return out


## 合并默认参数与节点实际参数。动态端口、校验、执行都走这一份。
static func merged_params(d: FxNodeDef, params: Dictionary) -> Dictionary:
	var merged := d.default_params()
	for key in params.keys():
		merged[key] = params[key]
	return merged


## 最终端口表：静态端口 → 参数端口 → 动态端口。
## 返回 {inputs, outputs, def}，端口顺序就是 GraphNode 插槽顺序。
##
## **每个参数默认都有输入端口**：只要它能被一个值表达，就应该能被连线驱动。
## 只有三类例外，写在节点 JSON 里就能关掉一个端口：
##   · `bindable: false` —— 明确声明“这个参数不接受连线”；
##   · 结构性参数（图层数组、分支步数）—— 它们的值决定端口/连线本身；
##   · 值是数组/对象且没有对应端口类型的（同一件事的另一种写法）。
static func ports(which: Variant, params: Dictionary = {}) -> Dictionary:
	var d: FxNodeDef = which if which is FxNodeDef else def(which)
	if d == null:
		return {"inputs": [], "outputs": [], "def": null}
	var inputs: Array[Dictionary] = []
	for p in d.inputs:
		inputs.append(p.duplicate(true))
	var outputs: Array[Dictionary] = []
	for p in d.outputs:
		outputs.append(p.duplicate(true))
	for p in d.params:
		if not bool(p.get("bindable", true)):
			continue
		var pid := String(p.get("id", ""))
		if pid.is_empty() or _has_port(inputs, pid):
			continue
		var port_type := param_port_type(p)
		if port_type == &"":
			continue
		inputs.append({
			"id": pid,
			"label": String(p.get("label", pid)),
			"type": port_type,
			"required": false,
			"multi": false,
			"bindable": true,
			"param": true,
		})
	var merged := merged_params(d, params)
	if d.port_provider != &"":
		var built := FxPortProviders.build(d.port_provider, d, merged, inputs, outputs)
		# 提供者可能直接把传进去的数组原样返回；先深拷贝再 clear，否则会清空自己。
		var built_inputs: Array = (built.get("inputs", []) as Array).duplicate(true)
		var built_outputs: Array = (built.get("outputs", []) as Array).duplicate(true)
		inputs.clear()
		for p in built_inputs:
			if p is Dictionary:
				inputs.append(p)
		outputs.clear()
		for p in built_outputs:
			if p is Dictionary:
				outputs.append(p)
	return {"inputs": inputs, "outputs": outputs, "def": d}


## 参数 → 端口类型。空 StringName 表示这个参数不接受连线。
## 结构性参数（值本身决定端口表）与“无法用单个值表达”的复合值在这里被排除；
## 其余一律按 kind 或默认值推断，所以插件新增参数不需要再手动写 bindable。
static func param_port_type(param: Dictionary) -> StringName:
	var kind := String(param.get("kind", "float"))
	if kind in ["layers", "steps"]:
		return &""
	var mapped := FxPortType.kind_to_type(kind)
	if mapped != &"any":
		return mapped
	var fallback: Variant = param.get("default", null)
	match typeof(fallback):
		TYPE_STRING, TYPE_STRING_NAME:
			return &"string"
		TYPE_INT:
			return &"number"
		TYPE_FLOAT:
			return &"number"
		TYPE_BOOL:
			return &"bool"
		TYPE_COLOR:
			return &"color"
	return &""


static func _has_port(ports: Array, id: String) -> bool:
	for p in ports:
		if p is Dictionary and String((p as Dictionary).get("id", "")) == id:
			return true
	return false


static func find_port(ports: Array, id: String) -> Dictionary:
	for p in ports:
		if p is Dictionary and String((p as Dictionary).get("id", "")) == id:
			return p
	return {}


static func default_params(which: Variant) -> Dictionary:
	var d: FxNodeDef = which if which is FxNodeDef else def(which)
	return d.default_params() if d != null else {}


# ================= 路径读写（TimelineOps / 参数面板共用） =================

## 读嵌套值。路径段用 "." 分隔，数字段按数组下标解释。缺失返回 null。
static func value_at(params: Dictionary, path: String) -> Variant:
	if path.is_empty():
		return params
	var current: Variant = params
	for raw_segment in path.split(".", false):
		var segment := String(raw_segment)
		if current is Dictionary:
			if not (current as Dictionary).has(segment):
				return null
			current = (current as Dictionary)[segment]
		elif current is Array:
			if not segment.is_valid_int():
				return null
			var index := int(segment)
			if index < 0 or index >= (current as Array).size():
				return null
			current = (current as Array)[index]
		else:
			return null
	return current


## 写嵌套值：中间层缺失时按下一段是不是数字自动建字典或数组。
static func apply_path(params: Dictionary, path: String, value: Variant) -> void:
	var parts := path.split(".", false)
	if parts.is_empty():
		return
	var current: Variant = params
	for i in range(parts.size() - 1):
		var segment := String(parts[i])
		var next_is_index := String(parts[i + 1]).is_valid_int()
		if current is Dictionary:
			var dict: Dictionary = current
			var child: Variant = dict.get(segment)
			if not child is Dictionary and not child is Array:
				child = [] if next_is_index else {}
				dict[segment] = child
			current = child
		elif current is Array:
			var arr: Array = current
			var index := int(segment)
			if index < 0:
				return
			while arr.size() <= index:
				arr.append([] if next_is_index else {})
			var child2: Variant = arr[index]
			if not child2 is Dictionary and not child2 is Array:
				child2 = [] if next_is_index else {}
				arr[index] = child2
			current = child2
		else:
			return
	var last := String(parts[parts.size() - 1])
	if current is Dictionary:
		(current as Dictionary)[last] = value
	elif current is Array:
		var arr2: Array = current
		if not last.is_valid_int():
			return
		var index2 := int(last)
		if index2 < 0:
			return
		while arr2.size() <= index2:
			arr2.append(null)
		arr2[index2] = value
