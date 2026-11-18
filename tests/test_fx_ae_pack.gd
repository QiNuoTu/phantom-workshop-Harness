extends SceneTree
## AE 风格图像插件族自测（fx.keying / fx.channels / fx.masks / fx.tone / fx.stylize）。
##
## 三条纪律，和工程里其它套件一致：
##   1. **逐像素断言**，不看"大概有变化"——「有变化」也可能是算错了方向；
##   2. **参数关掉必须逐字节等于原图**（半径 0 / 强度 0），否则"关掉却不生效"
##      会被当成渲染器坏了，查起来最费时间；
##   3. **节点定义也要测**：op id 拼错、端口名写错在运行期只报一句 push_error，
##      所以每个节点都走一遍 `FxCatalog.def()` + `FxOpRegistry.has_op()`。
##
## 运行：godot --headless --path . --script res://tests/test_fx_ae_pack.gd

const SIZE := Vector2i(32, 32)
const OUT_DIR := "user://graph_test"

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("== AE 风格图像插件族自测 ==")
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	_test_catalog()
	_test_keying()
	_test_channels()
	_test_masks()
	_test_tone()
	_test_stylize()
	_test_curve_widget()
	_test_graph_wiring()
	print("----")
	print("断言 %d 条" % checks)
	# 收尾必须自己关插件宿主：`ensure()` 建的实例与静态注册表不归引擎管，
	# 退出阶段按引擎顺序释放会 SIGSEGV（tests/test_plugins 与 test_plugin_lifecycle 同理）。
	# 这一条不是"测试技巧"，是 kernel 0.1.8 修掉的那个真问题的正确用法。
	FxPluginHost.shutdown()
	if failures.is_empty():
		print("AE 插件族自测全部通过")
		_quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		_quit(1)


# ================= 1. 目录契约 =================

## 五个插件、二十九个节点：定义在、op 在、端口名与算子读的键一致。
const EXPECTED := {
	"key.chroma_pro": ["image", "screen", "black", "white", "view"],
	"key.luma": ["image", "channel", "black", "white"],
	"key.diff": ["image", "background", "tolerance", "offset"],
	"key.color_range": ["image", "target", "hue_range"],
	"key.matte_clean": ["image", "shrink", "feather", "view"],
	"key.despill": ["image", "strength", "mode"],
	"channel.extract": ["image", "channel"],
	"channel.combine": ["r", "g", "b", "mode"],
	"channel.mixer": ["image", "rr", "gg", "bb", "mono"],
	"channel.set_alpha": ["image", "source", "channel", "invert"],
	"channel.shift": ["image", "offset", "amount"],
	"channel.swap": ["image", "r_from", "g_from"],
	"mask.rect": ["position", "size", "feather", "invert"],
	"mask.ellipse": ["center", "radius", "rotation"],
	"mask.boolean": ["a", "b", "mode"],
	"mask.from_luma": ["image", "black", "white"],
	"mask.feather": ["image", "radius", "expand"],
	"mask.vignette": ["center", "radius", "softness"],
	"tone.posterize_pro": ["image", "levels", "mode", "dither"],
	"tone.palette": ["image", "c1", "c2", "steps"],
	"tone.levels_pro": ["image", "in_black", "in_white", "gamma"],
	"tone.split_tone": ["image", "shadow", "highlight"],
	"tone.temperature": ["image", "temperature", "tint", "vibrance"],
	"tone.curves": ["image", "points", "channel"],
	"style.find_edges": ["image", "strength", "mode"],
	"style.emboss": ["image", "angle", "strength"],
	"style.cartoon": ["image", "levels", "edge_strength"],
	"style.halftone": ["image", "cell", "angle"],
	"style.grain": ["image", "amount", "size", "seed"],
}


func _test_catalog() -> void:
	for type_id in EXPECTED.keys():
		var def: FxNodeDef = FxCatalog.def(type_id)
		_check(def != null, "节点定义存在：%s" % type_id)
		if def == null:
			continue
		_check(not String(def.owner_plugin).is_empty(), "%s 有归属插件" % type_id)
		_check(FxOpRegistry.has_op(def.op), "%s 的算子 %s 已实现" % [type_id, String(def.op)])
		var ports := {}
		for p in def.inputs:
			ports[String((p as Dictionary).get("id", ""))] = true
		for spec in def.params:
			ports[String((spec as Dictionary).get("id", ""))] = true
		for key in EXPECTED[type_id]:
			_check(ports.has(String(key)), "%s 有输入/参数「%s」" % [type_id, key])


# ================= 2. 抠像 =================

