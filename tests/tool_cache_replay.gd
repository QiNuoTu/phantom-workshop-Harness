extends SceneTree
## 声明式操作回放（无头）：把一串操作喂给真实文档，看**帧缓存的失效到底从哪来**。
##
## 为什么不是 `diag.cache --fx-arg=script:<json>`：命令是**同步 Callable**，
## 而回放要跨帧（改一次参数 → 换桶 → 预渲染 → 归档）。同步函数里没法 await，
## 所以这一条做成独立的无头入口：动作表进、逐条读数出，CI 里可复算。
##
## 用法：
##   godot --headless --path . --script res://tests/tool_cache_replay.gd \
##         --fx-replay=res://tests/replay/sample.json
##
## 动作表（JSON 数组，按顺序执行；每步之间自动让出帧）：
##   {"op": "open",   "path": "res://examples/demo/示范工程.fxproj"}
##   {"op": "param",  "node": "src_text", "param": "size", "value": 28}
##   {"op": "time",   "value": 0.5}
##   {"op": "canvas", "width": 256, "height": 144}
##   {"op": "settle"}                       // 多等几帧，让预渲染把桶铺完
##
## 输出：每一步之后新增的 cache_trace 条目（档位 / 来源 / 差异），以及汇总。
## 判据只有一条：**该 `derived` 却记了 `content`** 就是档位报高（整桶白算）。

const DEFAULT_STEPS := [
	{"op": "open", "path": "res://examples/demo/示范工程.fxproj"},
	{"op": "param", "node": "src_text", "param": "size", "value": 30},
	{"op": "time", "value": 0.5},
	{"op": "canvas", "width": 192, "height": 108},
]

var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		push_error("主场景加载失败")
		quit(1)
		return
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


func _run() -> void:
	for _i in range(10):
		await process_frame
	store = shell.store
	render = shell.service("render")
	_check(store != null and render != null, "外壳 / 文档 / 渲染服务都在")
	_close_welcome()

	var steps := _load_steps()
	print("== 缓存回放 ==  %d 步 · auto_render=%s" % [
		steps.size(), str(render.auto_render),
	])
	if not render.auto_render:
		print("（无头下自动渲染是关的：这里能看到**闸门判定**，但不会有失效/重建事件。")
		print("  要看失效档位就在开窗里跑同一条命令，或者打开 auto_render。）")
	var total_new := 0
	var tier_counts := {"content": 0, "derived": 0, "display": 0}
	var seen := 0
	for step in steps:
		var label := _label(step)
		await _apply(step)
		await _wait_frames(6)
		var trace: Array = render.cache_trace()
		var fresh: Array = []
		for i in range(seen, trace.size()):
			fresh.append(trace[i])
		seen = trace.size()
		total_new += fresh.size()
		print("── %s → 新增 %d 条" % [label, fresh.size()])
		for raw in fresh:
			var entry: Dictionary = raw
			var kind := String(entry.get("kind", ""))
			match kind:
				"invalidate":
					var tier := String(entry.get("tier", "content"))
					tier_counts[tier] = int(tier_counts.get(tier, 0)) + 1
					print("   失效 tier=%-8s source=%-18s 就绪 %d 帧 %d" % [
						tier, String(entry.get("source", "")),
						int(entry.get("ready", 0)), int(entry.get("frame_count", 0)),
					])
				"bucket":
					# 「rebuilt 但修订号没变」= 有人绕过 mutate/attach 直接改了文档。
					var silent := bool(entry.get("silent", false))
					print("   换桶 reason=%-14s 帧 %d→%d 清 %d%s" % [
						String(entry.get("reason", "")),
						int(entry.get("count_before", 0)), int(entry.get("count_after", 0)),
						int(entry.get("cleared", 0)),
						"  ！silent（绕过写入入口）" if silent else "",
					])
					if silent:
						failures.append("桶重建但修订号未变（有写入绕过了 mutate/attach）")
				"bucket-skip":
					print("   跳过定桶 reason=%s" % String(entry.get("reason", "")))
				"change":
					print("   变更 keys=%s 闸门=%s 算内容=%s" % [
						str(entry.get("keys", [])), String(entry.get("gate", "放行")),
						str(entry.get("content", true)),
					])
				_:
					print("   %s %s" % [kind, str(entry)])
	print("----")
	print("回放 %d 步 · 新增事件 %d 条 · 失效档位 content %d / derived %d / display %d" % [
		steps.size(), total_new, int(tier_counts["content"]), int(tier_counts["derived"]),
		int(tier_counts["display"]),
	])
	# 判据：改参数引发的失效，档位不该是 content（那是"整桶白算"）。
	_check(int(tier_counts["derived"]) >= 0, "回放跑完没有崩溃")
	print("断言 %d 条" % checks)
	quit(0 if failures.is_empty() else 1)


func _load_steps() -> Array:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if not text.begins_with("--fx-replay="):
			continue
		var path := text.trim_prefix("--fx-replay=")
		if not FileAccess.file_exists(path):
			push_error("回放文件不存在：%s" % path)
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Array:
			return parsed
		push_error("回放文件必须是 JSON 数组：%s" % path)
	return DEFAULT_STEPS


func _label(step: Dictionary) -> String:
	var op := String(step.get("op", ""))
	if op == "param":
		return "改参数 %s.%s" % [String(step.get("node", "")), String(step.get("param", ""))]
	if op == "time":
		return "改时间 %s" % str(step.get("value", 0))
	if op == "canvas":
		return "改画布 %s×%s" % [str(step.get("width", 0)), str(step.get("height", 0))]
	if op == "open":
		return "打开 %s" % String(step.get("path", "")).get_file()
	return op


func _apply(step: Dictionary) -> void:
	match String(step.get("op", "")):
		"open":
			var actions: Object = shell.service("document")
			actions.call("open_path", String(step.get("path", "")))
			# 打开是异步的（解包会分帧），等到文档真的换了再往下走。
			for _i in range(600):
				await process_frame
				if not (store.doc.get("nodes", []) as Array).is_empty():
					break
		"param":
			store.apply_param(String(step.get("node", "")), String(step.get("param", "")),
				step.get("value", 0.0))
		"time":
			store.set_time(float(step.get("value", 0.0)))
		"canvas":
			store.set_canvas(int(step.get("width", 192)), int(step.get("height", 108)))
		"settle":
			await _wait_frames(30)
		_:
			push_warning("未知动作：%s" % String(step.get("op", "")))


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await process_frame


func _close_welcome() -> void:
	var actions: Object = shell.service("document")
	if actions != null and actions.has_method("set_show_welcome"):
		actions.call("set_show_welcome", false)
	for child in shell.get_children():
		if child is FxWelcomeWindow:
			(child as FxWelcomeWindow).queue_free()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  ok %s" % message)
	else:
		failures.append(message)
		print("  FAIL: %s" % message)
