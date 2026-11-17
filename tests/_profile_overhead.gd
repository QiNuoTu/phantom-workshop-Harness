extends SceneTree
## 框架开销画像：把「一帧里除算子以外的时间」拆开量。
##
## 为什么要单独量：op 合计 471ms，整帧 619ms，中间 148ms 没有归属。
## 这 148ms 如果花在「每帧重建端口表」「每帧对整份文档做递归哈希」这种地方，
## 那是纯浪费，比优化任何单个算子都划算。
##
## 运行：godot --headless --path . --script res://tests/_profile_overhead.gd

const PROJ := "res://examples/demo/示范工程.fxproj"
const REPEAT := 100


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	var loaded := FxProjectArchive.read_zip(PROJ)
	var doc: Dictionary = loaded.get("doc", {}) as Dictionary
	if doc.is_empty():
		print("读不到示范工程")
		quit(1)
		return
	var nodes: Array = doc.get("nodes", [])
	var edges: Array = doc.get("edges", [])
	print("== 框架开销画像 ==（%d 节点 / %d 边）" % [nodes.size(), edges.size()])

	# 1. 整份 nodes/edges 的递归哈希（_build_index 每帧做一次）
	var t := Time.get_ticks_usec()
	for i in range(REPEAT):
		var _k := int(hash(nodes)) * 31 + int(hash(edges))
	print("  hash(nodes)+hash(edges)      %7.3f ms / 次" % (_ms(t) / REPEAT))

	# 2. 端口表重建（_index_ports 每帧被 clear，于是每节点重建一次）
	t = Time.get_ticks_usec()
	for i in range(REPEAT):
		for item in nodes:
			var node_data: Dictionary = item
			var def := FxCatalog.def(node_data.get("type", ""))
			if def != null:
				var _ports := FxCatalog.ports(def, node_data.get("params", {}))
	print("  FxCatalog.ports × %d          %7.3f ms / 帧" % [nodes.size(), _ms(t) / REPEAT])

	# 3. 默认参数 + 轨道采样（_resolve_params 每节点每帧一次）
	t = Time.get_ticks_usec()
	for i in range(REPEAT):
		for item in nodes:
			var node_data: Dictionary = item
			var def := FxCatalog.def(node_data.get("type", ""))
			if def == null:
				continue
			var params := FxCatalog.default_params(def)
			var raw: Dictionary = node_data.get("params", {})
			for key in raw.keys():
				var value: Variant = raw[key]
				params[key] = value.duplicate(true) if value is Array or value is Dictionary else value
			var _resolved := FxTracks.resolve_layer(params, 0.5)
	print("  default_params + resolve × %d %7.3f ms / 帧" % [nodes.size(), _ms(t) / REPEAT])

	# 4. 预览捕获：duplicate + resize（每帧最多 55 次）
	var sample: Image = FxPixelKit.canvas(Vector2i(192, 108))
	sample.fill(Color(0.2, 0.4, 0.6, 0.8))
	t = Time.get_ticks_usec()
	for i in range(REPEAT):
		for k in range(55):
			var copy: Image = sample.duplicate()
			copy.resize(128, 72, Image.INTERPOLATE_NEAREST)
	print("  预览 capture × 55             %7.3f ms / 帧" % (_ms(t) / REPEAT))

	# 5. 静态缓存的整图签名（_signature_of 每个可缓存节点一次）
	t = Time.get_ticks_usec()
	for i in range(REPEAT):
		var _sig := 0
		for item in nodes:
			var node_data: Dictionary = item
			_sig = _sig * 31 + hash(String(node_data.get("type", "")))
			_sig = _sig * 31 + hash(node_data.get("params", {}))
	print("  逐节点签名 × %d               %7.3f ms / 帧" % [nodes.size(), _ms(t) / REPEAT])

	FxPluginHost.shutdown()
	quit(0)


func _ms(usec: int) -> float:
	return float(Time.get_ticks_usec() - usec) / 1000.0