func _test_keying() -> void:
	# 左边绿幕、右边红前景。抠绿之后：左 alpha≈0，右 alpha=255，右色不变。
	var split := _split(Color(0, 1, 0), Color(1, 0, 0))
	var keyed := _op("key.chroma_pro", "key.chroma_pro", {"image": split}, {
		"screen": "#00ff00", "black": 0.18, "white": 0.62, "soften": 0.0,
		"shrink": 0.0, "despill": 0.0, "view": "result",
	})
	_check(keyed != null, "专业绿幕键出图")
	if keyed != null:
		_check(_alpha(keyed, 2, 16) == 0, "绿幕被抠掉（alpha=%d）" % _alpha(keyed, 2, 16))
		_check(_alpha(keyed, 29, 16) == 255, "红前景保留（alpha=%d）" % _alpha(keyed, 29, 16))
		_check(_near(_pixel(keyed, 29, 16), Color(1, 0, 0)), "前景颜色不被改")
	# 蒙版视图：白=保留
	var matte := _op("key.chroma_pro", "key.chroma_pro", {"image": split}, {
		"screen": "#00ff00", "soften": 0.0, "view": "matte",
	})
	if matte != null:
		_check(_pixel(matte, 2, 16).r < 0.02, "蒙版视图：绿幕为黑")
		_check(_pixel(matte, 29, 16).r > 0.98, "蒙版视图：前景为白")

	# 亮度键：白全留、黑全抠
	var white := _solid(Color(1, 1, 1))
	var black := _solid(Color(0, 0, 0))
	var luma_white := _op("key.luma", "key.luma", {"image": white}, {"black": 0.3, "white": 0.6})
	var luma_black := _op("key.luma", "key.luma", {"image": black}, {"black": 0.3, "white": 0.6})
	if luma_white != null and luma_black != null:
		_check(_alpha(luma_white, 8, 8) == 255, "亮度键：白底全保留")
		_check(_alpha(luma_black, 8, 8) == 0, "亮度键：黑底全抠掉")
	# 反相
	var inverted := _op("key.luma", "key.luma", {"image": white}, {
		"black": 0.3, "white": 0.6, "invert": true,
	})
	if inverted != null:
		_check(_alpha(inverted, 8, 8) == 0, "亮度键反相后白底被抠掉")

	# 差值键：和背景一样的地方要抠掉，动过的地方要留
	var bg := _solid(Color(0.2, 0.2, 0.2))
	var moved := _solid(Color(0.2, 0.2, 0.2))
	for x in range(16, 32):
		for y in range(0, 32):
			moved.set_pixel(x, y, Color(0.9, 0.2, 0.2))
	var diff := _op("key.diff", "key.diff", {"image": moved, "background": bg}, {
		"tolerance": 0.05, "softness": 0.05, "despill": 0.0,
	})
	if diff != null:
		_check(_alpha(diff, 4, 4) == 0, "差值键：与背景相同处抠掉（alpha=%d）" % _alpha(diff, 4, 4))
		_check(_alpha(diff, 24, 16) == 255, "差值键：变化处保留（alpha=%d）" % _alpha(diff, 24, 16))

	# 颜色范围：目标绿 → 绿被抠，其它保留
	var ranged := _op("key.color_range", "key.color_range", {"image": split}, {
		"target": "#00ff00", "hue_range": 0.06, "sat_range": 0.2, "luma_range": 0.5,
		"softness": 0.01, "despill": 0.0,
	})
	if ranged != null:
		_check(_alpha(ranged, 2, 16) == 0, "颜色范围：绿色被选走")
		_check(_alpha(ranged, 29, 16) == 255, "颜色范围：红色没被选走")

	# 蒙版清理：斑点被收缩吃掉；参数全 0 时逐字节不变
	var speckled := _solid(Color(0, 0, 0))
	for y in range(16):
		for x in range(16):
			speckled.set_pixel(x, y, Color(1, 1, 1))
	speckled.set_pixel(24, 24, Color(1, 1, 1))  # 孤点
	var cleaned := _op("key.matte_clean", "key.matte_clean", {"image": speckled}, {
		"shrink": 1, "feather": 0, "denoise": 0.0, "view": "matte",
	})
	if cleaned != null:
		_check(_alpha(cleaned, 24, 24) == 0, "蒙版清理：孤点被收缩吃掉")
		_check(_alpha(cleaned, 8, 8) == 255, "蒙版清理：大块保留")
	# 参数全 0 时**蒙版**必须原样：这一条不比对字节，因为输出统一是 (v,v,v,v)
	# 的蒙版表示法，而输入可能是彩色图 —— 比的是"读出来的蒙版值"。
	var untouched := _op("key.matte_clean", "key.matte_clean", {"image": speckled}, {
		"shrink": 0, "feather": 0, "denoise": 0.0, "view": "matte",
	})
	if untouched != null:
		_check(_alpha(untouched, 8, 8) == 255 and _alpha(untouched, 24, 24) == 255
			and _alpha(untouched, 30, 2) == 0, "蒙版清理：参数全 0 时蒙版不变")
	var feathered := _op("key.matte_clean", "key.matte_clean", {"image": speckled}, {
		"shrink": 0, "feather": 4, "denoise": 0.0, "view": "matte",
	})
	if feathered != null:
		_check(_alpha(feathered, 16, 8) < 255, "蒙版清理：羽化让边缘变半透明（=%d）" % _alpha(feathered, 16, 8))
		_check(_alpha(feathered, 8, 8) == 255, "蒙版清理：羽化不伤内部")

	# 去溢色：(0,255,0) 的绿被压到 0；强度 0 时不变
	var green := _solid(Color(0, 1, 0))
	var despilled := _op("key.despill", "key.despill", {"image": green}, {
		"strength": 1.0, "mode": "green",
	})
	if despilled != null:
		_check(_pixel(despilled, 4, 4).g < 0.02, "去溢色：绿色通道被压掉（g=%.3f）" % _pixel(despilled, 4, 4).g)
	var kept := _op("key.despill", "key.despill", {"image": green}, {"strength": 0.0})
	if kept != null:
		_check(_bytes_equal(kept, green), "去溢色：强度 0 时逐字节不变")


