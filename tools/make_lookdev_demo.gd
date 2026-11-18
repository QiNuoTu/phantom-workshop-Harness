extends SceneTree
## 生成「调色抠像」验收工程 —— 把 28 个原生算子**全部**跑起来的实机样本。
##
##   examples/demo/调色抠像.fxproj   工程包（双击/打开即用）
##   examples/demo/调色抠像.fxgraph  同一张图的纯文本形态
##
## 为什么另开一份而不是往「示范工程」里塞：那份工程是性能与回归基线
## （103 节点 / 69 ms 的读数都对着它），往里加节点会把基线变成"上一次的事"。
##
## 工程分两块：
##   ① **主链** —— 绿幕 → 抠像 → 蒙版清理 → 设置透明度 → 换背景 → 分离色调 → 色阶 → 颗粒 → 输出
##      这条链决定"最终画面长什么样"，也是每次打开工程第一眼看到的东西；
##   ② **验收墙** —— 其余算子各自接一个预览：打开就能看到每个节点的真实效果，
##      同时保证它们在 `diag.project` 里**真的被求值**（不是躺在棋盘上的死节点）。
##
## 生成脚本同时是"新功能要进示例工程"的执行者：加算子时改这两张表，别手搓 JSON。
##
## 运行：godot --headless --path . --script res://tools/make_lookdev_demo.gd

const DIR := "res://examples/demo"
const GRAPH_PATH := DIR + "/调色抠像.fxgraph"
const PROJ_PATH := DIR + "/调色抠像.fxproj"

const CANVAS := Vector2i(192, 108)
const FPS := 30
const DURATION := 2.0

## 主链：id → [id, 类型, 位置, 参数]
const CHAIN := [
	["plate_bg", "image.solid", Vector2(0, 0), {"color": "#1ecf58"}],
	["subj_fill", "image.solid", Vector2(0, 140), {"color": "#e6b48c"}],
	# 人物用**硬边**：羽化留给后面的「蒙版清理」。合成前就羽化的话，
	# 绿幕与肤色会在边缘混出一条半绿半肤的像素，色度键只能给出半透明，
	# 画面就出现一圈暗边 —— 那不是抠像坏了，是素材没有可抠的边界。
	["subj_shape", "mask.ellipse", Vector2(0, 280), {
		"center": [96, 58], "radius": [30, 44], "feather": 0.0,
	}],
	["subj_cut", "image.mask", Vector2(240, 140), {"channel": "alpha"}],
	["plate", "image.blend2", Vector2(480, 40), {"mode": "normal"}],
	["key", "key.chroma_pro", Vector2(700, 40), {
		"screen": "#1ecf58", "black": 0.18, "white": 0.6, "soften": 0.12, "despill": 0.7,
	}],
	["clean", "key.matte_clean", Vector2(940, 40), {
		"shrink": 1, "feather": 2, "denoise": 0.1, "view": "matte",
	}],
	["cutout", "channel.set_alpha", Vector2(1180, 40), {"channel": "alpha", "mode": "multiply"}],
	# 竖向渐变（上暗下亮）：和"人物居中"不打架。径向渐变在这里会翻车 ——
	# 焦心是暗的，人物遮住中心后四周就剩一圈暗环，看起来像抠像留下的黑边。
	["bg_raw", "image.gradient", Vector2(700, 300), {
		"mode": "linear", "color_a": "#0a1230", "color_b": "#5f9fd0",
		"angle": 90.0, "softness": 0.2,
	}],
	["bg_look", "tone.palette", Vector2(940, 300), {
		"steps": 3, "c1": "#0a1024", "c2": "#2f5f96", "c3": "#8fc4e8", "smooth": 0.4,
	}],
	["comp", "image.blend2", Vector2(1420, 40), {"mode": "normal"}],
	["grade", "tone.split_tone", Vector2(1640, 40), {
		"shadow": "#22306a", "highlight": "#ffd9a0", "balance": 0.55, "amount": 0.75,
	}],
	["levels", "tone.levels_pro", Vector2(1860, 40), {
		"in_black": 0.03, "in_white": 0.97, "gamma": 1.05,
	}],
	["grain", "style.grain", Vector2(2080, 40), {"amount": 0.07, "size": 1, "seed": 3}],
	["out", "output.final", Vector2(2320, 40), {
		"layers": [{"name": "合成", "blend": "normal", "opacity": 1.0,
			"offset": [0, 0], "visible": true}],
	}],
]

