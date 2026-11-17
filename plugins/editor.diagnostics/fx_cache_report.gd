class_name FxCacheReport
extends RefCounted
## 帧缓存归因：回答「**谁**在重建缓存、重建了几次、值不值」。
##
## 为什么单独一个命令而不是塞进 diag.blame：
##   diag.blame 查的是**结构**（谁引用了谁、谁的贡献缺了），是静态事实；
##   这里查的是**运行时行为**（一次操作里桶被重建了几回），是动态事实。
##   两者的数据来源与失效方式都不同，混在一起会让「归因」变成一锅粥。
##
## 数据只走两条公开契约：
##   · `FxRenderHost.cache_trace()` —— 呈现器自己记录的重建/变更事件（本插件不认识它）；
##   · `FxRegistry.settings` —— 每个设置项声明的 `impact`（影响面）。
## 因此停用 `core.render` 时本命令照样能跑：它只会报「没有呈现器，没有可查的重建」。
##
## 用法：
##   godot --headless --path . -- --fx-diagnose --fx-run=diag.cache
##   godot --headless --path . -- --fx-run=diag.cache --fx-arg=reset   （先清空再统计）

## 报告里最多列多少条明细：再多也看不出新东西，反而把关键几条挤到屏幕外。
const SHOW_LIMIT := 12

const IMPACT_LABEL := {
	"content": "像素内容",
	"derived": "派生缓存",
	"display": "仅显示",
	"none": "不碰渲染",
}


static func cmd_report(ctx: Dictionary) -> void:
	var args: Array = ctx.get("args", [])
	if args.has("reset"):
		var host: Variant = ctx.get("render")
		if host != null and host.has_method("cache_reset_trace"):
			host.call("cache_reset_trace")
	var data := report(ctx)
	print(render(data))
	_push_status(ctx, data)


static func report(ctx: Dictionary = {}) -> Dictionary:
	var host: Variant = ctx.get("render")
	var trace: Array = []
	var available: bool = host != null and host.has_method("cache_trace")
	if available:
		var raw: Variant = host.call("cache_trace")
		if raw is Array:
			trace = raw
	var buckets: Array = []
	var skips: Array = []
	var changes: Array = []
	var invalidates: Array = []
	for raw in trace:
		var item: Dictionary = raw
		match String(item.get("kind", "")):
			"bucket": buckets.append(item)
			"bucket-skip": skips.append(item)
			"change": changes.append(item)
			"invalidate": invalidates.append(item)
	var by_reason := {}
	for raw in buckets:
		var reason := String((raw as Dictionary).get("reason", "?"))
		by_reason[reason] = int(by_reason.get(reason, 0)) + 1
	var by_gate := {}
	for raw in changes:
		var gate := String((raw as Dictionary).get("gate", "?"))
		by_gate[gate] = int(by_gate.get(gate, 0)) + 1
	var by_tier := {}
	for raw in invalidates:
		var tier := String((raw as Dictionary).get("tier", "content"))
		by_tier[tier] = int(by_tier.get(tier, 0)) + 1
	return {
		"available": available,
		"trace_size": trace.size(),
		"buckets": buckets,
		"skips": skips,
		"changes": changes,
		"invalidates": invalidates,
		"by_reason": by_reason,
		"by_gate": by_gate,
		"by_tier": by_tier,
		"impacts": _impact_table(),
		"pipeline": _pipeline(host, available),
		"findings": _verdicts(buckets, skips, changes, invalidates),
	}


## 两条预览管线的参数。呈现器认这个查询就报，不认就空着 ——
## 诊断插件不认识 FxRenderService 这个类名，只认方法名。
static func _pipeline(host: Variant, available: bool) -> Dictionary:
	if not available or host == null or not host.has_method("preview_pipeline_config"):
		return {}
	var raw: Variant = host.call("preview_pipeline_config")
	return raw if raw is Dictionary else {}


## 设置影响面统计：谁声明了什么，有没有漏声明。
static func _impact_table() -> Dictionary:
	var counts := {}
	var undecided: Array[String] = []
	var rows: Array[Dictionary] = []
	for raw in FxRegistry.settings:
		var def: Dictionary = raw
		var id := String(def.get("id", ""))
		if id.is_empty():
			continue
		var kind := FxSettings.impact_from(def)
		counts[kind] = int(counts.get(kind, 0)) + 1
		# `runtime` 却没写 impact：不是错，但意味着它退回了「最贵的那一档」。
		if not def.has("impact") and String(def.get("applies", "runtime")) == "runtime":
			undecided.append(id)
		rows.append({"id": id, "impact": kind, "applies": String(def.get("applies", "runtime")),
			"owner": String(def.get("owner", ""))})
	return {"counts": counts, "undecided": undecided, "rows": rows}