# ================= 3. 通道 =================

func _test_channels() -> void:
	var split_img := _split(Color(0, 1, 0), Color(1, 0, 0))
	var sample := _solid(Color(0.8, 0.4, 0.2), 0.6)
	var red_only := _op("channel.extract", "channel.extract", {"image": sample}, {"channel": "red"})
	if red_only != null:
		var c := _pixel(red_only, 4, 4)
		_check(absf(c.r - 0.8) < 0.01 and absf(c.g - 0.8) < 0.01, "分离通道：红通道出灰度图")
	var alpha_only := _op("channel.extract", "channel.extract", {"image": sample}, {"channel": "alpha"})
	if alpha_only != null:
		_check(absf(_pixel(alpha_only, 4, 4).r - 0.6) < 0.01, "分离通道：alpha 出灰度图")

	# 合并：R 来自纯红图、G 来自纯绿图 → 得到黄色
	var combined := _op("channel.combine", "channel.combine", {
		"r": _solid(Color(1, 0, 0)), "g": _solid(Color(0, 1, 0)),
		"b": _solid(Color(0, 0, 1)),
	}, {"mode": "red"})
	if combined != null:
		var c := _pixel(combined, 4, 4)
		_check(c.r > 0.98 and c.g < 0.02 and c.b < 0.02, "合并通道：红图充当 R（实际 %.2f,%.2f,%.2f）" % [c.r, c.g, c.b])

	# 通道混合器：只留红（rr=1，其余 0）→ 灰度=原红
	var mixed := _op("channel.mixer", "channel.mixer", {"image": sample}, {
		"rr": 1.0, "rg": 0.0, "rb": 0.0, "gr": 0.0, "gg": 0.0, "gb": 0.0,
		"br": 0.0, "bg": 0.0, "bb": 0.0, "mono": false,
	})
	if mixed != null:
		var c := _pixel(mixed, 4, 4)
		_check(absf(c.r - 0.8) < 0.01 and c.g < 0.02 and c.b < 0.02, "通道混合器：只留红")

	# 设置透明度：用一张全白图当 alpha 源 → 全不透明；全黑 → 全透明
	var transparent := _op("channel.set_alpha", "channel.set_alpha", {
		"image": sample, "source": _solid(Color(0, 0, 0)),
	}, {"channel": "luma", "invert": false})
	var opaque := _op("channel.set_alpha", "channel.set_alpha", {
		"image": sample, "source": _solid(Color(1, 1, 1)),
	}, {"channel": "luma", "invert": false})
	if transparent != null and opaque != null:
		_check(_alpha(transparent, 4, 4) == 0, "设置透明度：黑源 → 全透明")
		_check(_alpha(opaque, 4, 4) == 255, "设置透明度：白源 → 全不透明")

	# 通道错位：红蓝各偏移，绿不动
	var shifted := _op("channel.shift", "channel.shift", {"image": split_img}, {
		"offset": [4, 0], "amount": 1.0,
	})
	if shifted != null:
		_check(not _bytes_equal(shifted, split_img), "通道错位：画面确实变了")
	var still := _op("channel.shift", "channel.shift", {"image": split_img}, {"amount": 0.0})
	if still != null:
		_check(_bytes_equal(still, split_img), "通道错位：强度 0 时逐字节不变")

	# 通道交换：R↔G
	var swapped := _op("channel.swap", "channel.swap", {"image": _solid(Color(0.9, 0.1, 0.0))}, {
		"r_from": "green", "g_from": "red", "b_from": "blue", "a_from": "alpha",
	})
	if swapped != null:
		var c := _pixel(swapped, 4, 4)
		_check(absf(c.r - 0.1) < 0.01 and absf(c.g - 0.9) < 0.01, "通道交换：R 与 G 换了位置")


