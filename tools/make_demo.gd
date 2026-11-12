extends SceneTree
## 生成「示范工程」—— 一份能把工作台能力全用上的可打开工程。
##
##   examples/demo/示范工程.fxproj            工程包（含素材；双击/打开即用）
##   examples/demo/示范工程.fxgraph      同一张图的纯文本形态
##   examples/demo/示范工程_子图.fxgraph 被 graph.subgraph 引用的子工程
##   examples/demo/assets/*.png               生成出来的外部素材（精灵表 + 光球贴图）
##
## 这张图按「看得懂的分区」摆，而不是把节点堆成山：
##
##   ① 素材区   —— 外部贴图 / 精灵表 / pixelfx 序列帧 / VfxEngine 配方 / 字体文本
##   ② 背景     —— 径向渐变 → 星野 → 噪声星云（模糊半径被数值连线驱动）
##   ③ 前景     —— 精灵表变形与调色、光球位移、标题描边/辉光/染色、子图 + 着色器条纹
##   ④ 输出     —— 5 个图层按不同混合模式叠加，标题图层的位移打了关键帧
##   ⑤ 驱动     —— 关键帧与「连线驱动参数」两种动画写法并存（含读像素驱动参数）
##   ⑥ 流程导出 —— 分支 / 循环 / 累积 / 5 个导出节点（run 默认 false，不写盘）
##   ⑦ 巡展     —— 剩余节点类型各摆一个，能出图的接预览，凑齐 75/75
##
## 运行：godot --headless --path . --script res://tools/make_demo.gd

const DIR := "res://examples/demo"
const DOC_PATH := DIR + "/示范工程.fxgraph"
const PROJ_PATH := DIR + "/示范工程.fxproj"
const SUB_PATH := DIR + "/示范工程_子图.fxgraph"
const SHEET_PATH := DIR + "/assets/spark_sheet.png"
const ORB_PATH := DIR + "/assets/orb_ring.png"

## 画布定在 192×108：逐像素算子都在 GDScript 里跑，这个尺寸下整条主链仍然跑得动。
const CANVAS := Vector2i(192, 108)
const CHILD_CANVAS := Vector2i(128, 72)
const FPS := 30
const DURATION := 2.0

const SHEET_COLS := 4
const SHEET_ROWS := 4
const SHEET_FRAME := 32

## 巡展区只给「便宜且一眼看得出差别」的节点挂预览：每个预览都意味着每帧多跑一次，
## 挂满 20 个逐像素算子会把整份工程拖到两秒一帧。其余节点照样接好源图，接上预览就能看。
const TOUR_PREVIEW: Array[String] = [
	"image.levels", "image.invert", "image.threshold", "image.mask", "image.shadow",
]

var _used: Dictionary = {}
var _sources: Array[String] = []


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR + "/assets"))
	_write_sheet(SHEET_PATH)
	_write_orb(ORB_PATH)

	_used.clear()
	var child := _build_child()
	print("写入 %s：%s" % [SUB_PATH, error_string(FxGraphDoc.save(child, SUB_PATH))])

	_used.clear()
	_sources.clear()
	var doc := _build_main()
	_check(doc)
	print("写入 %s：%s" % [DOC_PATH, error_string(FxGraphDoc.save(doc, DOC_PATH))])

	var packed := FxProjectArchive.save_zip(doc, PROJ_PATH, {"include_assets": true})
	print("打包 %s：%s · 素材 %d 个 · 插件 %d 个" % [
		PROJ_PATH, str(packed.get("ok", false)),
		(packed.get("manifest", {}).get("assets", []) as Array).size(),
		(packed.get("manifest", {}).get("plugins", []) as Array).size(),
	])
	_report(doc)
	FxPluginHost.shutdown()
	quit(0)


# ================= 素材：用代码画出来，不依赖任何外部文件 =================

