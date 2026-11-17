extends SceneTree
## 单帧成本归属：谁吃了这 600ms。
##
## 关键点：`ctx.timings` 只留每个节点的**最后一次**耗时，循环体里被重复求值的
## 节点会被严重低估（`flow.for` × N）。这里用累加值 `timing_totals` + `op_calls`，
## 才能回答「这帧的钱花在谁身上」。
##
## 运行：godot --headless --path . --script res://tests/_profile_frame.gd

const PROJ := "res://examples/demo/示范工程.fxproj"


func _initialize() -> void:
	FxPluginHost.ensure()
	FxCatalog.ensure_loaded()
	var loaded := FxProjectArchive.read_zip(PROJ)
	var doc: Dictionary = loaded.get("doc", {}) as Dictionary
	if doc.is_empty():
		print("读不到示范工程")
		quit(1)
		return
	print("== 单帧成本归属 ==（%s，%d 节点）" % [str(FxGraphDoc.canvas(doc)),
		(doc.get("nodes", []) as Array).size()])

	var runner := FxGraphRunner.new()
	runner.static_cache_enabled = false
	runner.capture_previews = true
	runner.preview_limit = 128
	# 预热一次（shader 编译），不计入。
	runner.run(doc, 0.0)

	var fresh := FxGraphRunner.new()
	fresh.static_cache_enabled = false
	fresh.capture_previews = true
	fresh.preview_limit = 128
	var start := Time.get_ticks_usec()
	var result := fresh.run(doc, 0.5)
	var frame_ms := float(Time.get_ticks_usec() - start) / 1000.0
	var stats: Dictionary = result.get("stats", {})
	print("  整帧 %.2f ms · steps=%s · 求值节点 %s" % [frame_ms,
		str(stats.get("steps", "?")), str(stats.get("nodes", "?"))])

	var ctx := fresh.ctx
	var totals: Dictionary = ctx.timing_totals
	var calls: Dictionary = ctx.op_calls
	# 子图内部项（键带 "/"）已经包含在 `graph.subgraph` 那一项里，
	# 直接相加会算出 100% 以上的占比。所以它们单独列，只用来定位。
	var op_sum := 0.0
	var call_sum := 0
	var nested_sum := 0.0
	for key in totals.keys():
		if String(key).contains("/"):
			nested_sum += float(totals[key])
			continue
		op_sum += float(totals[key])
		call_sum += int(calls.get(key, 0))
	print("  算子累计 %.2f ms（占 %.1f%%）· 调用 %d 次 · 平均 %.2f ms/次" % [
		op_sum, op_sum / maxf(frame_ms, 0.01) * 100.0, call_sum,
		op_sum / maxf(float(call_sum), 1.0)])
	print("  框架/其它 %.2f ms" % maxf(frame_ms - op_sum, 0.0))
	print("  行并行       %d 次 · 串行 %d 次 · 上次切 %d 块" % [
		FxPixelParallel.parallel_calls, FxPixelParallel.serial_calls,
		FxPixelParallel.last_threads])

	var rows: Array = []
	for key in totals.keys():
		var node_data: Dictionary = FxGraphDoc.node(doc, key)
		rows.append({
			"id": String(key),
			"type": String(node_data.get("type", "?")),
			"ms": float(totals[key]),
			"calls": int(calls.get(key, 0)),
		})
	if nested_sum > 0.0:
		print("  子图内部合计 %.2f ms（已含在 graph.subgraph 里，不计入上面的占比）" % nested_sum)
	rows.sort_custom(func(a, b): return float(a["ms"]) > float(b["ms"]))
	print("  ── 累计耗时前 15 ──")
	for i in range(mini(15, rows.size())):
		var row: Dictionary = rows[i]
		print("  %2d %8.2f ms  %-22s %-20s ×%d" % [i + 1, float(row["ms"]),
			String(row["type"]), String(row["id"]), int(row["calls"])])

	# 按类型聚合：改一个算子的实现，能省多少是看这一列，不是看单个节点。
	var by_type := {}
	for row in rows:
		var t := String(row["type"])
		by_type[t] = float(by_type.get(t, 0.0)) + float(row["ms"])
	var type_rows: Array = []
	for key in by_type.keys():
		type_rows.append({"type": key, "ms": float(by_type[key])})
	type_rows.sort_custom(func(a, b): return float(a["ms"]) > float(b["ms"]))
	print("  ── 按算子类型 ──")
	for i in range(mini(12, type_rows.size())):
		var row: Dictionary = type_rows[i]
		print("  %2d %8.2f ms  %-22s %.1f%%" % [i + 1, float(row["ms"]),
			String(row["type"]), float(row["ms"]) / maxf(frame_ms, 0.01) * 100.0])

	FxPluginHost.shutdown()
	quit(0)