# ================= 4. 蒙版 =================

func _test_masks() -> void:
	var rect := _op("mask.rect", "mask.rect", {}, {
		"position": [8, 8], "size": [16, 16], "feather": 0.0, "invert": false,
	})
	if rect != null:
		_check(_alpha(rect, 16, 16) == 255, "矩形蒙版：内部不透明")
		_check(_alpha(rect, 2, 2) == 0, "矩形蒙版：外部透明")
	var rect_inv := _op("mask.rect", "mask.rect", {}, {
		"position": [8, 8], "size": [16, 16], "feather": 0.0, "invert": true,
	})
	if rect_inv != null:
		_check(_alpha(rect_inv, 16, 16) == 0 and _alpha(rect_inv, 2, 2) == 255, "矩形蒙版：反相")

	var ellipse := _op("mask.ellipse", "mask.ellipse", {}, {
		"center": [16, 16], "radius": [12, 12], "feather": 0.0,
	})
	if ellipse != null:
		_check(_alpha(ellipse, 16, 16) == 255, "椭圆蒙版：中心不透明")
		_check(_alpha(ellipse, 1, 1) == 0, "椭圆蒙版：角上透明")

	# 布尔：两块矩形相加 / 相减
	var left := _op("mask.rect", "mask.rect", {}, {"position": [0, 8], "size": [16, 16], "feather": 0.0})
	var right := _op("mask.rect", "mask.rect", {}, {"position": [16, 8], "size": [16, 16], "feather": 0.0})
	if left != null and right != null:
		var added := _op("mask.boolean", "mask.boolean", {"a": left, "b": right}, {"mode": "add"})
		var cut := _op("mask.boolean", "mask.boolean", {"a": left, "b": right}, {"mode": "subtract"})
		var both := _op("mask.boolean", "mask.boolean", {"a": left, "b": right}, {"mode": "intersect"})
		if added != null and cut != null and both != null:
			_check(_alpha(added, 4, 16) == 255 and _alpha(added, 28, 16) == 255, "蒙版布尔：相加")
			_check(_alpha(cut, 4, 16) == 255 and _alpha(cut, 28, 16) == 0, "蒙版布尔：相减")
			_check(_alpha(both, 4, 16) == 0, "蒙版布尔：相交（两块不重叠 → 空）")

	# 亮度转蒙版
	var gray := _solid(Color(0.8, 0.8, 0.8))
	var from_luma := _op("mask.from_luma", "mask.from_luma", {"image": gray}, {"black": 0.2, "white": 0.9})
	if from_luma != null:
		var expected := (0.8 - 0.2) / (0.9 - 0.2)
		_check(absf(_pixel(from_luma, 4, 4).r - expected) < 0.02,
			"亮度转蒙版：0.8 亮度重映射成 %.2f（实际 %.2f）" % [expected, _pixel(from_luma, 4, 4).r])

	# 羽化：半径 0 不变；半径大则边缘变软
	var from_luma0 := _op("mask.feather", "mask.feather", {"image": from_luma}, {"radius": 0, "expand": 0})
	if from_luma0 != null and from_luma != null:
		_check(_bytes_equal(from_luma0, from_luma), "蒙版羽化：半径 0 时逐字节不变")

	# 暗角
	var vignette := _op("mask.vignette", "mask.vignette", {}, {"radius": 0.8, "softness": 0.4})
	if vignette != null:
		_check(_alpha(vignette, 16, 16) == 255, "暗角：中心不透明")
		_check(_alpha(vignette, 0, 0) < 40, "暗角：四角变暗")


# ================= 5. 色调分离 =================

