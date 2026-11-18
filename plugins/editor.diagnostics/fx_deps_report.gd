extends RefCounted
## 依赖反向索引（`diag.deps`）：**停用某个插件，到底会掉什么**。
##
## `diag.blame` 回答"谁的错"，`diag.abi` 回答"原生在不在"，都不回答这个问题。
## 而停用一个插件前，人真正想知道的是：它供的东西还有谁在用、什么会跟着消失。
##
## 三条边全部从**清单与账本**推出来，不读代码：
##   · `provide` 键 → `inject` 该键的插件（服务依赖）；
##   · 节点定义的所属插件 → 实现它 op 的插件（算子依赖）；
##   · 插件 → 它贡献的面板/命令/参数控件/导出器的消费方（外壳，只有数量，无反向边）。
##
## 用法：
##   godot --headless --path . -- --fx-diagnose --fx-run=diag.deps
##   godot --headless --path . -- --fx-diagnose --fx-run=diag.deps --fx-arg=fx.native-kit
##                                          （第二个参数：只看某个插件的消费者）

static func cmd_report(ctx: Dictionary) -> void:
	var focus := ""
	for raw in (ctx.get("args", []) as Array):
		var text := String(raw)
		if not text.is_empty() and not text.begins_with("="):
			focus = text
			break
	var data := report(focus)
	print(render(data))
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("status"):
		shell.call("status", "依赖索引：插件 %d · 服务边 %d · 算子边 %d · 孤立供给 %d" % [
			int(data["plugins"]), (data["service_edges"] as Array).size(),
			(data["op_edges"] as Array).size(), (data["orphan_keys"] as Array).size(),
		])


static func report(focus: String = "") -> Dictionary:
	var manifests := _manifests()
	var provides := {}   # key -> [plugin]
	var injects := {}    # plugin -> [key]
	for pid in manifests.keys():
		var manifest: Dictionary = manifests[pid]
		var provide: Variant = manifest.get("provide", {})
		if provide is Dictionary:
			for key in (provide as Dictionary).keys():
				var k := String(key)
				if not provides.has(k):
					provides[k] = []
				(provides[k] as Array).append(String(pid))
		var inject: Variant = manifest.get("inject", [])
		if inject is Array:
			var list: Array[String] = []
			for key in (inject as Array):
				list.append(String(key))
			injects[String(pid)] = list

	# 服务边：provider → consumer（按 provide 键对上 inject）
	var service_edges: Array = []
	for pid in injects.keys():
		for key in (injects[pid] as Array):
			for provider in (provides.get(String(key), []) as Array):
				service_edges.append({"key": String(key), "from": String(provider),
					"to": String(pid)})
	# 算子边：节点定义方 → op 提供方
	var op_edges := _op_edges()
	# 孤儿供给：没有任何插件 inject 的键（不是错误，但说明"这个键目前没人用"）
	var orphan_keys: Array = []
	for key in provides.keys():
		var used := false
		for pid in injects.keys():
			if (injects[pid] as Array).has(String(key)):
				used = true
				break
		if not used:
			orphan_keys.append(String(key))
	orphan_keys.sort()

	var consumers := {}
	for edge in service_edges:
		var item: Dictionary = edge
		var from := String(item["from"])
		if not consumers.has(from):
			consumers[from] = {"service": [], "op": []}
		(consumers[from]["service"] as Array).append(item)

	return {
		"plugins": manifests.size(),
		"service_edges": service_edges,
		"op_edges": op_edges,
		"orphan_keys": orphan_keys,
		"consumers": consumers,
		"focus": focus,
		"contributions": _contributions(),
	}