const CHAIN_LINKS := [
	["plate_bg", "image", "plate", "a"],
	["subj_fill", "image", "subj_cut", "image"],
	["subj_shape", "image", "subj_cut", "mask"],
	["subj_cut", "image", "plate", "b"],
	["plate", "image", "key", "image"],
	["key", "image", "clean", "image"],
	["plate", "image", "cutout", "image"],
	["clean", "image", "cutout", "source"],
	["bg_raw", "image", "bg_look", "image"],
	["bg_look", "image", "comp", "a"],
	["cutout", "image", "comp", "b"],
	["comp", "image", "grade", "image"],
	["grade", "image", "levels", "image"],
	["levels", "image", "grain", "image"],
	["grain", "image", "out", "layer_0"],
]

## 验收墙：[id, 类型, 源节点 id（""=不需要输入）, 参数]。
## 一律接一个 `output.preview`：既看得见，也真的被求值。
const WALL := [
	["key_luma", "key.luma", "plate", {"black": 0.55, "white": 0.75, "view": "matte"}],
	["key_diff", "key.diff", "plate", {"tolerance": 0.06, "softness": 0.1, "despill": 0.0}],
	["key_range", "key.color_range", "plate", {"target": "#1ecf58", "hue_range": 0.06}],
	["key_despill", "key.despill", "key", {"strength": 1.0, "mode": "green"}],
	["ch_mixer", "channel.mixer", "plate", {"mono": true}],
	["ch_shift", "channel.shift", "comp", {"offset": [3, 1], "amount": 1.0}],
	["ch_swap", "channel.swap", "plate", {"r_from": "green", "g_from": "red"}],
	["m_rect", "mask.rect", "", {
		"position": [40, 18], "size": [112, 72], "roundness": 0.35, "feather": 6.0,
	}],
	["m_vig", "mask.vignette", "", {"radius": 0.8, "softness": 0.5}],
	["m_luma", "mask.from_luma", "clean", {"black": 0.1, "white": 0.9}],
	["m_feather", "mask.feather", "clean", {"radius": 4, "expand": 1}],
	["t_poster", "tone.posterize_pro", "comp", {"levels": 4, "mode": "luma", "smooth": 0.2}],
	["t_temp", "tone.temperature", "grade", {"temperature": 45.0, "vibrance": 0.3}],
	# 曲线：S 形提对比 + 轻微提亮中间调。点阵就是控件里拖出来的形状。
	["t_curve", "tone.curves", "comp", {
		"points": [[0.0, 0.0], [0.25, 0.18], [0.6, 0.72], [1.0, 1.0]],
	}],
	["s_emboss", "style.emboss", "plate", {"angle": 45.0, "strength": 1.2}],
	["s_half", "style.halftone", "bg_look", {"cell": 4, "angle": 45.0, "contrast": 1.6}],
	["s_edges", "style.find_edges", "plate", {"mode": "invert", "strength": 1.2}],
	["s_toon", "style.cartoon", "plate", {"levels": 4, "edge_strength": 0.8}],
	# 主链上已经用过的 3 个通道算子也各来一面：验收墙上"每个算子都有画面"。
	["ch_extract", "channel.extract", "key", {"channel": "alpha"}],
	["ch_combine", "channel.combine", "clean", {"mode": "luma"}],
	["m_bool", "mask.boolean", "clean", {"mode": "intersect"}],
]

## 验收墙上需要第二条入线的节点：{id: [端口, 源节点]}
const WALL_EXTRA_INPUT := {
	"key_diff": ["background", "plate_bg"],
	"ch_combine": ["g", "clean"],
	"m_bool": ["b", "m_rect"],
}


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	var doc := _build()
	var issues := FxGraphDoc.validate(doc)
	print("结构校验：%s" % ("通过" if issues.is_empty() else str(issues)))
	print("写入 %s：%s" % [GRAPH_PATH, error_string(FxGraphDoc.save(doc, GRAPH_PATH))])
	var packed := FxProjectArchive.save_zip(doc, PROJ_PATH, {"include_assets": false})
	print("打包 %s：%s" % [PROJ_PATH, str(packed.get("ok", false))])
	_report(doc)
	FxPluginHost.shutdown()
	quit(0)