func _test_tone() -> void:
	# 灰阶斜坡：量化到 4 级后只应有 4 个可能值
	var ramp := _make(SIZE, func(x: int, _y: int) -> Color:
		var v := float(x) / float(SIZE.x - 1)
		return Color(v, v, v, 1.0)
	)
	var posterized := _op("tone.posterize_pro", "tone.posterize_pro", {"image": ramp}, {
		"levels": 4, "mode": "rgb", "smooth": 0.0, "dither": 0.0, "amount": 1.0,
	})
	if posterized != null:
		var seen := {}
		for x in range(SIZE.x):
			seen[int(round(_pixel(posterized, x, 16).r * 255.0))] = true
		_check(seen.size() <= 4, "色调分离：4 级只留下 ≤4 个值（实际 %d 个）" % seen.size())
	var untouched := _op("tone.posterize_pro", "tone.posterize_pro", {"image": ramp}, {"amount": 0.0})
	if untouched != null:
		_check(_bytes_equal(untouched, ramp), "色调分离：混合 0 时逐字节不变")

	# 调色板：2 级黑/白
	var paletted := _op("tone.palette", "tone.palette", {"image": ramp}, {
		"c1": "#000000", "c2": "#ffffff", "steps": 2, "amount": 1.0, "smooth": 0.0,
	})
	if paletted != null:
		var dark := _pixel(paletted, 2, 16).r
		var bright := _pixel(paletted, 29, 16).r
		_check(dark < 0.05 and bright > 0.95, "调色板：暗端黑、亮端白（%.2f / %.2f）" % [dark, bright])

	# 专业色阶：输入黑白点重映射
	var ramp2 := _op("tone.levels_pro", "tone.levels_pro", {"image": ramp}, {
		"in_black": 0.25, "in_white": 0.75, "gamma": 1.0, "amount": 1.0,
	})
	if ramp2 != null:
		_check(_pixel(ramp2, 0, 16).r < 0.02, "专业色阶：低于黑点被压到 0")
		_check(_pixel(ramp2, 31, 16).r > 0.98, "专业色阶：高于白点被提到 1")

	# 分离色调：阴影染蓝、高光染黄
	var split_result := _op("tone.split_tone", "tone.split_tone", {"image": ramp}, {
		"shadow": "#0000ff", "highlight": "#ffff00", "balance": 0.5, "amount": 1.0,
	})
	if split_result != null:
		var low := _pixel(split_result, 1, 16)
		var high := _pixel(split_result, 30, 16)
		_check(low.b > low.r, "分离色调：暗部偏冷（b=%.2f r=%.2f）" % [low.b, low.r])
		_check(high.r > high.b, "分离色调：亮部偏暖（r=%.2f b=%.2f）" % [high.r, high.b])

	# 曲线：直线 = 原图；反相曲线 = 明暗对调；混合 0 = 逐字节不变；点不够时退化成直线
	var identity := _op("tone.curves", "tone.curves", {"image": ramp}, {
		"points": [[0.0, 0.0], [0.5, 0.5], [1.0, 1.0]], "amount": 1.0,
	})
	if identity != null:
		_check(_bytes_near(identity, ramp, 0.01), "曲线：直线映射逐像素近似等于原图")
	var flipped := _op("tone.curves", "tone.curves", {"image": ramp}, {
		"points": [[0.0, 1.0], [1.0, 0.0]], "amount": 1.0,
	})
	if flipped != null:
		_check(_pixel(flipped, 1, 16).r > 0.9, "曲线：反相把暗端提到亮（%.2f）"
			% _pixel(flipped, 1, 16).r)
		_check(_pixel(flipped, 30, 16).r < 0.1, "曲线：反相把亮端压到暗（%.2f）"
			% _pixel(flipped, 30, 16).r)
	var curve_off := _op("tone.curves", "tone.curves", {"image": ramp}, {
		"points": [[0.0, 0.0], [1.0, 0.0]], "amount": 0.0,
	})
	if curve_off != null:
		_check(_bytes_equal(curve_off, ramp), "曲线：混合 0 时逐字节不变")
	var degenerate := _op("tone.curves", "tone.curves", {"image": ramp}, {
		"points": [[0.5, 0.2]], "amount": 1.0,
	})
	if degenerate != null:
		_check(_bytes_near(degenerate, ramp, 0.01), "曲线：点不足两个时退回直线（不崩、不乱算）")

	# 关键帧插值：曲线参数是点阵，两端点数相同时逐点插值 —— 不是"到下一帧才跳"。
	var curve_track := {"track": [
		[0.0, [[0.0, 0.0], [1.0, 1.0]]],
		[1.0, [[0.0, 1.0], [1.0, 0.0]]],
	], "interp": "linear"}
	var mid_curve: Variant = FxTracks.sample(curve_track, 0.5)
	var mid_ok := mid_curve is Array and (mid_curve as Array).size() == 2
	_check(mid_ok, "曲线关键帧：中点采样出两点曲线")
	if mid_ok:
		var first_point: Array = (mid_curve as Array)[0]
		var last_point: Array = (mid_curve as Array)[1]
		_check(absf(float(first_point[1]) - 0.5) < 0.02 and absf(float(last_point[1]) - 0.5) < 0.02,
			"曲线关键帧：两端插到 0.5（实际 %.2f / %.2f）" % [first_point[1], last_point[1]])

	# 色温：调暖后红升高、蓝降低
	var warm := _op("tone.temperature", "tone.temperature", {"image": _solid(Color(0.5, 0.5, 0.5))}, {
		"temperature": 60.0, "tint": 0.0, "vibrance": 0.0, "saturation": 0.0,
	})
	if warm != null:
		var c := _pixel(warm, 4, 4)
		_check(c.r > c.b, "色温：调暖后红 > 蓝（%.2f / %.2f）" % [c.r, c.b])


