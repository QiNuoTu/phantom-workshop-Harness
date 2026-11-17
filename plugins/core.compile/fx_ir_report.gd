class_name FxIRReport
extends RefCounted
## core.compile 的诊断出口：一条命令、一行装配诊断。
##
## 归因口径：报告里所有「类型不匹配 / 环 / 可剪节点」都归属**插件层**
## （节点定义、算子声明或工程数据），不是内核问题。内核只提供能力代理与数据形状，
## 这里不检查它 —— 那是 diag.blame 的职责。


## 「调试 → IR 编译与剪枝」。编译当前文档，把计划打印出来。
static func cmd_report(ctx: Dictionary) -> void:
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


## 状态栏片段：剪枝数字属于诊断命令，不占常驻状态栏。
static func fragment(_stats: Dictionary) -> Dictionary:
	return {"text": "", "tone": ""}


## 启动装配诊断里的一行：让「这个能力在不在」变成可查的事实。
static func diagnostic(_service: Variant) -> String:
	return "IR 编译器 core.compile：DAG / 类型检查 / 常量折叠 / Live 剪枝（diag.compile 可查）"
