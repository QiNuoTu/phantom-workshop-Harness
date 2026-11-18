extends SceneTree
## 重操作预算门禁：28 个原生算子逐个计时，超预算就是失败。
##
## 为什么要有这道门禁：项目的硬规则是**「192×108 下一格几毫秒，做不到就进 GDExtension」**。
## 规则写在文档里没有用 —— 得有一条命令能在改完代码后回答「现在还是几毫秒吗」。
## 这条命令就是它：拿着真实参数、真实尺寸跑，超了就红。
##
## 口径（也是 docs/性能口径.md 记的那份）：
##   · 参考画布 192×108 —— 与示范工程一致，这是所有"能不能用"的判断基准；
##   · 512×512 —— 单张大图的上限场景，用来防止"小图很快、大图爆炸"；
##   · 每个算子取 **5 次里的最小值**：调度抖动只会变慢，最小值才代表这格的真实成本；
##   · 输入是一张带噪点的渐变图（不是纯色）：纯色会让分支预测过于友好。
##
## 预算（两条，同时成立）：
##   · 参考画布 192×108 下每格 ≤ 3 ms —— 「几毫秒」这句话的可执行版本；
##   · 每像素 ≤ 135 ns —— 尺度无关的那一条。512×512 的像素是 192×108 的 12.6 倍，
##     所以大图预算是 3 ms × 12.6 ≈ 38 ms；写死一个 20 ms 只会逼人写特例。
## 超了不许"调大阈值"：要么优化，要么这条链就不该用逐像素实现。
##
## 运行：godot --headless --path . --script res://tests/test_fx_budget.gd

const SMALL := Vector2i(192, 108)
const LARGE := Vector2i(512, 512)
## 192×108 下每个算子的上限（毫秒）。"几毫秒"取 3。
const BUDGET_SMALL := 3.0
## 尺度无关的上限：每像素纳秒。192×108 的 3 ms 就是 ~145 ns/px，留一点余量取 135。
const BUDGET_NS_PER_PX := 135.0
const RUNS := 5

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	print("== 原生算子预算 ==")
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	var small := _sample(SMALL)
	var large := _sample(LARGE)
	var rows: Array[Dictionary] = []
	for type_id in _types():
		var def: FxNodeDef = FxCatalog.def(type_id)
		_check(def != null, "节点定义存在：%s" % type_id)
		if def == null:
			continue
		var op := FxOpRegistry.get_op(def.op)
		_check(op.is_valid(), "%s 的算子已绑定" % type_id)
		if not op.is_valid():
			continue
		var ms_small := _time(op, def, small, SMALL)
		var ms_large := _time(op, def, large, LARGE)
		rows.append({"type": type_id, "small": ms_small, "large": ms_large})
		if ms_small > BUDGET_SMALL:
			_push("%s 在 192×108 下 %.2f ms，超预算 %.1f ms（要么优化，要么这条链不该逐像素）"
				% [type_id, ms_small, BUDGET_SMALL])
		var ns_per_px := ms_large * 1000000.0 / float(LARGE.x * LARGE.y)
		if ns_per_px > BUDGET_NS_PER_PX:
			_push("%s 每像素 %.0f ns，超预算 %.0f ns/px（512×512 实测 %.2f ms）"
				% [type_id, ns_per_px, BUDGET_NS_PER_PX, ms_large])
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("small", 0.0)) > float(b.get("small", 0.0))
	)
	print("%-22s %10s %10s" % ["节点", "192×108", "512×512"])
	var total_small := 0.0
	for row in rows:
		total_small += float(row["small"])
		print("%-22s %8.3f ms %8.3f ms" % [String(row["type"]), float(row["small"]),
			float(row["large"])])
	print("----")
	print("最慢 %.3f ms · %d 个算子合计 %.2f ms（参考画布）" % [
		float(rows[0]["small"]) if not rows.is_empty() else 0.0, rows.size(), total_small])
	print("断言 %d 条" % checks)
	if failures.is_empty():
		print("预算门禁通过：每个算子都在几毫秒以内")
		FxPluginHost.shutdown()
		quit(0)
	else:
		print("超预算 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		FxPluginHost.shutdown()
		quit(1)


## 28 个节点类型（与 test_fx_ae_pack 的目录契约同一份清单）。
func _types() -> Array[String]:
	return [
		"key.chroma_pro", "key.luma", "key.diff", "key.color_range", "key.matte_clean",
		"key.despill",
		"channel.extract", "channel.combine", "channel.mixer", "channel.set_alpha",
		"channel.shift", "channel.swap",
		"mask.rect", "mask.ellipse", "mask.boolean", "mask.from_luma", "mask.feather",
		"mask.vignette",
		"tone.posterize_pro", "tone.palette", "tone.levels_pro", "tone.split_tone",
		"tone.temperature", "tone.curves",
		"style.find_edges", "style.emboss", "style.cartoon", "style.halftone", "style.grain",
	]


## 真实一点的输入：对角渐变 + 噪点 + 一圈高光，避免"纯色让分支预测占便宜"。
func _sample(size: Vector2i) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in range(size.y):
		for x in range(size.x):
			var u := float(x) / float(maxi(size.x - 1, 1))
			var v := float(y) / float(maxi(size.y - 1, 1))
			var noise := float((x * 37 + y * 17) % 23) / 23.0 * 0.12
			var d := Vector2(u - 0.5, v - 0.5).length()
			var ring := 1.0 if absf(d - 0.3) < 0.05 else 0.0
			image.set_pixel(x, y, Color(clampf(u + noise, 0.0, 1.0),
				clampf(v + ring * 0.4, 0.0, 1.0), clampf(0.5 + noise, 0.0, 1.0), 1.0))
	return image


## 每个算子的输入：按定义里声明的端口全给上同一张图（`mask.*` 生成类没有输入也给）。
func _inputs(def: FxNodeDef, image: Image) -> Dictionary:
	var out := {}
	for port in def.inputs:
		out[String((port as Dictionary).get("id", ""))] = image
	if out.is_empty():
		out["image"] = image
	return out


func _time(op: Callable, def: FxNodeDef, image: Image, size: Vector2i) -> float:
	var ctx := FxEvalContext.new()
	ctx.canvas = size
	var params: Dictionary = def.default_params()
	var inputs := _inputs(def, image)
	var best := 1.0e9
	for _i in range(RUNS):
		var started := Time.get_ticks_usec()
		var result: Variant = op.call(ctx, {}, def, inputs, params)
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		if not (result is Dictionary) or not ((result as Dictionary).get("image") is Image):
			_push("%s 没有返回图像" % String(def.id))
			return 0.0
		best = minf(best, elapsed)
	return best


func _check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  ok %s" % message)
	else:
		_push(message)


func _push(message: String) -> void:
	failures.append(message)
	print("  FAIL: %s" % message)
