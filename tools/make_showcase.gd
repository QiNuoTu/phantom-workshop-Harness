extends SceneTree
## 生成两个「实例工程」：
##   · examples/showcase.fxgraph           —— 主链 + 每类代表节点，日常打开就能看、跑得动；
##   · examples/showcase_all_nodes.fxgraph —— 全节点巡展（一个类型不落），给核验用。
##
## 主链是一条真能看的效果链：渐变背景 → 光斑（关键帧模糊）→ 子图 → 文字 → 光晕 → 染色
## → 着色器条纹，最后在「最终输出」里按图层叠加；时间轴 2 秒循环，参数上带关键帧。
##
## 巡展区把节点按分类摆开，能出图的接上源图与「输出预览」，打开就能看到效果。
## 全量那份每帧要跑几十个逐像素算子，慢是正常的 —— 它给核验用，不是给人盯着看的。
##
## 运行：godot --headless --path . --script res://tools/make_showcase.gd

const OUT_MAIN := "res://examples/showcase.fxgraph"
const OUT_ALL := "res://examples/showcase_all_nodes.fxgraph"
const OUT_PROJ := "res://examples/showcase.fxproj"
const SUBGRAPH := "res://examples/nested_child.fxgraph"

## 这几类只摆不接预览：要么缺外部素材，要么单帧就要几百毫秒，每帧都跑没意义。
## 能力覆盖不减（节点照样在图里），只是不参与每帧求值。
const TOUR_LIGHT_CATEGORIES: Array[String] = ["特效/生成", "图像/来源", "导出与保存"]

## 主链里已经用掉的类型，巡展区不再重复摆。
var _used: Dictionary = {}
var _sources: Array[String] = []


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()

	var main := _new_doc("幻像工坊 · 全能力演示")
	_build_main_chain(main)
	_build_showcase_row(main)
	_save(main, OUT_MAIN)
	var packed: Dictionary = FxProjectArchive.save_zip(main, OUT_PROJ, {})
	print("工程包 %s：%s" % [OUT_PROJ, str(packed.get("ok", false))])
	_report("主链", main, false)

	_used.clear()
	var all := _new_doc("幻像工坊 · 全节点巡展")
	_build_main_chain(all)
	_build_full_tour(all)
	_save(all, OUT_ALL)
	_report("全节点", all, true)

	FxPluginHost.shutdown()
	quit(0)


func _new_doc(title: String) -> Dictionary:
	var doc := FxGraphDoc.create(title)
	FxGraphDoc.set_canvas(doc, 200, 112)
	FxGraphDoc.set_timeline(doc, 30, 2.0, true)
	return doc


func _save(doc: Dictionary, path: String) -> void:
	var err := FxGraphDoc.save(doc, path)
	print("写入 %s：%s" % [path, error_string(err)])


func _report(label: String, doc: Dictionary, expect_full: bool) -> void:
	var runner := FxGraphRunner.new()
	# 第一帧含字体/子图/着色器视口的首次加载开销，第二帧才是稳态耗时。
	var frame: Dictionary = runner.run(doc, 0.0)
	runner.invalidate_cache()
	frame = runner.run(doc, 0.5)
	var image: Variant = frame.get("image")
	var stats: Dictionary = frame.get("stats", {})
	var types := {}
	for item in doc.get("nodes", []):
		types[String((item as Dictionary).get("type", ""))] = true
	print("[%s] 节点 %d · 类型 %d/%d · 边 %d · 输出 %s · 求值 %.0f ms" % [
		label, (doc.get("nodes", []) as Array).size(), types.size(), FxCatalog.all().size(),
		(doc.get("edges", []) as Array).size(),
		"null" if image == null else "%d×%d" % [(image as Image).get_width(), (image as Image).get_height()],
		float(stats.get("ms", 0.0)),
	])
	var missing: Array[String] = []
	for def in FxCatalog.all():
		if not types.has(String(def.id)):
			missing.append(String(def.id))
	if expect_full and not missing.is_empty():
		print("  未覆盖：", missing)


# ================= 主链 =================

func _add(doc: Dictionary, type: String, id: String, pos: Vector2, params: Dictionary = {}) -> String:
	var made := FxGraphDoc.add_node(doc, type, id, pos, params)
	_used[type] = true
	return String(made.get("id", id))