## 4 × 4 帧的四角星，一边旋转一边呼吸 —— 当「精灵表」节点的输入。
func _write_sheet(path: String) -> void:
	var total := SHEET_COLS * SHEET_ROWS
	var img := Image.create(SHEET_FRAME * SHEET_COLS, SHEET_FRAME * SHEET_ROWS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var half := float(SHEET_FRAME) * 0.5
	for f in range(total):
		var ox := (f % SHEET_COLS) * SHEET_FRAME
		var oy := (f / SHEET_COLS) * SHEET_FRAME
		var ang := TAU * float(f) / float(total)
		var pulse := 0.78 + 0.22 * sin(ang * 2.0)
		for y in range(SHEET_FRAME):
			for x in range(SHEET_FRAME):
				var p := Vector2(float(x) + 0.5, float(y) + 0.5) - Vector2(half, half)
				var r := p.length() / half
				if r > 1.0:
					continue
				var theta := atan2(p.y, p.x)
				var spike := pow(absf(cos(theta * 2.0 - ang)), 6.0)
				var edge := (0.2 + 0.66 * spike) * pulse
				var a := clampf(1.0 - (r - edge) / 0.18, 0.0, 1.0)
				if a <= 0.004:
					continue
				a = a * a
				var col := Color(1.0, 0.74, 0.42).lerp(Color(1.0, 0.98, 0.9), a)
				img.set_pixel(ox + x, oy + y, Color(col.r, col.g, col.b, a))
	img.save_png(path)
	print("写入 %s：%d × %d" % [path, img.get_width(), img.get_height()])


## 一张带环的光球 —— 给「外部贴图 / 图片文件 / 图像对象」当输入。
func _write_orb(path: String) -> void:
	var size := 128
	var half := float(size) * 0.5
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y in range(size):
		for x in range(size):
			var p := Vector2(float(x) + 0.5, float(y) + 0.5) - Vector2(half, half)
			var r := p.length() / half
			if r > 1.0:
				continue
			var ring := exp(-pow((r - 0.74) / 0.05, 2.0))
			var core := exp(-pow(r / 0.26, 2.0)) * 0.8
			var a := clampf(ring + core, 0.0, 1.0)
			if a <= 0.004:
				continue
			var col := Color(0.52, 0.8, 1.0).lerp(Color(1.0, 1.0, 1.0), core)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	img.save_png(path)
	print("写入 %s：%d × %d" % [path, img.get_width(), img.get_height()])


# ================= 子工程 =================

func _build_child() -> Dictionary:
	var doc := FxGraphDoc.create("示范工程 · 子图（能量环）")
	FxGraphDoc.set_canvas(doc, CHILD_CANVAS.x, CHILD_CANVAS.y)
	FxGraphDoc.set_timeline(doc, FPS, DURATION, true)
	# 边界：外层连「强度」进来，子图把「能量进度」交回去。
	FxGraphDoc.add_node(doc, "graph.input", "s_intensity", Vector2(-300, 0), {
		"name": "强度", "type": "number",
	})
	FxGraphDoc.add_node(doc, "graph.timeline", "s_time", Vector2(-300, 200), {})
	FxGraphDoc.add_node(doc, "anim.remap", "s_progress", Vector2(-60, 200), {
		"in_min": 0.0, "in_max": 1.0, "out_min": 0.25, "out_max": 0.6,
		"clamp": true, "curve": "linear",
	})
	FxGraphDoc.add_node(doc, "graph.output", "s_progress_out", Vector2(200, 200), {
		"name": "能量进度", "type": "number",
	})
	FxGraphDoc.add_node(doc, "image.rays", "s_rays", Vector2(0, 0), {
		"count": 16, "color": "#ffd479", "length": 1.15, "width": 0.06,
		"speed": 0.8, "intensity": 1.3, "center": [0.5, 0.5],
	})
	FxGraphDoc.add_node(doc, "image.shockwave", "s_shock", Vector2(0, 380), {
		"radius": {"track": [[0.0, 0.05], [1.6, 0.95], [2.0, 0.05]], "interp": "ease"},
		"width": 0.06, "speed": 1.0, "color": "#ffd166", "core": "#ff7a2a",
		"intensity": 1.1, "center": [0.5, 0.5],
	})
	FxGraphDoc.add_node(doc, "image.mix", "s_mix", Vector2(360, 110), {
		"mode": "add", "amount": 1.0,
	})
	FxGraphDoc.add_node(doc, "image.blur", "s_blur", Vector2(620, 110), {"radius": 2})
	FxGraphDoc.add_node(doc, "output.final", "s_out", Vector2(880, 110), {
		"layers": [], "background_color": "#00000000",
	})
	doc["output"] = "s_out"
	_link(doc, "s_intensity", "value", "s_shock", "intensity")
	_link(doc, "s_time", "progress", "s_progress", "value")
	_link(doc, "s_progress", "value", "s_progress_out", "value")
	_link(doc, "s_rays", "image", "s_mix", "a")
	_link(doc, "s_shock", "image", "s_mix", "b")
	_link(doc, "s_mix", "image", "s_blur", "image")
	_link(doc, "s_blur", "image", "s_out", "background")
	return doc


# ================= 主图 =================

func _build_main() -> Dictionary:
	var doc := FxGraphDoc.create("示范工程 · 全能力演示")
	FxGraphDoc.set_canvas(doc, CANVAS.x, CANVAS.y)
	FxGraphDoc.set_timeline(doc, FPS, DURATION, true)
	doc["meta"]["note"] = "把工作台的能力全用一遍：外部素材、精灵表、配方、子图、着色器、图层、关键帧、连线驱动、流程与导出。"
	doc["meta"]["author"] = "幻像工坊 · 随包示例"

	_build_sources(doc)
	_build_background(doc)
	_build_foreground(doc)
	_build_drivers(doc)
	_build_flow_and_export(doc)
	_build_output(doc)
	_build_tour(doc)
	return doc


## 配方自带分辨率和一整套粒子参数；这里只把尺寸压到子图画布，
## 让「复用 VfxEngine」这件事不至于吃掉整帧预算（配方本体一行不改）。
func _recipe_json() -> String:
	var parsed: Variant = JSON.parse_string(FxRecipePresets.json_of("energy"))
	if not parsed is Dictionary:
		return FxRecipePresets.json_of("energy")
	var recipe: Dictionary = parsed
	recipe["width"] = CHILD_CANVAS.x
	recipe["height"] = CHILD_CANVAS.y
	return JSON.stringify(recipe)


## ① 素材区：每种「图像从哪来」各来一个。
func _build_sources(doc: Dictionary) -> void:
	_add(doc, "image.sheet", "src_sheet", _p(-980, 0), {
		"path": SHEET_PATH, "mode": "grid", "columns": SHEET_COLS, "rows": SHEET_ROWS,
		"fps": 14.0, "loop": true, "fit": "contain", "scale": 0.72,
	})
	_add(doc, "image.texture", "src_orb", _p(-980, 240), {
		"path": ORB_PATH, "fit": "contain", "scale": 0.8,
	})
	_add(doc, "image.file", "src_file", _p(-980, 460), {
		"path": ORB_PATH, "fit": "contain", "background": "#00000000",
	})
	_add(doc, "image.pixelfx", "src_pixelfx", _p(-980, 680), {
		"asset": "fire/campfire", "fps": 24, "scale": 0.9, "offset": [0, 16], "alpha": 0.95,
	})
	_add(doc, "image.recipe", "src_recipe", _p(-980, 900), {
		"recipe": _recipe_json(), "fit": "contain", "seed": 3,
	})
	_add(doc, "image.solid", "src_solid", _p(-980, 1120), {"color": "#0d1424"})
	_add(doc, "image.text", "src_text", _p(-980, 1300), {
		"text": "幻像工坊", "size": 20, "color": "#ffffff", "align": "center", "offset": [0, -18],
	})
	_preview(doc, "src_file", "image", _p(-640, 460), "图片文件：直接读外部 PNG")
	_preview(doc, "src_pixelfx", "image", _p(-640, 680), "pixelfx 序列帧：内置的 244 套手绘特效")
	_preview(doc, "src_sheet", "image", _p(-640, 0), "精灵表：4 × 4，14 fps 循环")


## ② 背景：渐变 + 星野 + 噪声星云。
func _build_background(doc: Dictionary) -> void:
	_add(doc, "image.gradient", "bg_grad", _p(0, 0), {
		"mode": "radial", "color_a": "#04060e", "color_b": "#301a5e",
		"center": [0.5, 0.52], "scale": 1.25, "softness": 0.28,
	})
	_add(doc, "image.starfield", "bg_stars", _p(0, 220), {
		"count": 90, "seed": 5, "color": "#cfe6ff", "background": "#00000000",
		"size": 1.0, "glow": 1.6,
	})
	_add(doc, "image.mix", "bg_sky", _p(320, 90), {"mode": "add", "amount": 1.0})
	_add(doc, "image.noise", "bg_vor", _p(0, 440), {
		"seed": 9, "cell": 5, "density": 0.5,
		"color_a": "#0a1120", "color_b": "#3a2a6e",
	})
	_add(doc, "image.blur", "bg_vblur", _p(320, 440), {"radius": 10})
	_add(doc, "image.ramp", "bg_ramp", _p(600, 440), {
		"shadow": "#05080f", "mid": "#1d1740", "highlight": "#5a3fae",
		"midpoint": 0.55, "amount": 0.28,
	})
	_add(doc, "image.blend2", "bg_comp", _p(860, 200), {
		"mode": "screen", "opacity": 0.28, "offset": [0, 0],
	})
	_link(doc, "bg_grad", "image", "bg_sky", "a")
	_link(doc, "bg_stars", "image", "bg_sky", "b")
	_link(doc, "bg_vor", "image", "bg_vblur", "image")
	_link(doc, "bg_vblur", "image", "bg_ramp", "image")
	_link(doc, "bg_sky", "image", "bg_comp", "a")
	_link(doc, "bg_ramp", "image", "bg_comp", "b")


## ③ 前景：精灵表 / 光球 / 标题 / 子图 + 着色器。
func _build_foreground(doc: Dictionary) -> void:
	_add(doc, "image.wave", "fg_wave", _p(0, 680), {
		"amplitude": 6.0, "frequency": 0.06, "speed": 1.2, "axis": "y",
	})
	_add(doc, "image.hue", "fg_hue", _p(320, 680), {"hue": 0.0, "saturation": 0.15})
	_add(doc, "image.bloom", "fg_bloom", _p(600, 680), {
		"threshold": 0.45, "amount": 0.85, "radius": 5,
	})
	_add(doc, "image.transform", "fg_orb_move", _p(0, 900), {
		"offset": [0, 0], "scale": [0.6, 0.6], "rotation": 0.0,
		"anchor": [0.5, 0.5], "wrap": "transparent",
	})
	_add(doc, "image.glow", "fg_orb_glow", _p(320, 900), {"radius": 7, "amount": 0.85})
	_add(doc, "image.outline", "fg_title_line", _p(0, 1120), {
		"color": "#241046", "thickness": 2, "mode": "outside", "threshold": 0.1,
	})
	_add(doc, "image.glow", "fg_title_glow", _p(320, 1120), {
		"radius": {"track": [[0.0, 4.0], [1.0, 12.0], [2.0, 4.0]], "interp": "ease"},
		"amount": 0.6,
	})
	_add(doc, "image.tint", "fg_title_tint", _p(600, 1120), {
		"color": "#bfe4ff", "amount": 0.3, "preserve_luma": true,
	})
	_add(doc, "graph.subgraph", "fg_sub", _p(0, 1360), {
		"path": SUB_PATH, "fit": "contain", "scale": 1.0, "offset": [0, 0], "alpha": 0.95,
		"time_scale": {"track": [[0.0, 0.6], [1.0, 1.4], [2.0, 0.6]], "interp": "ease"},
	})
	_add(doc, "shader.image", "fg_shader", _p(340, 1360), {
		"code": "shader_type canvas_item;\nuniform float u_time;\nvoid fragment() {\n\tvec2 uv = UV;\n\tfloat scan = sin((uv.y * 90.0) - u_time * 6.0);\n\tscan = smoothstep(0.75, 1.0, scan) * 0.5;\n\tvec4 base = texture(TEXTURE, uv);\n\tfloat vig = smoothstep(0.95, 0.35, distance(uv, vec2(0.5)));\n\tCOLOR = vec4(base.rgb + vec3(0.25, 0.45, 0.9) * scan * 0.5, base.a * vig);\n}\n",
		"uniforms": "", "enabled": true,
	})
	_link(doc, "src_sheet", "image", "fg_wave", "image")
	_link(doc, "fg_wave", "image", "fg_hue", "image")
	_link(doc, "fg_hue", "image", "fg_bloom", "image")
	_link(doc, "src_orb", "image", "fg_orb_move", "image")
	_link(doc, "fg_orb_move", "image", "fg_orb_glow", "image")
	_link(doc, "src_text", "image", "fg_title_line", "image")
	_link(doc, "fg_title_line", "image", "fg_title_glow", "image")
	_link(doc, "fg_title_glow", "image", "fg_title_tint", "image")
	_link(doc, "fg_sub", "image", "fg_shader", "image")
	# 图像对象：把一张图当对象读属性（宽高 / 格式 / 像素数），再读一个像素回来驱动参数。
	_add(doc, "image.object", "fg_obj", _p(600, 900), {})
	_add(doc, "image.info", "fg_obj_info", _p(860, 900), {})
	_add(doc, "image.pixel", "fg_obj_px", _p(860, 1080), {"x": 128, "y": 72})
	_add(doc, "math.number", "fg_px_mul", _p(600, 1080), {"op": "multiply", "a": 0.0, "b": 0.9})
	_link(doc, "src_orb", "image", "fg_obj", "image")
	_link(doc, "fg_obj", "object", "fg_obj_info", "object")
	_link(doc, "fg_obj", "object", "fg_obj_px", "object")
	_link(doc, "fg_obj_px", "r", "fg_px_mul", "a")
	_link(doc, "fg_px_mul", "number", "fg_bloom", "amount")
	_preview(doc, "fg_obj_info", "image", _p(1120, 900), "图像对象：宽 × 高 / 格式 / 像素数")


## ⑤ 驱动区：关键帧写一半，连线驱动写另一半。
func _build_drivers(doc: Dictionary) -> void:
	_add(doc, "anim.oscillator", "drv_osc", _p(0, 1700), {
		"wave": "sine", "frequency": 0.35, "amplitude": 0.5, "offset": 0.5,
		"phase": 0.0, "duty": 0.5,
	})
	_add(doc, "anim.remap", "drv_hue", _p(300, 1700), {
		"in_min": 0.0, "in_max": 1.0, "out_min": -28.0, "out_max": 28.0,
		"clamp": true, "curve": "linear",
	})
	_add(doc, "anim.pulse", "drv_pulse", _p(0, 1880), {
		"attack": 0.15, "hold": 0.2, "release": 0.35, "period": 1.6, "amplitude": 1.0,
	})
	_add(doc, "math.number", "drv_radius", _p(300, 1880), {
		"op": "multiply", "a": 0.0, "b": 10.0,
	})
	_add(doc, "anim.steps", "drv_steps", _p(0, 2060), {
		"values": "0.15,0.45,0.8", "duration": 2.0, "loop": true, "interp": "linear",
	})
	_add(doc, "anim.ease", "drv_ease", _p(0, 2240), {
		"curve": "quad_inout", "duration": 2.0, "from": 0.12, "to": 0.58,
		"offset": 0.0, "loop": true, "reverse": false,
	})
	_add(doc, "anim.orbit", "drv_orbit", _p(0, 2420), {
		"radius": [28, 16], "speed": 0.5, "phase": 0.0, "center": [0, 0], "tilt": 0.0,
	})
	_add(doc, "anim.noise1d", "drv_noise", _p(0, 2600), {
		"seed": 21, "frequency": 0.6, "octaves": 2, "amplitude": 1.0, "offset": 0.5,
	})
	_add(doc, "math.number", "drv_noise_amp", _p(300, 2600), {
		"op": "multiply", "a": 0.0, "b": 9.0,
	})
	# 图属性也能当数据源：画布宽度决定泛光半径，时间轴进度决定光球辉光半径。
	_add(doc, "graph.canvas", "drv_canvas", _p(0, 2780), {})
	_add(doc, "math.number", "drv_block", _p(300, 2780), {
		"op": "divide", "a": 0.0, "b": 32.0,
	})
	_add(doc, "graph.timeline", "drv_timeline", _p(0, 2960), {})
	_add(doc, "anim.remap", "drv_ripple", _p(300, 2960), {
		"in_min": 0.0, "in_max": 1.0, "out_min": 2.0, "out_max": 10.0,
		"clamp": true, "curve": "linear",
	})
	# 子图边界：脉冲抬一下「强度」送进子图，子图再把「能量进度」交回来点亮标题。
	_add(doc, "math.number", "drv_ring", _p(560, 1880), {
		"op": "multiply", "a": 0.0, "b": 1.6,
	})
	_link(doc, "drv_osc", "value", "drv_hue", "value")
	_link(doc, "drv_hue", "value", "fg_hue", "hue")
	_link(doc, "drv_pulse", "value", "drv_radius", "a")
	_link(doc, "drv_radius", "number", "bg_vblur", "radius")
	_link(doc, "drv_pulse", "value", "drv_ring", "a")
	_link(doc, "drv_ring", "number", "fg_sub", "s_intensity")
	_link(doc, "fg_sub", "s_progress_out", "fg_title_glow", "amount")
	_link(doc, "drv_steps", "value", "fg_title_tint", "amount")
	_link(doc, "drv_ease", "value", "bg_grad", "softness")
	_link(doc, "drv_orbit", "vec", "fg_orb_move", "offset")
	_link(doc, "drv_noise", "value", "drv_noise_amp", "a")
	_link(doc, "drv_noise_amp", "number", "fg_wave", "amplitude")
	_link(doc, "drv_canvas", "width", "drv_block", "a")
	_link(doc, "drv_block", "number", "fg_bloom", "radius")
	_link(doc, "drv_timeline", "progress", "drv_ripple", "value")
	_link(doc, "drv_ripple", "value", "fg_orb_glow", "radius")


## ⑥ 流程与导出：分支决定走哪条执行流，五个导出节点全部 run = false。
func _build_flow_and_export(doc: Dictionary) -> void:
	_add(doc, "logic.compare", "fl_cmp", _p(0, 3140), {
		"op": "greater", "a": 0.0, "b": 0.45, "tolerance": 0.0001,
	})
	_add(doc, "logic.bool", "fl_bool", _p(300, 3140), {"op": "and", "a": false, "b": true})
	_add(doc, "flow.branch", "fl_branch", _p(600, 3140), {"condition": true})
	_add(doc, "flow.sequence", "fl_seq", _p(900, 3140), {"steps": 2})
	_add(doc, "flow.for", "fl_loop", _p(0, 3320), {
		"first": 0, "last": 3, "step": 1, "max_iterations": 64,
	})
	# 累积的输入用一张静态图：时间相关的链在循环里会被逐次重算，非常贵。
	_add(doc, "image.shape", "fl_src", _p(300, 3500), {
		"shape": "circle", "color": "#7ee787", "size": 0.35, "feather": 0.2,
	})
	_add(doc, "image.accumulate", "fl_acc", _p(300, 3320), {
		"mode": "add", "opacity": 0.35, "reset": true,
	})
	_add(doc, "flow.index", "fl_index", _p(600, 3320), {})
	_add(doc, "io.export_image", "io_png", _p(900, 3320), {
		"path": "user://exports/demo_frame.png", "run": false,
	})
	_add(doc, "io.export_sheet", "io_sheet", _p(900, 3500), {
		"path": "user://exports/demo_sheet.png", "run": false,
	})
	_add(doc, "io.export_sequence", "io_seq", _p(900, 3680), {
		"dir": "user://exports/demo_sequence", "run": false,
	})
	_add(doc, "io.export_godot", "io_godot", _p(900, 3860), {
		"path": "user://exports/demo_emitter.tscn", "source": "sheet",
		"amount": 48, "lifetime": 0.0, "run": false,
	})
	_add(doc, "io.save_doc", "io_save", _p(900, 4040), {
		"path": "user://exports/demo.fxgraph", "run": false,
	})
	_link(doc, "drv_pulse", "value", "fl_cmp", "a")
	_link(doc, "fl_cmp", "result", "fl_bool", "a")
	_link(doc, "fl_bool", "result", "fl_branch", "condition")
	_link(doc, "fl_branch", "true", "fl_seq", "exec")
	_link(doc, "fl_loop", "body", "fl_acc", "exec")
	_link(doc, "fl_src", "image", "fl_acc", "image")
	_link(doc, "fg_bloom", "image", "io_png", "image")
	_preview(doc, "fl_acc", "image", _p(600, 3500), "循环 + 图像累积")


## ④ 输出：5 个图层，混合模式各不相同；标题图层的位移打关键帧。
func _build_output(doc: Dictionary) -> void:
	_add(doc, "output.final", "out", _p(1180, 900), {
		"layers": [
			{"name": "能量环", "blend": "screen", "opacity": 0.25, "offset": [0, 0], "visible": true},
			{"name": "光球", "blend": "add", "opacity": 0.9, "offset": [0, 0], "visible": true},
			{"name": "火花", "blend": "add", "opacity": 0.8, "offset": [0, 0], "visible": true},
			{"name": "扫描条纹", "blend": "screen", "opacity": 0.4, "offset": [0, 0], "visible": true},
			{"name": "标题", "blend": "normal", "opacity": 1.0,
				"offset": {"track": [[0.0, [0, 4]], [1.0, [0, -4]], [2.0, [0, 4]]], "interp": "ease"},
				"visible": true},
		],
		"background_color": "#05070f",
	})
	doc["output"] = "out"
	_link(doc, "bg_comp", "image", "out", "background")
	_link(doc, "src_recipe", "image", "out", "layer_0")
	_link(doc, "fg_orb_glow", "image", "out", "layer_1")
	_link(doc, "fg_bloom", "image", "out", "layer_2")
	_link(doc, "fg_shader", "image", "out", "layer_3")
	_link(doc, "fg_title_tint", "image", "out", "layer_4")
	# 注意：不要在这里再挂一个「预览最终输出」的节点 —— output.preview 每帧都会把它上游
	# 整条链重跑一遍（时间相关节点不跨消费者复用），等于把成本翻倍。预览口留给素材区。


# ================= 巡展：剩余类型一个不落 =================

func _ensure_sources(doc: Dictionary) -> void:
	if not _sources.is_empty():
		return
	var presets := [
		["image.checker", "tour_src_checker",
			{"cell": 10, "color_a": "#1f3a66", "color_b": "#f0c060"}],
		["image.shape", "tour_src_shape",
			{"shape": "circle", "color": "#ffd479", "size": 0.55, "feather": 0.12}],
		["image.noise", "tour_src_noise", {"seed": 7, "cell": 3, "density": 0.55}],
	]
	var row := 0
	for preset in presets:
		var made := _add(doc, String(preset[0]), String(preset[1]), _p(1800, row), preset[2])
		if not made.is_empty():
			_sources.append(made)
		row += 160


## 抖动 / 路径 / 弹簧三个运动算子各配一个位移 + 预览，让「数值 → 参数」看得见。
func _build_motion_demos(doc: Dictionary) -> void:
	var presets := [
		["anim.shake", "抖动", {"amplitude": [9, 6], "frequency": 9.0, "seed": 17, "decay": 1.4}],
		["anim.path", "路径", {"points": "0,0;26,16;0,30;-26,16", "duration": 2.0,
			"loop": true, "smooth": true}],
		["anim.spring", "弹簧", {"target": 26.0, "stiffness": 90.0, "damping": 9.0, "duration": 1.4}],
	]
	for i in range(presets.size()):
		var type_id := String(presets[i][0])
		if _used.has(type_id):
			continue
		var pos := _p(1800, 560 + i * 200)
		var drv := _add(doc, type_id, "motion_%d" % i, pos, presets[i][2])
		var src := _add(doc, "image.checker", "motion_src_%d" % i,
			pos + Vector2(280, 0), {"cell": 6, "color_a": "#1b2a4a", "color_b": "#7ee787"})
		var move := _add(doc, "image.transform", "motion_move_%d" % i,
			pos + Vector2(560, 0), {"scale": [0.5, 0.5], "offset": [0, 0]})
		_link(doc, src, "image", move, "image")
		_link(doc, drv, "vec", move, "offset")
		_preview(doc, move, "image", pos + Vector2(840, 0), "运动算子 · %s" % String(presets[i][1]))


func _build_tour(doc: Dictionary) -> void:
	_ensure_sources(doc)
	_build_motion_demos(doc)
	var index := 0
	for raw in FxCatalog.all():
		var def: FxNodeDef = raw
		var type_id := String(def.id)
		if _used.has(type_id):
			continue
		var pos := Vector2(2400.0 + float(index / 6) * 420.0, float(index % 6) * 260.0)
		_place_tour_node(doc, def, pos, index)
		index += 1
	print("巡展区补齐 %d 个类型" % index)


func _place_tour_node(doc: Dictionary, def: FxNodeDef, pos: Vector2, cursor: int) -> void:
	var type_id := String(def.id)
	var made := _add(doc, type_id, "tour_" + type_id.replace(".", "_"), pos, def.default_params())
	if made.is_empty():
		return
	var slot := 0
	for port in def.inputs:
		if not FxPortType.can_connect(FxPortType.IMAGE, StringName(String(port.get("type", "any")))):
			continue
		if _sources.is_empty():
			break
		var src: String = _sources[(cursor + slot) % _sources.size()]
		_link(doc, src, "image", made, String(port.get("id", "")))
		slot += 1
	if not TOUR_PREVIEW.has(type_id) or def.is_output:
		return
	var image_out := ""
	for port in def.outputs:
		if FxPortType.can_connect(FxPortType.IMAGE, StringName(String(port.get("type", "any")))):
			image_out = String(port.get("id", ""))
			break
	if image_out.is_empty():
		return
	_preview(doc, made, image_out, pos + Vector2(300, 0), type_id)


# ================= 工具 =================

func _p(x: float, y: float) -> Vector2:
	return Vector2(x, y)


func _add(doc: Dictionary, type: String, id: String, pos: Vector2, params: Dictionary = {}) -> String:
	var made := FxGraphDoc.add_node(doc, type, id, pos, params)
	var got := String(made.get("id", ""))
	if got.is_empty():
		push_error("加不了节点：%s（%s）" % [type, id])
		return ""
	_used[type] = true
	return got


func _link(doc: Dictionary, from: String, from_port: String, to: String, to_port: String) -> bool:
	if from.is_empty() or to.is_empty():
		return false
	var result := FxGraphDoc.connect_ports(doc, from, from_port, to, to_port)
	if result != FxGraphDoc.LINK_OK:
		push_error("连线失败 %s.%s → %s.%s（%s）" % [
			from, from_port, to, to_port, _link_error(result)])
		return false
	return true


func _link_error(code: int) -> String:
	match code:
		FxGraphDoc.LINK_NO_NODE: return "节点不存在"
		FxGraphDoc.LINK_NO_PORT: return "端口不存在"
		FxGraphDoc.LINK_TYPE: return "类型不兼容"
		FxGraphDoc.LINK_CYCLE: return "会成环"
	return "未知"


func _preview(doc: Dictionary, from: String, from_port: String, pos: Vector2, note: String) -> void:
	if from.is_empty():
		return
	var id := "prev_" + from
	var made := _add(doc, "output.preview", id, pos, {"note": note})
	if made.is_empty():
		return
	_link(doc, from, from_port, made, "image")


func _check(doc: Dictionary) -> void:
	var issues := FxGraphDoc.validate(doc)
	if issues.is_empty():
		print("结构校验：通过")
		return
	for issue in issues:
		print("结构问题：", issue)


func _report(doc: Dictionary) -> void:
	var runner := FxGraphRunner.new()
	var frame: Dictionary = runner.run(doc, 0.0)
	runner.invalidate_cache()
	frame = runner.run(doc, 0.5)
	var image: Variant = frame.get("image")
	var stats: Dictionary = frame.get("stats", {})
	var types := {}
	var with_frames := 0
	for raw in doc.get("nodes", []):
		var item: Dictionary = raw
		types[String(item.get("type", ""))] = true
		if item.get("type", "") == "output.preview":
			with_frames += 1
	var layer_count := 0
	var out := FxGraphDoc.node(doc, doc.get("output", ""))
	if not out.is_empty():
		layer_count = (out.get("params", {}).get("layers", []) as Array).size()
	print("[示范工程] 节点 %d · 类型 %d/%d · 边 %d · 输出 %s · %d 图层 · %d 个预览 · 求值 %.0f ms" % [
		(doc.get("nodes", []) as Array).size(), types.size(), FxCatalog.all().size(),
		(doc.get("edges", []) as Array).size(),
		"null" if image == null else "%d×%d" % [(image as Image).get_width(), (image as Image).get_height()],
		layer_count, with_frames, float(stats.get("ms", 0.0)),
	])
	var missing: Array[String] = []
	for raw in FxCatalog.all():
		var def: FxNodeDef = raw
		if not types.has(String(def.id)):
			missing.append(String(def.id))
	if missing.is_empty():
		print("类型覆盖：%d/%d 全齐" % [types.size(), FxCatalog.all().size()])
	else:
		print("未覆盖：", missing)