# ================= 6. 风格化 =================

func _test_stylize() -> void:
	# 半边黑半边白：边缘检测应在交界处最亮
	var edge_src := _solid(Color(0, 0, 0))
	for x in range(16, 32):
		for y in range(32):
			edge_src.set_pixel(x, y, Color(1, 1, 1))
	var edges := _op("style.find_edges", "style.find_edges", {"image": edge_src}, {
		"strength": 1.0, "mode": "mono",
	})
	if edges != null:
		var at_edge := _pixel(edges, 15, 16).r
		var flat := _pixel(edges, 4, 16).r
		_check(at_edge > 0.5 and flat < 0.05, "查找边缘：交界亮、平坦区黑（%.2f / %.2f）" % [at_edge, flat])

	var embossed := _op("style.emboss", "style.emboss", {"image": edge_src}, {
		"angle": 0.0, "strength": 1.0, "keep_color": false, "amount": 1.0,
	})
	if embossed != null:
		_check(_bytes_near(embossed, edge_src, 0.002) == false, "浮雕：画面确实变了")

	var cartoon := _op("style.cartoon", "style.cartoon", {"image": edge_src}, {
		"levels": 4, "edge_strength": 1.0, "amount": 1.0,
	})
	if cartoon != null:
		_check(cartoon != null, "卡通：出图")

	var halftone := _op("style.halftone", "style.halftone", {"image": _solid(Color(0.5, 0.5, 0.5))}, {
		"cell": 4, "angle": 45.0, "amount": 1.0,
	})
	if halftone != null:
		var seen := {}
		for x in range(0, 16):
			for y in range(0, 16):
				seen[int(round(_pixel(halftone, x, y).r * 255.0))] = true
		_check(seen.size() >= 2, "半调：出现网点（%d 种灰度）" % seen.size())

	var grain := _op("style.grain", "style.grain", {"image": _solid(Color(0.5, 0.5, 0.5))}, {
		"amount": 0.5, "size": 1, "seed": 7,
	})
	if grain != null:
		_check(not _bytes_equal(grain, _solid(Color(0.5, 0.5, 0.5))), "颗粒：画面确实变了")
	var grain_off := _op("style.grain", "style.grain", {"image": _solid(Color(0.5, 0.5, 0.5))}, {
		"amount": 0.0, "size": 1, "seed": 7,
	})
	if grain_off != null:
		_check(_bytes_equal(grain_off, _solid(Color(0.5, 0.5, 0.5))), "颗粒：强度 0 时逐字节不变")


# ================= 6.5 曲线控件（拖点背后的数学） =================