func _link(doc: Dictionary, from: String, from_port: String, to: String, to_port: String) -> bool:
	return FxGraphDoc.connect_ports(doc, from, from_port, to, to_port) == FxGraphDoc.LINK_OK


func _build_main_chain(doc: Dictionary) -> void:
	# 背景：径向渐变，scale 打关键帧做「呼吸」→ 一打开就能看出在动。
	# 注意 angle 只对线性模式起作用，径向要用 scale/center 才有动画。
	_add(doc, "image.gradient", "bg", Vector2(0, 0), {
		"mode": "radial", "color_a": "#101a3a", "color_b": "#4a2a6a",
		"scale": {"track": [[0.0, 1.15], [1.0, 1.85], [2.0, 1.15]], "interp": "ease"},
		"softness": 0.35,
	})
	# 光斑：圆形 + 呼吸式模糊，演示关键帧。
	_add(doc, "image.shape", "dot", Vector2(0, 200), {
		"shape": "circle", "color": "#ffd479", "background": "#00000000",
		"size": 0.44, "feather": 0.22, "center": [0.5, 0.5],
	})
	_add(doc, "image.blur", "dot_blur", Vector2(240, 200), {
		"radius": {"track": [[0.0, 2.0], [0.6, 12.0], [1.4, 3.0], [2.0, 2.0]], "interp": "ease"},
	})
	# 子图：复用 examples/nested_child.fxgraph（另一个示例工程当节点用）。
	_add(doc, "graph.subgraph", "sub", Vector2(0, 400), {
		"path": SUBGRAPH, "fit": "contain", "time_scale": 1.5,
	})
	# 文字与光晕：文本节点默认字体就指向 core.text 自带的字体文件。
	_add(doc, "image.text", "title", Vector2(0, 600), {
		"text": "幻像工坊", "size": 30, "color": "#ffffff", "align": "center", "offset": [0, 0],
	})
	_add(doc, "image.glow", "title_glow", Vector2(260, 600), {
		"radius": {"track": [[0.0, 4.0], [1.0, 10.0], [2.0, 4.0]], "interp": "ease"},
		"amount": 0.55,
	})
	_add(doc, "image.tint", "title_tint", Vector2(520, 600), {
		"color": "#9fd0ff", "amount": 0.55, "preserve_luma": true,
	})
	# 着色器：内联代码，UV + 时间做流动斜条纹。GPU 节点 → 渲染服务自动回主线程。
	_add(doc, "shader.image", "shader", Vector2(520, 400), {
		"code": "shader_type canvas_item;\nuniform float u_time = 0.0;\nvoid fragment() {\n\tvec2 uv = UV;\n\tfloat band = sin((uv.x + uv.y) * 18.0 + u_time * 3.0);\n\tCOLOR = vec4(mix(vec3(0.15, 0.45, 1.0), vec3(1.0, 0.75, 0.3), band * 0.5 + 0.5), 0.55);\n}\n",
		"uniforms": "u_time = 0.0", "enabled": true,
	})
	# 混合与合成：背景 ← 光斑，再按图层叠子图、文字光晕、着色器条纹。
	_add(doc, "image.mix", "bg_dot", Vector2(500, 200), {"mode": "add", "amount": 0.85})
	# 图层从底到顶：子图 → 着色器条纹 → 文字光晕（文字必须在最上层，不然会被盖住）。
	_add(doc, "output.final", "out", Vector2(1080, 200), {
		"layers": [
			{"name": "子图", "blend": "add", "opacity": 0.38, "offset": [0, 0], "visible": true},
			{"name": "着色器条纹", "blend": "screen", "opacity": 0.30, "offset": [0, 0], "visible": true},
			{"name": "文字光晕", "blend": "add", "opacity": 1.0,
				"offset": {"track": [[0.0, [0, 5]], [1.0, [0, -5]], [2.0, [0, 5]]], "interp": "ease"},
				"visible": true},
		],
		"background_color": "#0a0d18",
	})
	_link(doc, "dot", "image", "dot_blur", "image")
	_link(doc, "title", "image", "title_glow", "image")
	_link(doc, "title_glow", "image", "title_tint", "image")
	_link(doc, "bg", "image", "bg_dot", "a")
	_link(doc, "dot_blur", "image", "bg_dot", "b")
	_link(doc, "sub", "image", "shader", "image")
	# 背景图 + 三个图层（图层端口 id 是动态的 layer_<序号>）。
	_link(doc, "bg_dot", "image", "out", "background")
	_link(doc, "sub", "image", "out", "layer_0")
	_link(doc, "shader", "image", "out", "layer_1")
	_link(doc, "title_tint", "image", "out", "layer_2")
	doc["output"] = "out"