## 判定。只写「从数字能直接读出来」的结论，不猜动机。
static func _verdicts(buckets: Array, skips: Array, changes: Array,
		invalidates: Array = []) -> Array:
	var out: Array = []
	if not buckets.is_empty():
		# 同一批内容的反复重建：分段哈希完全相同，说明像素内容没动，动的是 fps/duration。
		var same_parts := 0
		var meta_only := 0
		var nodes_moved := 0
		for raw in buckets:
			var item: Dictionary = raw
			var before: Dictionary = item.get("parts_before", {})
			var after: Dictionary = item.get("parts_after", {})
			if before.is_empty() or after.is_empty():
				continue
			if before == after:
				same_parts += 1
			elif before.get("nodes") != after.get("nodes") or before.get("edges") != after.get("edges"):
				nodes_moved += 1
			else:
				meta_only += 1
		if same_parts > 0:
			out.append({
				"level": "error", "title": "内容分段没变却重建了 %d 次" % same_parts,
				"hint": "节点、连线、meta 三段哈希都一样，只有 fps/时长不同 —— 查时间轴字段是不是被反复写回同值。",
			})
		if meta_only > 0:
			out.append({
				"level": "warn", "title": "%d 次重建只动了 meta 段" % meta_only,
				"hint": "meta 里有画布与时间轴；若只是视图态（缩放/选中/播放头）混进了 meta，它就不该参与指纹。",
			})
		if nodes_moved > 0:
			# 顺手把「谁变的」带出来：只报「改了图」等于没报，
			# 定位还得再跑一遍，把归因做成一次性结论。
			var sample: Array[String] = []
			for raw in buckets:
				var item: Dictionary = raw
				var before: Dictionary = item.get("parts_before", {})
				var after: Dictionary = item.get("parts_after", {})
				if before.is_empty() or after.is_empty():
					continue
				if before.get("nodes") != after.get("nodes") or before.get("edges") != after.get("edges"):
					sample = _detail_diff(item.get("detail_before", {}), item.get("detail_after", {}))
			var hint := "这是真内容变化，重建是必要的；要省的是「同样的改动被拆成多次写入」。"
			if not sample.is_empty():
				hint += " 最近一次变的是：%s。" % " · ".join(PackedStringArray(sample))
			out.append({
				"level": "info", "title": "%d 次重建确实改了图/连线" % nodes_moved,
				"hint": hint,
			})
		# 静默写入：指纹变了，修订号却没变 —— 说明有人直接改了文档字典，
		# 绕过了 mutate()/attach()。这类改动不会通知任何订阅者，
		# 表现就是「我没动，缓存却换了、预览空了一下」。
		var silent := 0
		var silent_names: Array[String] = []
		for raw in buckets:
			var item: Dictionary = raw
			if not bool(item.get("silent", false)):
				continue
			silent += 1
			if silent_names.is_empty():
				silent_names = _detail_diff(item.get("detail_before", {}), item.get("detail_after", {}))
		if silent > 0:
			var silent_hint := "修订号没变、内容指纹却变了：有代码直接改了文档字典，绕过了 mutate()/attach()。" \
				+ "这类写入不会通知订阅者，界面上表现为「什么都没做，缓存却重建了」。"
			if not silent_names.is_empty():
				silent_hint += " 最近一次改的是：%s。" % " · ".join(PackedStringArray(silent_names))
			out.append({
				"level": "error", "title": "%d 次内容变化没走变更通知" % silent,
				"hint": silent_hint,
			})
		var by_reason := {}
		for raw in buckets:
			var reason := String((raw as Dictionary).get("reason", "?"))
			by_reason[reason] = int(by_reason.get(reason, 0)) + 1
		var worst := ""
		var worst_n := 0
		for key in by_reason.keys():
			if int(by_reason[key]) > worst_n:
				worst = String(key)
				worst_n = int(by_reason[key])
		if not worst.is_empty():
			out.append({
				"level": "info", "title": "最频繁的重建来源：%s（%d 次）" % [_reason_label(worst), worst_n],
				"hint": "改法是让上位写入合并（一次拖拽只提交一次），而不是让定桶更懒。",
			})
	if buckets.is_empty() and changes.is_empty() and invalidates.is_empty():
		out.append({"level": "info", "title": "没有记录到任何重建或变更",
			"hint": "刚带 --fx-arg=reset 跑过、或这段时间确实没操作，都是这个结果。"
				+ "想看实际行为：先 reset，在界面里做一段操作，再不带 reset 跑一次。"})
	if skips.size() > buckets.size() * 4 and skips.size() > 8:
		out.append({"level": "warn",
			"title": "定桶被反复触发但没换桶（%d 次跳过 / %d 次重建）" % [skips.size(), buckets.size()],
			"hint": "每次都进了 prepare 才发现指纹没变 —— 说明「脏」标志被置得太勤，该在置脏那侧收紧。"})
	if not invalidates.is_empty():
		out.append_array(_invalidate_verdicts(invalidates, buckets))
	return out


