class_name FxNodePreview
extends RefCounted
## 单节点样张：给「添加节点」面板生成「这个节点长什么样」的真实渲染图。
##
## 做法很土但很实在：临时拼一张三节点小图 ——
##   棋盘源（image.checker）→ 目标节点 → 当作输出
## 用渲染后端跑一帧，把目标节点的输出图取出来。算不出来（没有图像输出、
## 缺必需素材、纯数值节点）就返回 null，由面板退到图标纹理、再退到分类色块。
##
## 为什么放渲染插件而不是面板插件：只有这里认识执行器与算子表，
## 面板按「有 preview_node 方法就调、没有就算了」的软契约取用，不产生编译期耦合。

## 样张源图：棋盘格最能暴露模糊 / 扭曲 / 像素化这类几何效果。
const SOURCE_TYPE := "image.checker"
## 静帧样张的时间点：稍偏一点，避免正好落在动画的起始状态。
const STATIC_T := 0.35

static var _runner: FxGraphRunner = null
## 缓存键 "type|w|h"：静帧样张算一次就够，节点增删后由 clear_cache() 清掉。
static var _cache: Dictionary = {}


static func clear_cache() -> void:
	_cache.clear()


static func _ensure_runner() -> FxGraphRunner:
	if _runner == null:
		_runner = FxGraphRunner.new()
	# 样张只要像素：不抓节点预览，避免污染执行器的预览表。
	_runner.quality = 0
	_runner.capture_previews = false
	_runner.operator_quality = 1.0
	return _runner


## 节点有没有能进画面的输出（没有就别浪费一次渲染）。
static func can_render(node_type: String) -> bool:
	var def := FxCatalog.def(node_type)
	if def == null:
		return false
	for port in def.outputs:
		if FxPortType.can_connect(FxPortType.IMAGE, port.get("type", "")):
			return true
		if FxPortType.can_connect(FxPortType.IMAGE_OBJECT, port.get("type", "")):
			return true
	return def.is_output


## 能吃图像的所有输入端口 id（遮罩/混合这类双输入节点要全部接上，样张才不是空白）。
static func _image_inputs_of(def: FxNodeDef) -> Array[String]:
	var out: Array[String] = []
	for port in def.inputs:
		if FxPortType.can_connect(FxPortType.IMAGE, port.get("type", "")):
			out.append(String(port.get("id", "")))
	return out


## 样张源图：棋盘 + 亮圆盘的叠合。
## 棋盘暴露几何变形（模糊/扭曲/像素化），亮圆盘暴露亮度、色相与光晕，
## 圆盘的硬边还能看出描边、遮罩、色键有没有生效。
static func _source_params() -> Dictionary:
	return {"cell": 12, "color_a": "#2b5fa8", "color_b": "#e8b34a", "offset": [0, 0]}


## 在 doc 里搭一条 3 节点的迷你源链（棋盘 + 圆盘 → 混合），返回出口节点 id。
## 比单张棋盘信息量大得多，而且只用引擎已有的节点与算子。
static func _add_source(doc: Dictionary) -> String:
	if FxCatalog.def("image.checker") == null or FxCatalog.def("image.shape") == null \
			or FxCatalog.def("image.mix") == null:
		return ""
	FxGraphDoc.add_node(doc, "image.checker", "src_chk", Vector2(-520, 0), _source_params())
	FxGraphDoc.add_node(doc, "image.shape", "src_dot", Vector2(-520, 120),
		{"shape": "circle", "color": "#fff1c9", "background": "#00000000",
			"size": 0.52, "feather": 0.06, "center": [0.5, 0.5]})
	FxGraphDoc.add_node(doc, "image.mix", "src", Vector2(-260, 0),
		{"mode": "normal", "amount": 1.0})
	FxGraphDoc.connect_ports(doc, "src_chk", "image", "src", "a")
	FxGraphDoc.connect_ports(doc, "src_dot", "image", "src", "b")
	return "src"


## 生成样张。t < 0 时用 STATIC_T；同一 (type, 尺寸, 时间) 会走缓存。
## use_cache = false 用于「动图试算」：面板要按时间连续出帧，不能把缓存撑爆。
static func render(node_type: String, size: Vector2i, t: float = -1.0,
		use_cache: bool = true) -> Image:
	var def := FxCatalog.def(node_type)
	if def == null or not can_render(node_type):
		return null
	var width := clampi(size.x, 8, 512)
	var height := clampi(size.y, 8, 512)
	var when := STATIC_T if t < 0.0 else t
	var key := "%s|%d|%d|%s" % [node_type, width, height, str(snappedf(when, 0.05))]
	if use_cache and _cache.has(key):
		return _cache[key] as Image
	var runner := _ensure_runner()
	# 每张样张都是一张独立的小图：先清缓存，免得上一次的节点结果串进来。
	runner.invalidate_cache()
	var doc := build_doc(node_type, Vector2i(width, height))
	if doc.is_empty():
		return null
	# 直接用执行器求一帧，**不走渲染后端**：后端实例可能正被后台线程使用，
	# 为了几张缩略图和它抢状态不划算。样张只在主线程算，永远是 CPU 那套语义。
	var result := runner.run(doc, when)
	var image: Variant = result.get("image")
	if not image is Image:
		return null
	var made := image as Image
	if made.get_width() != width or made.get_height() != height:
		made = made.duplicate()
		made.resize(width, height, Image.INTERPOLATE_BILINEAR)
	# 全透明的样张等于没效果（缺素材、缺字体的节点常见），交给上层回退。
	if not _has_ink(made):
		return null
	if use_cache:
		_cache[key] = made
	return made


## 拼一张「源 → 目标」的小图。目标节点自己就是源类型时不接上游，直接跑。
static func build_doc(node_type: String, size: Vector2i) -> Dictionary:
	var def := FxCatalog.def(node_type)
	if def == null:
		return {}
	var doc := FxGraphDoc.create("样张")
	FxGraphDoc.set_canvas(doc, size.x, size.y)
	var params := def.default_params()
	FxGraphDoc.add_node(doc, node_type, "t", Vector2.ZERO, params)
	# 源图接到**每一个**图像输入：遮罩/混合这类双输入节点的样张才不是空白。
	var targets := _image_inputs_of(def)
	if not targets.is_empty():
		var source := _add_source(doc)
		if not source.is_empty():
			for port_id in targets:
				FxGraphDoc.connect_ports(doc, source, "image", "t", port_id)
	doc["output"] = "t"
	return doc


static func _has_ink(image: Image) -> bool:
	var step := maxi(1, image.get_width() / 12)
	var y := 0
	while y < image.get_height():
		var x := 0
		while x < image.get_width():
			if image.get_pixel(x, y).a > 0.02:
				return true
			x += step
		y += step
	return false