## 控件本身的鼠标交互不好在无头里模拟，但**规范化与采样**是纯函数，必须钉住：
## 它们的输出直接决定"画出来的曲线"和"算出来的 LUT"是不是同一条。
func _test_curve_widget() -> void:
	var script: Script = load("res://plugins/fx.tone/fx_curve_widget.gd")
	var widget: Control = script.new()
	_check(widget != null, "曲线控件可实例化")
	if widget == null:
		return
	# 乱序 + 缺端点的输入：应当排序并把端点钉到 0 / 1。
	var normalized: Array = widget.call("_normalize", [[0.8, 0.9], [0.2, 0.3]])
	_check(normalized.size() == 2, "规范化保留点数")
	_check(absf(float(normalized[0][0])) < 0.001 and absf(float(normalized[1][0]) - 1.0) < 0.001,
		"规范化把端点钉在 0 与 1")
	_check(float(normalized[0][1]) <= float(normalized[1][1]),
		"规范化后点按 x 升序，y 未被改动")
	# 单点输入 → 退化成直线（控件不能变成一条竖线）。
	var single: Array = widget.call("_normalize", [[0.5, 0.5]])
	_check(single.size() == 2, "单点输入退化成两点直线")
	# 采样与算子同规则：线性、区间外取端点。
	widget.set("value", [[0.0, 0.0], [0.5, 0.8], [1.0, 1.0]])
	_check(absf(float(widget.call("_sample_at", 0.25)) - 0.4) < 0.01,
		"控件采样：0.25 落在 0→0.8 的中点（实际 %.2f）" % widget.call("_sample_at", 0.25))
	_check(absf(float(widget.call("_sample_at", 1.5)) - 1.0) < 0.001, "控件采样：区间外取端点")
	# 合批写入：改本地值不该立刻写文档（否则一次拖动 = 几十次换桶）。
	var writes := []
	var batched: Control = script.new()
	batched.set("_ctx", {
		"get": func() -> Variant: return [[0.0, 0.0], [1.0, 1.0]],
		"set": func(v: Variant) -> void: writes.append(v),
	})
	batched.call("set_value", [[0.0, 0.0], [0.5, 0.7], [1.0, 1.0]])
	_check(writes.is_empty(), "曲线控件：拖动中不写文档（合批）")
	batched.call("flush")
	_check(writes.size() == 1, "曲线控件：flush 后只写一次（实际 %d 次）" % writes.size())
	batched.call("set_value", [[0.0, 0.0], [0.4, 0.6], [1.0, 1.0]])
	batched.call("flush")
	_check(writes.size() == 2, "曲线控件：连续两组改动各写一次，不丢")
	batched.free()
	# 控件采样与原生 LUT **逐点对拍**：这是"画的和算的不是一条线"的唯一防线。
	# 注意：这里不能先 free(widget) —— 释放后再比较 `widget == null` 会得到 true，
	# 后面的检查就被静默跳过了（第一次写这段时踩到的坑）。
	_curve_matches_native()
	widget.free()


## 同一组控制点：控件画出来的曲线 vs 原生 tone.curves 实际算出来的值。
## 任何一边私自改规则（钳位范围、插值方式、区间外处理）都会在这里红。
func _curve_matches_native() -> void:
	var points := [[0.0, 0.0], [0.3, 0.55], [0.7, 0.62], [1.0, 1.0]]
	var script: Script = load("res://plugins/fx.tone/fx_curve_widget.gd")
	var widget: Control = script.new()
	widget.set("value", points)
	# 256 级灰阶斜坡：第 i 个像素就是 i/255，正好当 LUT 的输入。
	var ramp := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in range(256):
		var v := float(i) / 255.0
		ramp.set_pixel(i, 0, Color(v, v, v, 1.0))
	var mapped := _op("tone.curves", "tone.curves", {"image": ramp}, {
		"points": points, "amount": 1.0,
	})
	if mapped == null:
		widget.free()
		return
	var worst := 0.0
	for i in range(0, 256, 7):
		var expected := float(widget.call("_sample_at", float(i) / 255.0))
		var actual := _pixel(mapped, i, 0).r
		worst = maxf(worst, absf(expected - actual))
	_check(worst <= 0.02, "控件与算子采样逐点一致（最大差 %.3f）" % worst)
	# 两端越界：控件与算子都要钳在 0..1，谁都不许私自外推。
	var overshoot := _op("tone.curves", "tone.curves", {"image": ramp}, {
		"points": [[0.0, 0.0], [0.5, 1.8], [1.0, 1.0]], "amount": 1.0,
	})
	if overshoot != null:
		var mid := _pixel(overshoot, 128, 0).r
		_check(absf(mid - 1.0) < 0.02, "曲线：y 超 1 被钳到 1（实际 %.2f）" % mid)
	widget.free()


# ================= 7. 整图接线 =================