## 失效请求的判定：**档位报高了**比「次数多」更值得报。
## 判据是计数对比而不是因果推断：content 档请求次数多于真实换桶次数，
## 就说明有失效请求并没有改变内容身份 —— 那部分是白付的代价。
static func _invalidate_verdicts(invalidates: Array, buckets: Array) -> Array:
	var out: Array = []
	var content_requests := 0
	var by_source := {}
	for raw in invalidates:
		var item: Dictionary = raw
		if String(item.get("tier", "content")) == "content":
			content_requests += 1
		var source := String(item.get("source", ""))
		if source.is_empty():
			source = "（文档变更）"
		by_source[source] = int(by_source.get(source, 0)) + 1
	if content_requests > buckets.size():
		out.append({
			"level": "warn",
			"title": "content 档失效 %d 次，实际换桶 %d 次" % [content_requests, buckets.size()],
			"hint": "多出来的请求并没有改变内容身份：调用方把档位报高了（该用 derived / display / none），"
				+ "或同一改动用多次写入拆开了。",
		})
	var noisy: Array[String] = []
	for key in by_source.keys():
		if int(by_source[key]) >= 3:
			noisy.append("%s ×%d" % [String(key), int(by_source[key])])
	if not noisy.is_empty():
		noisy.sort()
		out.append({
			"level": "info",
			"title": "重复失效的来源：%s" % ", ".join(PackedStringArray(noisy)),
			"hint": "同一个来源连续失效通常是「拖滑块/批量写回逐次提交」。应在写入侧合并成一次，"
				+ "而不是让失效侧去猜哪次算数。",
		})
	return out


static func _reason_label(reason: String) -> String:
	match reason:
		"param": return "改参数"
		"tick": return "0.25s 巡检"
		"archive": return "归档时补桶"
		"preview": return "缩略图趟"
		"prefetch": return "预渲染启动"
		"draft": return "草稿趟"
		"play": return "按播放时定桶"
		"boot": return "启动"
	# 插件不要写死别人的枚举：不认识就原样报出来。
	return reason


static func render(data: Dictionary = {}) -> String:
	var info := data if not data.is_empty() else report()
	var lines: Array[String] = []
	lines.append("== 帧缓存归因 ==")
	lines.append("采样 %d 条（桶重建 %d · 空转 %d · 失效请求 %d · 变更通知 %d）" % [
		int(info.get("trace_size", 0)), (info.get("buckets", []) as Array).size(),
		(info.get("skips", []) as Array).size(), (info.get("invalidates", []) as Array).size(),
		(info.get("changes", []) as Array).size(),
	])
	if not bool(info.get("available", false)):
		lines.append("当前呈现器没有实现 cache_trace：可能是 core.render 未启用，或后端不是它。")
		return "\n".join(lines)
	lines.append_array(_render_reasons(info))
	lines.append_array(_render_events(info))
	lines.append_array(_render_invalidates(info))
	lines.append_array(_render_gates(info))
	lines.append_array(_render_pipeline(info))
	lines.append_array(_render_impacts(info))
	lines.append("── 判定 ──")
	var findings: Array = info.get("findings", [])
	if findings.is_empty():
		lines.append("没有发现异常的重建行为。")
	for raw in findings:
		var item: Dictionary = raw
		var mark := "✗" if String(item.get("level", "")) == "error" else (
			"!" if String(item.get("level", "")) == "warn" else "·")
		lines.append("%s %s" % [mark, String(item.get("title", ""))])
		var hint := String(item.get("hint", ""))
		if not hint.is_empty():
			lines.append("    → %s" % hint)
	return "\n".join(lines)


