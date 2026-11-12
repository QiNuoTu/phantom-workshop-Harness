class_name FxOpsSubgraph
extends RefCounted
## 子图节点：把**另一个图文档**当作一个节点来渲染。
##
## 这就是「工程嵌套」与 AE 那种预合成（pre-compose）的运行时形态：
##   · 子工程有自己的画布、时间轴、输出节点；
##   · 外层只看见一张图（外加时长 / 帧数 / 画布尺寸这些必要参数）；
##   · 子工程可以再嵌子工程，靠静态栈检测循环引用，不会把进程卡死。
##
## 文档按「路径 + 修改时间」缓存，播放时不会每帧读盘；改了子图文件下一次
## 求值就会自动读到新内容。
##
## **作用域约束**：文档缓存是「跨求值共享的只读事实」，用互斥量保护；
## 递归栈与内层执行器是「一次求值的组合状态」，放在 FxEvalContext 上。
## 早先两者都是静态单例，6 条预渲染线程并发求帧时互相覆盖执行器的
## doc/evaluating/索引，会误报「检测到循环依赖 s_out」。

## 路径 -> {stamp, doc}
static var _cache: Dictionary = {}
static var _doc_mutex := Mutex.new()
const MAX_CACHE := 8
## 同一次求值里每个子图最多回报这么多条警告，避免一帧刷几百行。
const MAX_WARNINGS := 6

## 子图边界节点：在子图内部声明「一个输入端口」/「一个输出端口」。
## 端口 id 用节点 id（改名不会断线），name 只是显示用的标签。
const INPUT_TYPE := "graph.input"
const OUTPUT_TYPE := "graph.output"

## 边界能传哪些类型：图像 + 四种标量/向量。够覆盖绝大多数参数驱动场景。
const BOUNDARY_TYPES: Array[String] = ["image", "number", "vec2", "color", "bool", "string"]


## 子图对外暴露的端口表。编辑器、校验器、执行器都读这一份，不会各说各话。
static func declared_ports(doc: Dictionary) -> Dictionary:
	var ins: Array[Dictionary] = []
	var outs: Array[Dictionary] = []
	for item in doc.get("nodes", []):
		var node: Dictionary = item
		var type := String(node.get("type", ""))
		if type != INPUT_TYPE and type != OUTPUT_TYPE:
			continue
		var spec := {
			"id": String(node.get("id", "")),
			"label": port_label_of(node),
			"type": port_type_of(node),
			"required": false,
			"multi": false,
			"bindable": false,
			"param": false,
		}
		if type == INPUT_TYPE:
			ins.append(spec)
		else:
			outs.append(spec)
	return {"inputs": ins, "outputs": outs}


static func port_type_of(node: Dictionary) -> StringName:
	var params: Dictionary = node.get("params", {})
	var raw := String(params.get("type", "image")).to_lower()
	match raw:
		"number", "int", "float":
			return FxPortType.NUMBER
		"vec2":
			return FxPortType.VEC2
		"color":
			return FxPortType.COLOR
		"bool":
			return FxPortType.BOOL
		"string":
			return FxPortType.STRING
		"image_object":
			return FxPortType.IMAGE_OBJECT
	return FxPortType.IMAGE


static func port_label_of(node: Dictionary) -> String:
	var params: Dictionary = node.get("params", {})
	var label := String(params.get("name", "")).strip_edges()
	return label if not label.is_empty() else String(node.get("id", ""))