# ================= 巡展区 =================

## 给巡展节点准备几张源图，轮着用，避免所有样张都长得一样。
func _ensure_sources(doc: Dictionary) -> void:
	if not _sources.is_empty():
		return
	var presets := [
		["image.checker", "tour_src_checker",
			{"cell": 12, "color_a": "#2b5fa8", "color_b": "#e8b34a"}],
		["image.shape", "tour_src_shape",
			{"shape": "circle", "color": "#ffd479", "size": 0.6, "feather": 0.1}],
		["image.noise", "tour_src_noise", {"seed": 7, "cell": 3, "density": 0.6}],
	]
	var row := 0
	for preset in presets:
		var type_id := String(preset[0])
		if FxCatalog.def(type_id) == null:
			continue
		FxGraphDoc.add_node(doc, type_id, String(preset[1]), Vector2(-520, row), preset[2])
		_used[type_id] = true
		_sources.append(String(preset[1]))
		row += 160


## 摆一个节点：图像输入接源图；with_preview = true 时再接一个「输出预览」，让它参与求值。
func _place_tour_node(doc: Dictionary, def: FxNodeDef, pos: Vector2,
		with_preview: bool, source_cursor: int) -> void:
	var type_id := String(def.id)
	var made := FxGraphDoc.add_node(doc, type_id, "tour_" + type_id.replace(".", "_"),
		pos, def.default_params())
	var node_id := String(made.get("id", ""))
	_used[type_id] = true
	if node_id.is_empty():
		return
	var source_index := 0
	for port in def.inputs:
		if not FxPortType.can_connect(FxPortType.IMAGE, StringName(String(port.get("type", "any")))):
			continue
		if _sources.is_empty():
			break
		var src: String = _sources[(source_cursor + source_index) % _sources.size()]
		FxGraphDoc.connect_ports(doc, src, "image", node_id, String(port.get("id", "")))
		source_index += 1
	if not with_preview or def.is_output:
		return
	var image_out := ""
	for port in def.outputs:
		if FxPortType.can_connect(FxPortType.IMAGE, StringName(String(port.get("type", "any")))):
			image_out = String(port.get("id", ""))
			break
	if image_out.is_empty():
		return
	var preview_id := "tour_prev_" + type_id.replace(".", "_")
	var preview := FxGraphDoc.add_node(doc, "output.preview", preview_id,
		pos + Vector2(280, 0), {"note": type_id})
	if String(preview.get("id", "")).is_empty():
		return
	FxGraphDoc.connect_ports(doc, node_id, image_out, preview_id, "image")
	_used["output.preview"] = true


## 主链那份：只挑几类「最能说明引擎能力」的代表节点，控制住每帧开销。
## 逐像素算子都在 GDScript 里跑，摆满 75 个类型就不是能看的东西了（那是 all_nodes 那份）。
const SAMPLE_CATEGORIES: Array[String] = [
	"图像/处理", "图像/调色", "图像/扭曲", "图像/合成",
]


func _build_showcase_row(doc: Dictionary) -> void:
	_ensure_sources(doc)
	var picked := {}
	var index := 0
	for def in FxCatalog.all():
		var type_id := String(def.id)
		if _used.has(type_id) or picked.has(def.category):
			continue
		if not SAMPLE_CATEGORIES.has(def.category):
			continue
		picked[def.category] = true
		_place_tour_node(doc, def, _tour_pos(index), true, index)
		index += 1


## 全量那份：一个类型不落。缺素材 / 太重的那几类只摆不接。
func _build_full_tour(doc: Dictionary) -> void:
	_ensure_sources(doc)
	var index := 0
	for def in FxCatalog.all():
		if _used.has(String(def.id)):
			continue
		var light := TOUR_LIGHT_CATEGORIES.has(def.category)
		_place_tour_node(doc, def, _tour_pos(index), not light, index)
		index += 1


func _tour_pos(index: int) -> Vector2:
	return Vector2(1400.0 + float(index / 12) * 320.0, float(index % 12) * 220.0)