static func render(data: Dictionary = {}) -> String:
	var info := data if not data.is_empty() else report()
	var lines: Array[String] = []
	lines.append("== 依赖索引 ==")
	lines.append("插件 %d · 服务边 %d · 算子边 %d · 孤立供给键 %d" % [
		int(info["plugins"]), (info["service_edges"] as Array).size(),
		(info["op_edges"] as Array).size(), (info["orphan_keys"] as Array).size(),
	])
	var focus := String(info.get("focus", ""))
	if not focus.is_empty():
		lines.append_array(_render_focus(info, focus))
		return "\n".join(lines)

	# 算子边按"定义方 → 提供方"聚合：28 条逐条列出没人看得下去。
	var grouped := {}
	for raw in (info["op_edges"] as Array):
		var edge: Dictionary = raw
		var key := "%s→%s" % [String(edge["from"]), String(edge["to"])]
		if not grouped.has(key):
			grouped[key] = {"from": String(edge["from"]), "to": String(edge["to"]),
				"ops": []}
		(grouped[key]["ops"] as Array).append(String(edge["op"]))
	if not grouped.is_empty():
		lines.append("── 算子依赖（停用右边那个，左边这些节点会失效）──")
		for key in grouped.keys():
			var item: Dictionary = grouped[key]
			lines.append("  %-16s %2d 个算子  ← %s" % [String(item["to"]),
				(item["ops"] as Array).size(), String(item["from"])])

	var consumers: Dictionary = info["consumers"]
	if not consumers.is_empty():
		lines.append("── 服务依赖（谁 inject 了谁的键）──")
		for pid in consumers.keys():
			var names: Array[String] = []
			for raw in (consumers[pid]["service"] as Array):
				names.append(String((raw as Dictionary)["to"]))
			names.sort()
			# 一个键被 40 个插件注入时（`kernel.graph` 就是），整行打印没人读得下去。
			if names.size() > 8:
				var head: Array[String] = []
				for i in range(8):
					head.append(names[i])
				lines.append("  %-16s → %s 等 %d 个" % [String(pid),
					", ".join(PackedStringArray(head)), names.size()])
			else:
				lines.append("  %-16s → %s" % [String(pid), ", ".join(PackedStringArray(names))])

	var orphan: Array = info["orphan_keys"]
	if not orphan.is_empty():
		# 45 个"没人 inject 的键"里绝大多数是 `plugin.*` / `panel.*` ——
		# 那是**对外留的把手**（外部工具、测试替身用），本就不该有 inject。
		# 按前缀分组报数量，把真正可疑的那几个（契约类前缀）单独列出来。
		var by_prefix := {}
		var interesting: Array[String] = []
		for raw in orphan:
			var key := String(raw)
			var prefix := key.split(".")[0]
			by_prefix[prefix] = int(by_prefix.get(prefix, 0)) + 1
			if prefix == "kernel" or prefix == "graph" or prefix == "service" \
					or prefix == "timeline" or prefix == "node":
				interesting.append(key)
		var parts: Array[String] = []
		for prefix in by_prefix.keys():
			parts.append("%s.* ×%d" % [String(prefix), int(by_prefix[prefix])])
		parts.sort()
		lines.append("── 没人 inject 的供给键 %d 个（按前缀）──" % orphan.size())
		lines.append("  %s" % ", ".join(PackedStringArray(parts)))
		if not interesting.is_empty():
			lines.append("  ！其中契约类前缀：%s" % ", ".join(PackedStringArray(interesting)))
			lines.append("    → 这类键本应有人 inject；一个都没有，说明它对外的承诺已经没人接。")
	lines.append("── 怎么用 ──")
	lines.append("  · 要停用某个插件前，先 `--fx-arg=<id>` 看它的消费者；")
	lines.append("  · 有消费者的会跟着失效（这是设计好的边界），没有的才是真正的孤岛。")
	return "\n".join(lines)


static func _render_focus(info: Dictionary, focus: String) -> Array[String]:
	var lines: Array[String] = []
	lines.append("── %s 的消费者 ──" % focus)
	var hits := 0
	for raw in (info["service_edges"] as Array):
		var edge: Dictionary = raw
		if String(edge["from"]) != focus:
			continue
		hits += 1
		lines.append("  服务 %-26s → %s" % [String(edge["key"]), String(edge["to"])])
	for raw2 in (info["op_edges"] as Array):
		var e2: Dictionary = raw2
		if String(e2["to"]) != focus:
			continue
		hits += 1
		lines.append("  算子 %-26s ← %s（节点定义方）" % [String(e2["op"]), String(e2["from"])])
	if hits == 0:
		lines.append("  （没有插件依赖它：停用它只会让它自己的贡献消失）")
	var contribution: Dictionary = (info["contributions"] as Dictionary).get(focus, {})
	if not contribution.is_empty():
		lines.append("── 它自己的贡献 ──")
		for kind in contribution.keys():
			lines.append("  %-12s %d" % [String(kind), int(contribution[kind])])
	return lines


## 算子边：每条 = {op, from: 节点定义方, to: 算子提供方}。
static func _op_edges() -> Array:
	var providers := {}
	for raw in FxRegistry.ledger:
		var entry: Dictionary = raw
		if String(entry.get("kind", "")) != "op":
			continue
		var key := String(entry.get("key", ""))
		if not providers.has(key):
			providers[key] = []
		(providers[key] as Array).append(String(entry.get("owner", "")))
	var out: Array = []
	for raw_def in FxCatalog.all():
		var def: FxNodeDef = raw_def
		var owners: Array = providers.get(String(def.op), [])
		for owner in owners:
			if String(owner) == def.owner_plugin:
				continue
			out.append({"op": String(def.op), "from": def.owner_plugin, "to": String(owner)})
	return out


## 每个插件贡献了多少条（面板/命令/算子/节点文件……），按账本统计。
static func _contributions() -> Dictionary:
	var out := {}
	for raw in FxRegistry.ledger:
		var entry: Dictionary = raw
		var owner := String(entry.get("owner", ""))
		if owner.is_empty():
			continue
		var kind := String(entry.get("kind", ""))
		if not out.has(owner):
			out[owner] = {}
		var bucket: Dictionary = out[owner]
		bucket[kind] = int(bucket.get(kind, 0)) + 1
	return out


static func _manifests() -> Dictionary:
	var out := {}
	for info in FxRegistry.plugin_infos:
		var pid := String((info as Dictionary).get("id", ""))
		out[pid] = _manifest_of(pid)
	return out


static func _manifest_of(plugin_id: String) -> Dictionary:
	var path := "res://plugins/%s/plugin.json" % plugin_id
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _strings(items: Array) -> Array[String]:
	var out: Array[String] = []
	for item in items:
		out.append(String(item))
	return out