## `graph.input`：把外层传进来的值原样吐出来。没接线时给该类型的零值。
static func read_input(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var key := String(node.get("id", ""))
	if ctx.subgraph_inputs.has(key):
		return {"value": ctx.subgraph_inputs[key]}
	var type := port_type_of(node)
	if type == FxPortType.IMAGE:
		return {"value": _blank(ctx.canvas)}
	return {"value": _zero_of(type)}


## `graph.output`：把值交给外层。求值器最后会补跑一次（evaluate_always），
## 所以它不需要接在子图的输出节点上游。
static func write_output(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var key := String(node.get("id", ""))
	var value: Variant = inputs.get("value")
	if value == null:
		value = _zero_of(port_type_of(node))
	ctx.subgraph_outputs[key] = value
	return {}


static func _zero_of(type: StringName) -> Variant:
	match type:
		FxPortType.NUMBER, FxPortType.INT:
			return 0.0
		FxPortType.VEC2:
			return Vector2.ZERO
		FxPortType.COLOR:
			return Color(1, 1, 1, 1)
		FxPortType.BOOL:
			return false
		FxPortType.STRING:
			return ""
	return null


static func render(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var raw := FxPortType.as_string(params.get("path", ""), "").strip_edges()
	if raw.is_empty():
		return _empty(ctx, {})
	var path := resolve_path(raw)
	if path.is_empty():
		ctx.warn("子图文件找不到：%s" % raw)
		return _empty(ctx, {})
	# 递归栈属于本次求值（ctx），不是全局：不同线程/不同帧互不干扰。
	var stack: Array[String] = ctx.subgraph_stack
	if stack.has(path):
		ctx.warn("子图循环引用：%s（本帧跳过）" % raw)
		return _empty(ctx, {})
	var doc := _doc_at(path)
	if doc.is_empty():
		ctx.warn("子图不是合法的图文档：%s" % raw)
		return _empty(ctx, {})

	var timeline := FxGraphDoc.timeline(doc)
	var duration := maxf(0.001, float(timeline.get("duration", 1.0)))
	var fps := maxf(1.0, float(timeline.get("fps", 30.0)))
	var scale := FxPortType.as_number(params.get("time_scale", 1.0), 1.0)
	var offset := FxPortType.as_number(params.get("time_offset", 0.0), 0.0)

	# 外层接在这个节点上的值，按子图声明的输入端口逐个转进去。
	var declared := declared_ports(doc)
	var forwarded: Dictionary = {}
	for item in declared.get("inputs", []):
		var port_id := String((item as Dictionary).get("id", ""))
		if inputs.has(port_id):
			forwarded[port_id] = inputs[port_id]

	# 每个「求值作用域 × 子图路径」独占一个执行器：同帧多次引用同一子图可复用
	# 静态缓存，跨线程/跨帧绝不共享。父链通过 inherited_subgraph_stack 传递，
	# A 嵌 B 嵌 A 时内层能看见完整路径。
	var sub: FxGraphRunner = ctx.subgraph_runners.get(path)
	if sub == null:
		sub = FxGraphRunner.new()
		ctx.subgraph_runners[path] = sub
	sub.capture_previews = false
	sub.quality = ctx.quality
	sub.operator_quality = ctx.operator_quality
	sub.options = ctx.options.duplicate(true)
	sub.boundary_inputs = forwarded
	stack.append(path)
	sub.inherited_subgraph_stack = []
	for entry in stack:
		sub.inherited_subgraph_stack.append(entry)
	var result := sub.run(doc, ctx.t * scale + offset)
	stack.pop_back()

	var warned := 0
	for item in result.get("warnings", []):
		if warned >= MAX_WARNINGS:
			ctx.warn("子图 %s：还有更多警告（已省略）" % raw.get_file())
			break
		ctx.warn("子图 %s：%s" % [raw.get_file(), String(item)])
		warned += 1

	var image: Image = result.get("image")
	var canvas := FxGraphDoc.canvas(doc)
	var out := {
		"image": _place(ctx, path, image, params),
		"duration": duration,
		"frames": maxf(1.0, round(duration * fps)),
		"canvas": Vector2(canvas),
	}
	# 子图里「输出节点」的值：没声明的就留空，下游读到 null 会照常处理。
	for item in declared.get("outputs", []):
		var port_id := String((item as Dictionary).get("id", ""))
		if sub.boundary_outputs.has(port_id):
			out[port_id] = sub.boundary_outputs[port_id]
	return out


## 子图有哪些节点类型 —— 供编辑器展开 / 打包时做检查，不参与渲染。
static func doc_of(path: String) -> Dictionary:
	var resolved := resolve_path(path)
	return _doc_at(resolved) if not resolved.is_empty() else {}


static func clear_cache() -> void:
	_doc_mutex.lock()
	_cache.clear()
	_doc_mutex.unlock()


## 诊断：当前缓存了多少份子图文档（作用域状态不再是全局，故为 0 项）。
static func cached_docs() -> int:
	_doc_mutex.lock()
	var n := _cache.size()
	_doc_mutex.unlock()
	return n


# ================= 内部 =================

## 把参数里的路径解析成真实可读路径（相对资源根 / res:// / user:// 都认）。
## 编辑器双击下钻也走这里，保证「能渲染的」和「能打开的」是同一条链。
static func resolve_path(path: String) -> String:
	var key := path.strip_edges()
	if key.is_empty():
		return ""
	if FileAccess.file_exists(key):
		return key
	return FxResourceRoot.resolve(key)


## 只读事实的缓存：跨线程共享，但读写都在同一把锁里，Dictionary 不会被并发改写。
static func _doc_at(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var stamp := FileAccess.get_modified_time(path)
	_doc_mutex.lock()
	if _cache.has(path):
		var hit: Dictionary = _cache[path]
		if int(hit.get("stamp", -1)) == stamp:
			var found: Dictionary = hit.get("doc") as Dictionary
			_doc_mutex.unlock()
			return found
	_doc_mutex.unlock()
	# 不用 FxGraphDoc.load_json：它读失败会回落到空文档，这里需要区分「坏了」和「空的」。
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var raw: Variant = JSON.parse_string(text)
	if not raw is Dictionary:
		return {}
	var doc := FxGraphDoc.normalize(raw)
	_doc_mutex.lock()
	_cache[path] = {"stamp": stamp, "doc": doc}
	while _cache.size() > MAX_CACHE:
		var first: String = String(_cache.keys()[0])
		_cache.erase(first)
	_doc_mutex.unlock()
	return doc


static func _empty(ctx: FxEvalContext, extra: Dictionary) -> Dictionary:
	var out := {
		"image": _blank(ctx.canvas),
		"duration": 0.0,
		"frames": 0.0,
		"canvas": Vector2.ZERO,
	}
	out.merge(extra, true)
	return out


static func _blank(size: Vector2i) -> Image:
	var image := Image.create_empty(maxi(1, size.x), maxi(1, size.y), false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return image


## 子图输出按 fit / scale / offset / alpha 落到外层画布上。
static func _place(ctx: FxEvalContext, _path: String, source: Image, params: Dictionary) -> Image:
	var canvas := _blank(ctx.canvas)
	if source == null:
		ctx.warn("子图没有输出图像（检查子工程的输出节点）")
		return canvas
	var layer: Image = source.duplicate()
	if layer.is_compressed():
		layer.decompress()
	layer.convert(Image.FORMAT_RGBA8)
	var fit := FxPortType.as_string(params.get("fit", "contain"), "contain")
	var scale := clampf(FxPortType.as_number(params.get("scale", 1.0), 1.0), 0.01, 32.0)
	var offset := FxPortType.as_vec2(params.get("offset", [0, 0]), Vector2.ZERO)
	var alpha := clampf(FxPortType.as_number(params.get("alpha", 1.0), 1.0), 0.0, 1.0)

	var src := Vector2(float(layer.get_width()), float(layer.get_height()))
	var target := src * scale
	match fit:
		"stretch":
			target = Vector2(float(canvas.get_width()), float(canvas.get_height())) * scale
		"contain":
			var k := minf(float(canvas.get_width()) / maxf(src.x, 1.0),
				float(canvas.get_height()) / maxf(src.y, 1.0))
			target = src * k * scale
		"cover":
			var k2 := maxf(float(canvas.get_width()) / maxf(src.x, 1.0),
				float(canvas.get_height()) / maxf(src.y, 1.0))
			target = src * k2 * scale
	var pixel := Vector2i(maxi(1, int(round(target.x))), maxi(1, int(round(target.y))))
	if pixel != layer.get_size():
		layer.resize(pixel.x, pixel.y, Image.INTERPOLATE_LANCZOS)
	if alpha < 0.999:
		_apply_alpha(layer, alpha)

	var center := Vector2(ctx.canvas) * 0.5 + offset
	var dst := Vector2i(int(round(center.x - float(pixel.x) * 0.5)),
		int(round(center.y - float(pixel.y) * 0.5)))
	# 目标裁剪：blend_rect 要求落点在图内。
	var x0 := maxi(0, -dst.x)
	var y0 := maxi(0, -dst.y)
	var x1 := mini(layer.get_width(), canvas.get_width() - dst.x)
	var y1 := mini(layer.get_height(), canvas.get_height() - dst.y)
	if x1 <= x0 or y1 <= y0:
		return canvas
	var use := layer.get_region(Rect2i(x0, y0, x1 - x0, y1 - y0))
	canvas.blend_rect(use, Rect2i(Vector2i.ZERO, use.get_size()), Vector2i(dst.x + x0, dst.y + y0))
	return canvas


static func _apply_alpha(image: Image, alpha: float) -> void:
	var data := image.get_data()
	for i in range(3, data.size(), 4):
		data[i] = int(round(float(data[i]) * alpha))
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data)