## 两条管线分开报：这是「小图糊一点、输出必须精确」能被验证的地方。
static func _render_pipeline(info: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var pipe: Dictionary = info.get("pipeline", {})
	if pipe.is_empty():
		return out
	out.append("── 两条预览管线 ──")
	out.append("  节点小图：边长 %d · 算子质量 %.2f · 刷新 %.2fs%s" % [
		int(pipe.get("limit", 0)), float(pipe.get("operator", 0.0)),
		float(pipe.get("refresh", 0.0)),
		" · 已关闭" if not bool(pipe.get("capture", true)) else "",
	])
	out.append("  输出预览：显示倍率 %.2f（缓存帧与导出仍全分辨率）" % float(pipe.get("display_scale", 1.0)))
	out.append("  归档 / 导出：降采样%s" % (
		"开" if bool(pipe.get("output_downscale", false)) else "关（内核钉死，插件改不动）"))
	# 动态质量：阶梯与最近一次实测。草稿是「先给看、再给好」，所以这里要能回答
	# 「它到底有没有真的出过图」，而不是只说一句「已开启」。
	if bool(pipe.get("draft", false)):
		var steps: Array = pipe.get("draft_steps", [])
		var names: Array[String] = []
		for raw in steps:
			var scale := float(raw)
			if scale > 0.0:
				names.append("1/%d" % int(round(1.0 / scale)))
		out.append("  动态质量：草稿阶梯 %s → 精确（只服务显示：不写缓存、不归档、不影响导出）" % (
			" → ".join(PackedStringArray(names)) if not names.is_empty() else "?"))
		var last: Dictionary = pipe.get("draft_last", {})
		if not last.is_empty():
			var shown := int(last.get("shown", -1))
			out.append("  最近草稿：第 %d 帧 · 1/%d 画布%s" % [
				int(last.get("index", -1)),
				int(round(1.0 / maxf(float(last.get("scale", 1.0)), 0.0001))),
				(" · 已上屏（f%d）" % shown) if shown >= 0 else " · 尚未上屏",
			])
	else:
		out.append("  动态质量：关（设置 render.draft 关闭，或线程前提不满足）")
	return out


static func _render_reasons(info: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var by_reason: Dictionary = info.get("by_reason", {})
	if by_reason.is_empty():
		return out
	var parts: Array[String] = []
	var keys: Array = by_reason.keys()
	keys.sort()
	for key in keys:
		parts.append("%s %d" % [_reason_label(String(key)), int(by_reason[key])])
	out.append("按原因：%s" % " · ".join(PackedStringArray(parts)))
	return out


static func _render_events(info: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var buckets: Array = info.get("buckets", [])
	if buckets.is_empty():
		return out
	out.append("── 最近的重建（最多 %d 条，越靠下越新）──" % SHOW_LIMIT)
	var start := maxi(buckets.size() - SHOW_LIMIT, 0)
	for i in range(start, buckets.size()):
		var item: Dictionary = buckets[i]
		var diff := _diff_parts(item.get("parts_before", {}), item.get("parts_after", {}))
		out.append("  t=%.2fs  %s  %s→%s  帧 %d→%d  清 %d 格  %s" % [
			float(item.get("at", 0.0)), _reason_label(String(item.get("reason", "?"))),
			String(item.get("fp_before", "")), String(item.get("fp_after", "")),
			int(item.get("count_before", 0)), int(item.get("count_after", 0)),
			int(item.get("cleared", 0)), diff,
		])
		var size: Variant = item.get("frame_size", null)
		if size is Vector2i and (size as Vector2i) != Vector2i.ZERO:
			out.append("      画布 %dx%d · 稳定期 %.2fs · 播放中 %s" % [
				(size as Vector2i).x, (size as Vector2i).y,
				float(item.get("settle", 0.0)), "是" if bool(item.get("playing", false)) else "否",
			])
		var names := _detail_diff(item.get("detail_before", {}), item.get("detail_after", {}))
		if not names.is_empty():
			out.append("      变了：%s" % " · ".join(PackedStringArray(names)))
		if bool(item.get("silent", false)):
			out.append("      ！没走变更通知（修订号没变，内容却变了）")
	return out


## 明细对比：这一次重建到底是谁变了。只报 id，不报字段值 ——
## 值可能很长（一张图的采样数组能刷满屏），报出来反而把关键那一行挤掉。
static func _detail_diff(before: Variant, after: Variant) -> Array[String]:
	var out: Array[String] = []
	if not (before is Dictionary) or not (after is Dictionary):
		return out
	var b: Dictionary = before
	var a: Dictionary = after
	if b.is_empty() or a.is_empty():
		return out
	for kind in ["nodes", "edges"]:
		var label := "节点" if String(kind) == "nodes" else "连线"
		var old: Dictionary = b.get(kind, {})
		var now: Dictionary = a.get(kind, {})
		for key in now.keys():
			if not old.has(key):
				out.append("%s+%s" % [label, String(key)])
			elif int(old[key]) != int(now[key]):
				out.append("%s~%s" % [label, String(key)])
		for key in old.keys():
			if not now.has(key):
				out.append("%s-%s" % [label, String(key)])
	if out.size() > 6:
		var extra := out.size() - 6
		out.resize(6)
		out.append("…另 %d 处" % extra)
	return out


static func _diff_parts(before: Dictionary, after: Dictionary) -> String:
	if before.is_empty() or after.is_empty():
		return "（无分段信息）"
	var names := {"nodes": "图", "edges": "连线", "meta": "meta"}
	var moved: Array[String] = []
	for key in ["nodes", "edges", "meta"]:
		if before.get(key) != after.get(key):
			moved.append(String(names[key]))
	if moved.is_empty():
		return "分段全同（只有 fps/时长变了）"
	return "变化：%s" % " / ".join(PackedStringArray(moved))


static func _render_invalidates(info: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var invalidates: Array = info.get("invalidates", [])
	if invalidates.is_empty():
		return out
	var by_tier: Dictionary = info.get("by_tier", {})
	var parts: Array[String] = []
	for key in by_tier.keys():
		parts.append("%s %d" % [String(IMPACT_LABEL.get(String(key), String(key))), int(by_tier[key])])
	out.append("── 失效请求（档位 = 代价的上限）──")
	out.append("  " + " · ".join(PackedStringArray(parts)))
	var start := maxi(invalidates.size() - 6, 0)
	for i in range(start, invalidates.size()):
		var item: Dictionary = invalidates[i]
		var source := String(item.get("source", ""))
		if source.is_empty():
			source = "（文档变更）"
		out.append("  t=%.2fs  %s  ← %s  就绪 %d/%d" % [
			float(item.get("at", 0.0)),
			String(IMPACT_LABEL.get(String(item.get("tier", "content")),
				String(item.get("tier", "content")))),
			source, int(item.get("ready", 0)), int(item.get("frame_count", 0)),
		])
	return out


static func _render_gates(info: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var by_gate: Dictionary = info.get("by_gate", {})
	if by_gate.is_empty():
		return out
	var labels := {
		"content": "放行（内容变了）",
		"layout_only": "挡下（纯布局）",
		"identity_same": "挡下（内容身份没变）",
	}
	var parts: Array[String] = []
	for key in by_gate.keys():
		parts.append("%s %d" % [String(labels.get(String(key), String(key))), int(by_gate[key])])
	out.append("变更通知：%s" % " · ".join(PackedStringArray(parts)))
	return out


static func _render_impacts(info: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var table: Dictionary = info.get("impacts", {})
	var counts: Dictionary = table.get("counts", {})
	if counts.is_empty():
		return out
	out.append("── 设置影响面（声明值决定一次改动波及到哪）──")
	for key in ["content", "derived", "display", "none"]:
		var ids: Array[String] = []
		for raw in table.get("rows", []):
			var row: Dictionary = raw
			if String(row.get("impact", "")) == key:
				ids.append(String(row.get("id", "")))
		if ids.is_empty():
			continue
		out.append("  %s %d：%s" % [
			String(IMPACT_LABEL.get(key, key)), ids.size(),
			", ".join(PackedStringArray(ids.slice(0, 6))) + ("…" if ids.size() > 6 else ""),
		])
	var undecided: Array = table.get("undecided", [])
	if not undecided.is_empty():
		out.append("  未声明 impact 的 runtime 项 %d 个（回落成最贵的「像素内容」）：%s" % [
			undecided.size(),
			", ".join(PackedStringArray(undecided.slice(0, 6))) + ("…" if undecided.size() > 6 else ""),
		])
	return out


static func _push_status(ctx: Dictionary, data: Dictionary) -> void:
	var shell: Variant = ctx.get("shell")
	if shell == null or not shell.has_method("status"):
		return
	var buckets: Array = data.get("buckets", [])
	var changes: Array = data.get("changes", [])
	if not bool(data.get("available", false)):
		shell.call("status", "帧缓存归因：呈现器没有实现 cache_trace")
		return
	shell.call("status", "帧缓存归因：重建 %d 次 · 空转 %d 次 · 变更通知 %d 条" % [
		buckets.size(), (data.get("skips", []) as Array).size(), changes.size()])
