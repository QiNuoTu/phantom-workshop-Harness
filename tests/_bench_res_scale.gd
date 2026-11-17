extends SceneTree
## 实测：逐层分辨率档到底省多少。
##
## 口径（三个都踩过，写下来）：
##   · 用示范工程，但**改画布尺寸**跑多组：192×108 太小，像素成本被调度开销淹没，
##     测出来只会是噪声（和上一轮预览管线一样）。
##   · 必须预热：示范工程含 shader 节点，首轮要编译 shader（约 0.8 s），
##     不预热第一组永远被污染。
##   · `static_cache_enabled = false`：量的是「算一帧」，不是「命中缓存」。
##
## 运行（要开窗）：godot --path . --script res://tests/_bench_res_scale.gd

const PROJ := "res://examples/demo/示范工程.fxproj"
const RUNS := 2


func _initialize() -> void:
	var doc: Dictionary = {}
	var loaded: Dictionary = FxProjectArchive.read_zip(PROJ)
	var inner: Variant = loaded.get("doc")
	if inner is Dictionary:
		doc = inner
	if doc.is_empty():
		print("读不到示范工程：%s（%s）" % [PROJ, str(loaded.get("message", ""))])
		quit(1)
		return
	print("== 逐层分辨率档实测 ==")
	print("节点 %d · 原画布 %s" % [(doc.get("nodes", []) as Array).size(),
		str(FxGraphDoc.canvas(doc))])
	var roots := _preview_roots(doc)

	for size in [192, 512]:
		var base := _resize_canvas(doc, size)
		print("-- 画布 %dx%d --" % [size, size])
		_measure(base, roots, {}, 1)   # 预热
		var full := _measure(base, roots, {}, RUNS)
		var half := _measure(base, roots, {"all": 0.5}, RUNS)
		var quarter := _measure(base, roots, {"all": 0.25}, RUNS)
		print("  A 全分辨率            %8.2f ms" % full)
		print("  B 全图 0.5 档          %8.2f ms  (%+.1f%%)"
			% [half, (half - full) / maxf(full, 0.01) * 100.0])
		print("  C 全图 0.25 档         %8.2f ms  (%+.1f%%)"
			% [quarter, (quarter - full) / maxf(full, 0.01) * 100.0])
		if full > 0.01:
			print("  0.5 档相对全分辨率    %.2fx 速度" % (full / maxf(half, 0.01)))
			print("  0.25 档相对全分辨率   %.2fx 速度" % (full / maxf(quarter, 0.01)))
	quit(0)


## 给除「输出节点 / 汇点」外的所有节点打档位。
## 这就是「整张图按该档求值、只有最后一帧回到全尺寸」的上限场景。
func _apply_scale(doc: Dictionary, scale: float) -> Dictionary:
	var copy := doc.duplicate(true)
	var output := FxGraphDoc.output_id(copy)
	for item in copy.get("nodes", []):
		var node_data: Dictionary = item
		var id := String(node_data.get("id", ""))
		if id == output:
			continue
		var def := FxCatalog.def(node_data.get("type", ""))
		if def != null and def.evaluate_always:
			continue
		node_data["res_scale"] = scale
	return copy


func _resize_canvas(doc: Dictionary, size: int) -> Dictionary:
	var copy := doc.duplicate(true)
	var meta: Dictionary = copy.get("meta", {})
	var canvas: Dictionary = meta.get("canvas", {})
	canvas["width"] = size
	canvas["height"] = size
	meta["canvas"] = canvas
	copy["meta"] = meta
	return copy


func _preview_roots(doc: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for item in doc.get("nodes", []):
		if out.size() >= 8:
			break
		out.append(String((item as Dictionary).get("id", "")))
	return out


func _measure(doc: Dictionary, roots: Array[String], scales: Dictionary,
		runs: int = RUNS) -> float:
	var target := doc
	if scales.has("all"):
		target = _apply_scale(doc, float(scales["all"]))
	var total := 0.0
	for i in range(maxi(runs, 1)):
		var runner := FxGraphRunner.new()
		runner.quality = 1
		runner.capture_previews = true
		runner.preview_limit = 128
		runner.static_cache_enabled = false
		runner.preview_roots = roots
		var focus := {}
		for id in roots:
			focus[id] = true
		runner.preview_nodes = focus
		var start := Time.get_ticks_usec()
		runner.run(target, 0.5)
		total += float(Time.get_ticks_usec() - start) / 1000.0
	return total / float(maxi(runs, 1))
