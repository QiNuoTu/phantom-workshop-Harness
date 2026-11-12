class_name FxPortProviders
extends RefCounted
## 动态端口提供者：端口数量由参数决定的节点（输出图层、序列分支）走这里。
##
## 关键点：执行器、校验器、编辑器都调用同一个 FxCatalog.ports()，
## 因此“界面上看到的端口”和“执行时认的端口”不可能对不上。
## 新增动态节点只需在 def.port_provider 写一个 id，并在这里加一个分支。

static func build(id: StringName, def: FxNodeDef, params: Dictionary,
		inputs: Array[Dictionary], outputs: Array[Dictionary]) -> Dictionary:
	match id:
		&"output_layers":
			return _output_layers(def, params, inputs, outputs)
		&"sequence":
			return _sequence(def, params, inputs, outputs)
		&"subgraph":
			return _subgraph(params, inputs, outputs)
		&"subgraph_input":
			return _boundary_in(params, inputs, outputs)
		&"subgraph_output":
			return _boundary_out(params, inputs, outputs)
	return {"inputs": inputs, "outputs": outputs}


## 子图节点：把子工程里声明的输入/输出节点，长成外层节点上的端口。
## 子工程没声明就一个都不加，与旧工程完全兼容。
static func _subgraph(params: Dictionary, inputs: Array[Dictionary],
		outputs: Array[Dictionary]) -> Dictionary:
	var path := String(params.get("path", "")).strip_edges()
	if path.is_empty():
		return {"inputs": inputs, "outputs": outputs}
	var doc := FxOpsSubgraph.doc_of(path)
	if doc.is_empty():
		return {"inputs": inputs, "outputs": outputs}
	var declared := FxOpsSubgraph.declared_ports(doc)
	var ins := _copy(inputs)
	var outs := _copy(outputs)
	for item in declared.get("inputs", []):
		var spec: Dictionary = item
		ins.append({
			"id": spec.get("id", ""), "label": spec.get("label", ""),
			"type": spec.get("type", FxPortType.IMAGE),
			"required": false, "multi": false, "bindable": false, "param": false,
		})
	for item in declared.get("outputs", []):
		var spec2: Dictionary = item
		outs.append({
			"id": spec2.get("id", ""), "label": spec2.get("label", ""),
			"type": spec2.get("type", FxPortType.IMAGE),
			"required": false, "multi": true, "bindable": false, "param": false,
		})
	return {"inputs": ins, "outputs": outs}


## 子图输入节点自己只有一个出口，类型由 params.type 决定。
static func _boundary_in(params: Dictionary, inputs: Array[Dictionary],
		outputs: Array[Dictionary]) -> Dictionary:
	var outs := _copy(outputs)
	outs.append({
		"id": "value", "label": _boundary_label(params),
		"type": FxOpsSubgraph.port_type_of({"params": params}),
		"required": false, "multi": false, "bindable": false, "param": false,
	})
	return {"inputs": inputs, "outputs": outs}


## 子图输出节点自己只有一个入口，类型同样由 params.type 决定。
static func _boundary_out(params: Dictionary, inputs: Array[Dictionary],
		outputs: Array[Dictionary]) -> Dictionary:
	var ins := _copy(inputs)
	ins.append({
		"id": "value", "label": _boundary_label(params),
		"type": FxOpsSubgraph.port_type_of({"params": params}),
		"required": false, "multi": false, "bindable": false, "param": false,
	})
	return {"inputs": ins, "outputs": outputs}


static func _boundary_label(params: Dictionary) -> String:
	var label := String(params.get("name", "")).strip_edges()
	return label if not label.is_empty() else "值"


static func _copy(specs: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item in specs:
		out.append(item.duplicate(true))
	return out


## 最终输出：背景 + 每个图层一个 image 输入。
## layers 数组顺序 = 从底到顶；端口 id 固定为 layer_0..layer_n，改名不影响连线。
static func _output_layers(_def: FxNodeDef, params: Dictionary,
		inputs: Array[Dictionary], outputs: Array[Dictionary]) -> Dictionary:
	var ins: Array[Dictionary] = []
	for p in inputs:
		ins.append(p.duplicate(true))
	var layers: Array = params.get("layers", [])
	for i in range(layers.size()):
		var layer: Dictionary = layers[i] if layers[i] is Dictionary else {}
		var layer_name := String(layer.get("name", "图层 %d" % (i + 1)))
		var layer_id := String(layer.get("id", str(i)))
		ins.append({
			"id": "layer_%s" % layer_id,
			"label": layer_name,
			"type": FxPortType.IMAGE,
			"required": false,
			"multi": false,
			"bindable": false,
			"param": false,
		})
	return {"inputs": ins, "outputs": outputs}


## 序列：steps 决定几个执行出口，保证顺序不受连线先后影响。
static func _sequence(_def: FxNodeDef, params: Dictionary,
		inputs: Array[Dictionary], outputs: Array[Dictionary]) -> Dictionary:
	var steps := clampi(FxPortType.as_int(params.get("steps", 2), 2), 1, 8)
	var outs: Array[Dictionary] = []
	for i in range(steps):
		outs.append({
			"id": "then_%d" % i,
			"label": "%d" % (i + 1),
			"type": FxPortType.EXEC,
			"required": false,
			"multi": true,
			"bindable": false,
			"param": false,
		})
	return {"inputs": inputs, "outputs": outs}