func _build() -> Dictionary:
	var doc := FxGraphDoc.create("调色抠像 · 28 个原生算子验收工程")
	FxGraphDoc.set_canvas(doc, CANVAS.x, CANVAS.y)
	FxGraphDoc.set_timeline(doc, FPS, DURATION, true)
	doc["meta"]["author"] = "幻像工坊 · 随包示例"
	doc["meta"]["note"] = "主链：绿幕 → 抠像 → 蒙版清理 → 换背景 → 分离色调 → 色阶 → 颗粒。" \
		+ "验收墙：每个算子各接一个预览，打开即可逐个看效果（也保证它们被真实求值）。"

	for item in CHAIN:
		FxGraphDoc.add_node(doc, String(item[1]), String(item[0]), item[2], item[3])

	# 验收墙：两列排布，每个节点配一个预览。
	var column := 0
	var row := 0
	for item in WALL:
		var node_id := String(item[0])
		var type_id := String(item[1])
		var source_id := String(item[2])
		var position := Vector2(0, 520 + row * 220 + column * 1000)
		FxGraphDoc.add_node(doc, type_id, node_id, position, item[3])
		var preview_id := "prev_" + node_id
		FxGraphDoc.add_node(doc, "output.preview", preview_id, position + Vector2(240, 0), {
			"note": type_id,
		})
		if not source_id.is_empty():
			_link(doc, source_id, "image", node_id, _first_input(type_id))
		_link(doc, node_id, "image", preview_id, "image")
		column += 1
		if column >= 2:
			column = 0
			row += 1

	for node_id in WALL_EXTRA_INPUT.keys():
		var spec: Array = WALL_EXTRA_INPUT[node_id]
		_link(doc, String(spec[1]), "image", String(node_id), String(spec[0]))

	for link in CHAIN_LINKS:
		_link(doc, String(link[0]), String(link[1]), String(link[2]), String(link[3]))
	doc["output"] = "out"
	return doc


func _first_input(type_id: String) -> String:
	var def: FxNodeDef = FxCatalog.def(type_id)
	if def == null or def.inputs.is_empty():
		return "image"
	return String((def.inputs[0] as Dictionary).get("id", "image"))


func _link(doc: Dictionary, from_id: String, from_port: String, to_id: String,
		to_port: String) -> void:
	var err := FxGraphDoc.connect_ports(doc, from_id, from_port, to_id, to_port)
	if err != FxGraphDoc.LINK_OK:
		push_error("连线失败：%s.%s → %s.%s（%d）" % [from_id, from_port, to_id, to_port, err])


func _report(doc: Dictionary) -> void:
	var types := {}
	for raw in doc.get("nodes", []):
		types[String((raw as Dictionary).get("type", ""))] = true
	var runner := FxGraphRunner.new()
	var frame: Dictionary = runner.run(doc, 0.0)
	var image: Variant = frame.get("image")
	var totals: Dictionary = runner.ctx.timing_totals
	var slowest := ""
	var slowest_ms := 0.0
	var sum := 0.0
	for key in totals.keys():
		sum += float(totals[key])
		if float(totals[key]) > slowest_ms:
			slowest_ms = float(totals[key])
			slowest = String(key)
	print("[调色抠像] 节点 %d · 类型 %d · 边 %d · 输出 %s · 告警 %s" % [
		(doc.get("nodes", []) as Array).size(), types.size(),
		(doc.get("edges", []) as Array).size(),
		"null" if image == null else "%d×%d" % [(image as Image).get_width(),
			(image as Image).get_height()],
		str(frame.get("warnings", [])),
	])
	print("逐节点合计 %.1f ms · 最慢一格 %s %.1f ms" % [sum, slowest, slowest_ms])
	if image is Image:
		(image as Image).save_png("user://graph_test/lookdev_frame0.png")
		print("样张：user://graph_test/lookdev_frame0.png")