## 走一遍真正的执行器：节点定义、端口名、算子调用三者必须对得上。
func _test_graph_wiring() -> void:
	var doc := FxGraphDoc.create("AE 插件族接线")
	FxGraphDoc.set_canvas(doc, 64, 64)
	FxGraphDoc.set_timeline(doc, 30, 1.0, false)
	FxGraphDoc.add_node(doc, "image.solid", "src", Vector2(0, 0), {"color": "#22cc55"})
	FxGraphDoc.add_node(doc, "key.chroma_pro", "key", Vector2(220, 0), {"screen": "#22cc55"})
	FxGraphDoc.add_node(doc, "key.matte_clean", "clean", Vector2(440, 0), {"shrink": 1})
	FxGraphDoc.add_node(doc, "mask.vignette", "vig", Vector2(440, 160), {})
	FxGraphDoc.add_node(doc, "mask.boolean", "bool", Vector2(660, 160), {"mode": "intersect"})
	FxGraphDoc.add_node(doc, "channel.extract", "chan", Vector2(660, 0), {"channel": "alpha"})
	FxGraphDoc.add_node(doc, "tone.levels_pro", "levels", Vector2(880, 0), {})
	FxGraphDoc.add_node(doc, "style.grain", "grain", Vector2(1100, 0), {"amount": 0.2})
	FxGraphDoc.add_node(doc, "output.final", "out", Vector2(1320, 0), {
		"layers": [{"name": "合成", "blend": "normal", "opacity": 1.0, "offset": [0, 0], "visible": true}],
	})
	doc["output"] = "out"
	var links := [
		["src", "image", "key", "image"],
		["key", "image", "clean", "image"],
		["clean", "image", "chan", "image"],
		["vig", "image", "bool", "a"],
		["clean", "image", "bool", "b"],
		["chan", "image", "levels", "image"],
		["levels", "image", "grain", "image"],
		["grain", "image", "out", "layer_0"],
	]
	var link_ok := true
	for link in links:
		var err := FxGraphDoc.connect_ports(doc, String(link[0]), String(link[1]),
			String(link[2]), String(link[3]))
		if err != FxGraphDoc.LINK_OK:
			link_ok = false
			_push("连线失败：%s → %s（%d）" % [link[0], link[2], err])
	_check(link_ok, "五个插件的节点能按预期接线")
	var result: Dictionary = FxGraphRunner.new().run(doc, 0.0)
	var image: Variant = result.get("image")
	_check(image is Image, "整图求值出图")
	_check((result.get("warnings", []) as Array).is_empty(),
		"整图求值没有告警（%s）" % str(result.get("warnings", [])))
	if image is Image:
		_check((image as Image).get_width() == 64, "输出尺寸跟随画布")


# ================= 工具 =================

func _op(type_id: String, _op_id: String, inputs: Dictionary, params: Dictionary) -> Image:
	var def: FxNodeDef = FxCatalog.def(type_id)
	if def == null:
		_push("节点定义缺失：%s" % type_id)
		return null
	var merged := def.default_params()
	for key in params.keys():
		merged[key] = params[key]
	var ctx := FxEvalContext.new()
	ctx.canvas = SIZE
	var callable := FxOpRegistry.get_op(def.op)
	if not callable.is_valid():
		_push("算子缺失：%s" % type_id)
		return null
	var result: Variant = callable.call(ctx, {}, def, inputs, merged)
	if not (result is Dictionary):
		_push("算子没有返回字典：%s" % type_id)
		return null
	var image: Variant = (result as Dictionary).get("image")
	if not image is Image:
		_push("算子没有返回图像：%s" % type_id)
		return null
	return image as Image


## 纯色图。**alpha 默认 1**：`Color(0,0,0)` 自带 a=0，
## 拿它当"黑色"用会得到一张全透明的图，测试结果就与意图相反了。
func _solid(color: Color, alpha: float = 1.0) -> Image:
	var filled := Color(color.r, color.g, color.b, alpha)
	return _make(SIZE, func(_x: int, _y: int) -> Color: return filled)


func _split(left: Color, right: Color) -> Image:
	return _make(SIZE, func(x: int, _y: int) -> Color: return left if x < SIZE.x / 2 else right)


func _make(size: Vector2i, fn: Callable) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in range(size.y):
		for x in range(size.x):
			image.set_pixel(x, y, fn.call(x, y))
	return image


func _pixel(image: Image, x: int, y: int) -> Color:
	return image.get_pixel(clampi(x, 0, image.get_width() - 1),
		clampi(y, 0, image.get_height() - 1))


func _alpha(image: Image, x: int, y: int) -> int:
	return int(round(_pixel(image, x, y).a * 255.0))


func _near(a: Color, b: Color, tolerance: float = 0.02) -> bool:
	return absf(a.r - b.r) < tolerance and absf(a.g - b.g) < tolerance \
		and absf(a.b - b.b) < tolerance


func _bytes_equal(a: Image, b: Image) -> bool:
	if a == null or b == null:
		return false
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return false
	return a.get_data() == b.get_data()


func _bytes_near(a: Image, b: Image, tolerance: float) -> bool:
	if a == null or b == null:
		return false
	var da := a.get_data()
	var db := b.get_data()
	if da.size() != db.size():
		return false
	for i in range(da.size()):
		if absf(float(da[i]) - float(db[i])) > tolerance * 255.0:
			return false
	return true


func _check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  ok %s" % message)
	else:
		failures.append(message)
		print("  FAIL: %s" % message)


func _push(message: String) -> void:
	failures.append(message)
	print("  FAIL: %s" % message)


func _quit(code: int) -> void:
	quit(code)
