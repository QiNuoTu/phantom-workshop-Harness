extends RefCounted
## 原生实况（`diag.abi`）：**库在不在、绑定了几类、哪些算子不许跨线程**。
##
## 为什么单开一条命令：原生出问题时日志只有一句「加载失败（架构不符 / 依赖缺失 /
## 引擎版本不兼容）」——它不说"哪一族缺了、还有多少算子能用"。而没有这些事实，
## 排查就会滑向"重编一遍试试"，试完还是不知道有没有变好。
##
## 实现刻意**不引用任何具体原生类**（不写 `FxNativeBridge`、不写 `FxKitKey`）：
## 诊断插件一旦指名别的插件的类，那个插件停用就会让诊断自己解析失败。
## 所以这里只用两样公开契约：
##   · 内核的 `FxNative`（库清单、绑定数、非线程安全算子、ABI 版本）；
##   · 各插件自己的 `status_fragments()` 诊断行 —— 谁的原生，谁自己报。
##
## 用法：
##   godot --headless --path . -- --fx-diagnose --fx-run=diag.abi

static func cmd_report(ctx: Dictionary) -> void:
	var data := report()
	print(render(data))
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("status"):
		shell.call("status", "原生实况：库 %d 个 · 绑定类 %d · 非线程安全算子 %d" % [
			int(data["libraries"].size()), int(data["bound_classes"]),
			int(data["unsafe"].size()),
		])


static func report() -> Dictionary:
	var ops_by_owner := {}
	var op_total := 0
	for raw in FxRegistry.ledger:
		var entry: Dictionary = raw
		if String(entry.get("kind", "")) != "op":
			continue
		op_total += 1
		var owner := String(entry.get("owner", ""))
		ops_by_owner[owner] = int(ops_by_owner.get(owner, 0)) + 1
	# 声明了原生库的插件：只有它们才可能"加载失败"。
	var native_plugins: Array[String] = []
	for info in FxRegistry.plugin_infos:
		var pid := String((info as Dictionary).get("id", ""))
		if _manifest_of(pid).get("native", null) is Dictionary:
			native_plugins.append(pid)
	native_plugins.sort()
	# 各插件自报的诊断行（含"5/5 族在场"这种粒度）。
	# **只取声明了原生库的插件**：别的插件也在往状态栏报素材根、IR 之类，
	# 混进来会让这一屏没法读 —— 这条命令问的是"原生在不在"。
	var fragments: Array[String] = []
	for entry in FxRegistry.status_fragments:
		var owner := String((entry as Dictionary).get("owner", ""))
		if not native_plugins.has(owner):
			continue
		var diag: Callable = (entry as Dictionary).get("diagnostic", Callable())
		if not diag.is_valid():
			continue
		var line := String(diag.call(null))
		if not line.is_empty():
			fragments.append(line)
	return {
		"abi": FxNative.ABI_VERSION,
		"libraries": FxNative.loaded_libraries(),
		"bound_classes": FxNative.bound_count(),
		"unsafe": FxNative.unsafe_ops(),
		"thread_safe": FxNative.thread_safe(),
		"ops_total": op_total,
		"ops_by_owner": ops_by_owner,
		"native_plugins": native_plugins,
		"fragments": fragments,
	}


static func render(data: Dictionary = {}) -> String:
	var info := data if not data.is_empty() else report()
	var lines: Array[String] = []
	lines.append("== 原生实况 ==")
	# 注意两个数不是一回事：`ops_total` 是账本里的 op **登记条数**（含 render.gpu 这类覆盖），
	# 节点类型数由 core.graph 自报。混着写会让人以为"算子比节点多出 6 个"。
	lines.append("ABI 版本 %d · 已加载库 %d · 绑定类实例 %d · op 登记 %d 条（其中原生 %d）" % [
		int(info["abi"]), (info["libraries"] as Array).size(), int(info["bound_classes"]),
		int(info["ops_total"]), _native_ops(info),
	])
	var libraries: Array = info["libraries"]
	if libraries.is_empty():
		lines.append("！没有任何原生库加载 —— 依赖原生的节点会报「算子没有实现」。")
	for raw in libraries:
		lines.append("  库 %s" % String(raw))
	var declared: Array = info["native_plugins"]
	if not declared.is_empty():
		lines.append("── 声明了原生库的插件 ──")
		var by_owner: Dictionary = info["ops_by_owner"]
		for pid in declared:
			var count := int(by_owner.get(pid, 0))
			if count == 0:
				lines.append("  %-16s 不直接登记算子（经桥接实现，算子记在别的插件名下）" % String(pid))
			else:
				lines.append("  %-16s 算子 %d 个" % [String(pid), count])
	var unsafe: Array = info["unsafe"]
	lines.append("── 线程 ──")
	if unsafe.is_empty():
		lines.append("  全部算子声明线程安全；预渲染可继续在工作线程上跑。")
	else:
		lines.append("  ！%d 个算子声明非线程安全 → 整帧回退主线程：%s" % [
			unsafe.size(), ", ".join(PackedStringArray(_strings(unsafe)))])
	if not bool(info.get("thread_safe", true)):
		lines.append("  当前 `FxNative.thread_safe()` = false（渲染服务据此回退主线程）。")
	var fragments: Array = info["fragments"]
	if not fragments.is_empty():
		lines.append("── 各插件自报 ──")
		for raw in fragments:
			lines.append("  %s" % String(raw))
	lines.append("── 读法 ──")
	lines.append("  · 库 0 个：先 `bash plugins/<id>/build.sh template_debug`；")
	lines.append("  · 库在、绑定类 0：`.gdextension` 的 entry_symbol 或类注册没对上；")
	lines.append("  · 某族缺席：只有那一族的算子回落/失效，其余照常 —— 看「各插件自报」那一行。")
	return "\n".join(lines)


## 原生算子数 = 账本里由"声明了原生库的插件"提供的 op 条数。
static func _native_ops(info: Dictionary) -> int:
	var by_owner: Dictionary = info["ops_by_owner"]
	var total := 0
	for pid in (info["native_plugins"] as Array):
		total += int(by_owner.get(String(pid), 0))
	return total


static func _strings(items: Array) -> Array[String]:
	var out: Array[String] = []
	for item in items:
		out.append(String(item))
	return out


static func _manifest_of(plugin_id: String) -> Dictionary:
	var path := "res://plugins/%s/plugin.json" % plugin_id
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
