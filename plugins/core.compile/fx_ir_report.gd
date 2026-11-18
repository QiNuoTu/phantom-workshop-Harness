class_name FxIRReport
extends RefCounted
## core.compile 的诊断出口：一条命令、一行装配诊断。
##
## 归因口径：报告里所有「类型不匹配 / 环 / 可剪节点」都归属**插件层**
## （节点定义、算子声明或工程数据），不是内核问题。内核只提供能力代理与数据形状，
## 这里不检查它 —— 那是 diag.blame 的职责。


## 「调试 → IR 编译与剪枝」。编译当前文档，把计划打印出来。
static func cmd_report(ctx: Dictionary) -> void:
	# `--fx-arg=<path>`：编译**指定工程**，而不是当前打开的那份。
	# 工程读盘不在这里实现：本插件不认识 .fxproj，问能力键 `project.read`。
	# 提供方缺席时打印一句"装回 editor.diagnostics"，而不是偷偷退回当前文档 ——
	# 那是"看起来跑了、其实跑的是别的东西"，比报错更坏。
	var wanted := ""
	for raw_arg in (ctx.get("args", []) as Array):
		var text := String(raw_arg)
		if not text.is_empty() and not text.begins_with("="):
			wanted = text
			break
	if not wanted.is_empty():
		_cmd_from_project(ctx, wanted)
		return
	var doc: Dictionary = {}
	var roots: Array = []
	var shell: Variant = ctx.get("shell")
	if shell != null:
		var store: Variant = shell.get("store")
		if store != null:
			var raw: Variant = store.get("doc")
			if raw is Dictionary:
				doc = raw
			# 选中节点是 preview_roots 的一部分；命令跑在主线程，读一次就够。
			var selected: Variant = store.get("selected_id")
			if selected != null and not String(selected).is_empty():
				roots.append(String(selected))
	# 呈现器知道「展开 ∪ 选中」的完整根集合；命令跑在主线程，问一次即可。
	var renderer: Variant = shell.call("service", "render") if shell.has_method("service") else null
	if renderer != null and renderer.has_method("preview_roots"):
		var extra: Variant = renderer.call("preview_roots")
		if extra is Array:
			for item in (extra as Array):
				var rid := String(item)
				if not rid.is_empty() and not roots.has(rid):
					roots.append(rid)
	if doc.is_empty():
		print(FxIRCompiler.explain({}, "IR 编译与剪枝（当前无文档）"))
		return
	var plan := FxIRCompiler.compile(doc, roots)
	print(FxIRCompiler.explain(plan))
	var s: Dictionary = plan.get("stats", {})
	if shell != null and shell.has_method("status"):
		shell.call("status", "IR：Live %d / Dead %d · 折叠 %d · 类型错误 %d" % [
			int(s.get("live", 0)), int(s.get("dead", 0)),
			int(s.get("foldable", 0)), int(s.get("type_errors", 0)),
		])


## 编译一个磁盘上的工程。文档由 `project.read` 能力提供（只读解析，不打开工程）。
static func _cmd_from_project(ctx: Dictionary, path: String) -> void:
	var providers := FxCapabilities.providers("project.read")
	if providers.is_empty():
		print("== IR 编译与剪枝（%s）==" % path)
		print("没有可用的工程读取器：`project.read` 能力缺席。")
		print("  → 装回/启用 `editor.diagnostics`（它提供只读解析），或去掉 --fx-arg 编当前文档。")
		return
	var reader: Callable = (providers[0] as Dictionary).get("apply", Callable())
	if not reader.is_valid():
		print("project.read 的 handler 无效：提供方实现有问题。")
		return
	var loaded: Variant = reader.call(path)
	if not (loaded is Dictionary) or not bool((loaded as Dictionary).get("ok", false)):
		var message := "读不了：%s" % path
		if loaded is Dictionary:
			message = String((loaded as Dictionary).get("message", message))
		print("== IR 编译与剪枝（%s）==" % path)
		print(message)
		return
	var doc: Dictionary = (loaded as Dictionary).get("doc", {})
	var nodes: Array = doc.get("nodes", [])
	print(FxIRCompiler.explain(FxIRCompiler.compile(doc, []),
		"IR 编译与剪枝 · %s（%d 节点）" % [path.get_file(), nodes.size()]))
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("status"):
		shell.call("status", "IR（工程）：%s · %d 节点" % [path.get_file(), nodes.size()])


## 状态栏片段：剪枝数字属于诊断命令，不占常驻状态栏。
static func fragment(_stats: Dictionary) -> Dictionary:
	return {"text": "", "tone": ""}


## 启动装配诊断里的一行：让「这个能力在不在」变成可查的事实。
static func diagnostic(_service: Variant) -> String:
	return "IR 编译器 core.compile：DAG / 类型检查 / 常量折叠 / Live 剪枝（diag.compile 可查）"
