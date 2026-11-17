extends SceneTree
## 实测：节点小图这条独立管线到底省在哪。
##
## 口径说明（第一次写错过，记下来）：
##   `capture_previews=false` **不是**「只算输出」——关掉捕获后预览根不再算作求值根，
##   实际求值集合会变成输出链，和「抓小图」根本不是同一批节点，两者不可比。
##   所以这里三组都**开着捕获、同根求值**，只改一个变量：
##     A 小图边长 16（几乎不占像素）  → 相当于「没有小图」的成本基线
##     B 小图边长 128（默认）         → B−A = 缩放+拷贝的代价
##     C 小图边长 128 + 算子 0.5      → C−B = 小图算子档的影响
## 运行（要开窗：示范工程含 shader 节点，无头跑不了）：
##   godot --path . --script res://tests/_bench_preview.gd

const PROJ := "res://examples/demo/示范工程.fxproj"
const RUNS := 5


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
	var roots := _preview_roots(doc)
	print("== 预览管线实测（%s）==" % PROJ)
	print("节点 %d · 预览根 %d · 画布 %s" % [
		(doc.get("nodes", []) as Array).size(), roots.size(), str(FxGraphDoc.canvas(doc))])

	# 预热：示范工程含 shader 节点，第一次求值要编译 shader（约 0.8 s）。
	# 不预热的话「第一组」永远被这 0.8 s 污染，看着像「边长 16 比 128 慢一倍」——
	# 第一次跑就被这个假象骗过一次，写进注释免得下一个人再踩。
	_measure(doc, roots, 128, 1.0, 1)
	var tiny := _measure(doc, roots, 16, 1.0)
	var full := _measure(doc, roots, 128, 1.0)
	var cheap := _measure(doc, roots, 128, 0.5)
	print("  A 边长 16（≈无小图）    %8.2f ms" % tiny)
	print("  B 边长 128 · 算子 1.0   %8.2f ms" % full)
	print("  C 边长 128 · 算子 0.5   %8.2f ms" % cheap)
	if tiny > 0.01:
		print("  小图缩放+拷贝的代价   %+.1f%%（B 相对 A）"
			% ((full - tiny) / tiny * 100.0))
	if full > 0.01:
		print("  小图算子档 1.0→0.5    %+.1f%%（C 相对 B）"
			% ((cheap - full) / full * 100.0))
	# 第二组：把画布放大到 512²，看「小图代价随像素涨」这条趋势。
	# 这不是基准工程的原尺寸，只用来回答「大画布上这个旋钮值不值」。
	var big := doc.duplicate(true)
	var meta: Dictionary = big.get("meta", {})
	var canvas: Dictionary = meta.get("canvas", {})
	canvas["width"] = 512
	canvas["height"] = 512
	meta["canvas"] = canvas
	big["meta"] = meta
	var big_roots := _preview_roots(big)
	_measure(big, big_roots, 128, 1.0, 1)
	var b_tiny := _measure(big, big_roots, 16, 1.0, 3)
	var b_full := _measure(big, big_roots, 128, 1.0, 3)
	var b_cheap := _measure(big, big_roots, 128, 0.5, 3)
	print("-- 画布放大到 512x512（趋势参考，非基准）--")
	print("  A 边长 16              %8.2f ms" % b_tiny)
	print("  B 边长 128 · 算子 1.0   %8.2f ms" % b_full)
	print("  C 边长 128 · 算子 0.5   %8.2f ms" % b_cheap)
	if b_tiny > 0.01:
		print("  小图缩放+拷贝的代价   %+.1f%%（B 相对 A）"
			% ((b_full - b_tiny) / b_tiny * 100.0))
	if b_full > 0.01:
		print("  小图算子档 1.0→0.5    %+.1f%%（C 相对 B）"
			% ((b_cheap - b_full) / b_full * 100.0))
	quit(0)


## 取前 8 个节点当预览根：够代表「旁支也要出小图」的成本，又不至于把 103 个全开。
func _preview_roots(doc: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for item in doc.get("nodes", []):
		if out.size() >= 8:
			break
		out.append(String((item as Dictionary).get("id", "")))
	return out


func _measure(doc: Dictionary, roots: Array[String], limit: int, operator: float,
		runs: int = RUNS) -> float:
	var total := 0.0
	for i in range(runs):
		var runner := FxGraphRunner.new()
		runner.quality = 1
		runner.operator_quality = operator
		runner.capture_previews = true
		runner.preview_limit = limit
		runner.static_cache_enabled = false   # 量「算一帧」，不是「命中缓存」
		runner.preview_roots = roots
		var focus := {}
		for id in roots:
			focus[id] = true
		runner.preview_nodes = focus
		var start := Time.get_ticks_usec()
		runner.run(doc, 0.5)
		total += float(Time.get_ticks_usec() - start) / 1000.0
	return total / float(maxi(runs, 1))
