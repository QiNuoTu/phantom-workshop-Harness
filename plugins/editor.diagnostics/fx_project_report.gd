extends RefCounted
## 工程诊断：**打开一个真实工程**，把每一处问题判给「内核 / 某个插件 / 装配」。
##
## 为什么需要它：`diag.blame` 查的是**装配出来的环境**（谁引用了谁、谁的贡献缺了），
## 它不认识任何一个工程文件；`diag.compile` 只看启动时的示例文档。于是「这个工程
## 打开后画面不对 / 某个节点不生效」只能靠人肉翻图，而翻图最容易翻错方向 ——
## 改了半天插件，真因是工程里留着一个改名前的端口。
##
## 本命令补的正是这一段：**工程内容本身的结构与求值**。
##
##   godot --headless --path . -- --fx-diagnose --fx-run=diag.project \
##         --fx-arg=examples/demo/示范工程.fxproj
##
## 不带 `--fx-arg` 时诊断当前打开的文档（在界面里点菜单也能用）。
##
## 判据全部是**可复核的事实**，不猜：
##   1. 节点类型查不到定义        → 插件（本机没装/停用了提供它的插件）；
##   2. 节点有定义但算子没实现    → 定义方插件（它承诺了一个没人实现的 op）；
##   3. 边指向不存在的节点        → 装配（工程文件残缺/被手工改过）；
##   4. 边指向不存在的端口        → 端口两端的定义方插件（定义改了名、工程没迁移）；
##   5. 节点里留着定义中没有的参数 → 定义方插件（参数改名没做迁移）；
##   6. 参数默认值落在 min/max 外 → 插件（拖进来就是非法值，用户一碰就"坏了"）；
##   7. 求值告警                  → 按文本里出现的节点 id 归给该节点所属插件；
##   8. 逐节点耗时                → **只报数，不判罪**（性能不是错误，见作业口径）。
##
## 刻意不做的事：不替用户改工程、不猜"画面不好看是谁的错"、不把耗时当缺陷。

## 归属词汇与 FxBlame 一致（值是同一份约定的**数据**，逻辑只有 FxBlame 那一份）。
## 为什么不写 `const X := FxBlame.X`：GDScript 对"跨文件常量折叠"不可靠 ——
## 实测那一刻脚本能读、但静态函数返回时会在退出阶段炸 `Stack underflow`。
## 常量重复 10 行无风险；逻辑重复才是屎山，所以 finding / tally / level_rank 全部共用。
const LAYER_KERNEL := "kernel"
const LAYER_PLUGIN := "plugin"
const LAYER_ASSEMBLY := "assembly"

const LEVEL_ERROR := "error"
const LEVEL_WARN := "warn"
const LEVEL_INFO := "info"

const LAYER_LABEL := {
	LAYER_KERNEL: "内核",
	LAYER_PLUGIN: "插件",
	LAYER_ASSEMBLY: "装配",
}
const LEVEL_MARK := {LEVEL_ERROR: "✗", LEVEL_WARN: "!", LEVEL_INFO: "·"}

## 最近一次诊断的文档。归属反查（节点 id → 插件）要读它，
## 而检查函数是静态的、拿不到 ctx —— 用一份进程内缓存比到处传 doc 更不容易漏。
static var _last_doc: Dictionary = {}


# ================= 对外 =================

static func cmd_report(ctx: Dictionary) -> void:
	var args: Array = ctx.get("args", [])
	var path := ""
	for raw in args:
		var text := String(raw)
		if text.is_empty() or text.begins_with("="):
			continue
		path = _normalize_path(text)
		break
	var loaded := {"ok": true, "doc": {}, "manifest": {}, "message": ""}
	if not path.is_empty():
		loaded = _read_project(path)
		if not bool(loaded.get("ok", false)):
			print("工程读不了：%s" % String(loaded.get("message", "")))
	var doc: Dictionary = loaded.get("doc", {}) as Dictionary
	if doc.is_empty():
		doc = _current_doc(ctx)
	var data := report(doc, path, loaded.get("manifest", {}) as Dictionary)
	print(render(data, path))
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("status"):
		var by_layer: Dictionary = data.get("by_layer", {})
		var counts: Dictionary = data.get("by_level", {})
		shell.call("status", "工程诊断：错误 %d · 警告 %d ｜ 需要动手 内核 %d / 插件 %d / 装配 %d" % [
			int(counts.get(LEVEL_ERROR, 0)), int(counts.get(LEVEL_WARN, 0)),
			int(by_layer.get(LAYER_KERNEL, 0)), int(by_layer.get(LAYER_PLUGIN, 0)),
			int(by_layer.get(LAYER_ASSEMBLY, 0)),
		])


static func report(doc: Dictionary = {}, path: String = "", manifest: Dictionary = {}) -> Dictionary:
	_last_doc = doc
	var findings: Array = []
	var structure := _check_structure(doc)
	findings.append_array(structure)
	findings.append_array(_check_manifest(manifest))
	var evaluation := _evaluate(doc)
	findings.append_array(evaluation.get("findings", []))
	findings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var la := FxBlame.level_rank(String(a.get("level", LEVEL_INFO)))
		var lb := FxBlame.level_rank(String(b.get("level", LEVEL_INFO)))
		if la != lb:
			return la < lb
		return String(a.get("layer", "")) < String(b.get("layer", ""))
	)
	var counts := FxBlame.tally(findings)
	var by_level: Dictionary = counts["by_level"]
	var by_layer: Dictionary = counts["by_layer"]
	return {
		"path": path,
		"findings": findings,
		"by_level": by_level,
		"by_layer": by_layer,
		"facts": _facts(doc),
		"timings": evaluation.get("timings", {}),
		"frame_ms": float(evaluation.get("frame_ms", 0.0)),
		"needs_work": int(by_level[LEVEL_ERROR]) + int(by_level[LEVEL_WARN]),
	}


static func render(data: Dictionary = {}, path: String = "") -> String:
	var info := data if not data.is_empty() else report()
	var facts: Dictionary = info.get("facts", {})
	var lines: Array[String] = []
	lines.append("== 工程诊断 ==")
	var label := path if not path.is_empty() else String(facts.get("name", "当前文档"))
	lines.append("工程 %s · %d 节点 · %d 边 · 画布 %s · %.2fs@%d" % [
		label, int(facts.get("nodes", 0)), int(facts.get("edges", 0)),
		String(facts.get("canvas", "?")), float(facts.get("duration", 0.0)),
		int(facts.get("fps", 0)),
	])
	var types: Dictionary = facts.get("types", {})
	var owners: Array[String] = []
	for raw in (facts.get("owners", []) as Array):
		owners.append(String(raw))
	if not owners.is_empty():
		lines.append("涉及插件（%d）：%s" % [owners.size(), ", ".join(PackedStringArray(owners))])
	if not types.is_empty():
		lines.append("节点类型 %d 种 · 定义命中 %d/%d · 算子命中 %d/%d" % [
			types.size(), int(facts.get("defined", 0)), int(facts.get("nodes", 0)),
			int(facts.get("implemented", 0)), int(facts.get("nodes", 0)),
		])
	var findings: Array = info.get("findings", [])
	if findings.is_empty():
		lines.append("没有发现可归因的问题。")
	for raw in findings:
		var item: Dictionary = raw
		var layer := String(item.get("layer", LAYER_ASSEMBLY))
		var owner := String(item.get("owner", ""))
		var who := String(LAYER_LABEL.get(layer, layer))
		if not owner.is_empty():
			who = "%s:%s" % [who, owner]
		var at := String(item.get("at", ""))
		var where := "" if at.is_empty() else "  @ %s" % at
		lines.append("%s [%s] %s%s" % [
			String(LEVEL_MARK.get(String(item.get("level", LEVEL_INFO)), "·")),
			who, String(item.get("message", "")), where,
		])
		var hint := String(item.get("hint", ""))
		if not hint.is_empty():
			lines.append("    → %s" % hint)
	var timings: Dictionary = info.get("timings", {})
	if not timings.is_empty():
		lines.append("── 逐节点耗时（本帧，只报数不判罪）──")
		var rows: Array = []
		for key in timings.keys():
			rows.append({"id": String(key), "ms": float(timings[key])})
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("ms", 0.0)) > float(b.get("ms", 0.0))
		)
		var limit: int = mini(rows.size(), 8)
		for i in range(limit):
			var row: Dictionary = rows[i]
			lines.append("  %2d. %-18s %6.1f ms  → %s" % [
				i + 1, String(row.get("id", "")), float(row.get("ms", 0.0)),
				_node_owner(String(row.get("id", ""))),
			])
		lines.append("  整帧 %.1f ms" % float(info.get("frame_ms", 0.0)))
	var by_level: Dictionary = info.get("by_level", {})
	var by_layer: Dictionary = info.get("by_layer", {})
	lines.append("── 汇总 ──")
	lines.append("错误 %d · 警告 %d · 信息 %d ｜ 需要动手：内核 %d / 插件 %d / 装配 %d" % [
		int(by_level.get(LEVEL_ERROR, 0)), int(by_level.get(LEVEL_WARN, 0)),
		int(by_level.get(LEVEL_INFO, 0)),
		int(by_layer.get(LAYER_KERNEL, 0)), int(by_layer.get(LAYER_PLUGIN, 0)),
		int(by_layer.get(LAYER_ASSEMBLY, 0)),
	])
	var kernel_n := int(by_layer.get(LAYER_KERNEL, 0))
	var plugin_n := int(by_layer.get(LAYER_PLUGIN, 0))
	var assembly_n := int(by_layer.get(LAYER_ASSEMBLY, 0))
	if kernel_n + plugin_n + assembly_n == 0:
		lines.append("结论：内核 0 / 插件 0 / 装配 0 —— 这个工程在本机是干净的。")
	elif kernel_n > 0:
		lines.append("结论：先修内核那几条 —— 基座不成立时，插件问题也不可信。")
	elif plugin_n > 0:
		lines.append("结论：问题在插件侧，优先更新/新增插件解决，不要改内核。")
	else:
		lines.append("结论：插件都正常，动手的是装配（缺插件 / 工程文件 / 版本区间）。")
	return "\n".join(lines)


# ================= 检查项 =================

## 工程内容的结构检查。全部只看「定义怎么说」与「工程怎么用」，不看具体插件。
static func _check_structure(doc: Dictionary) -> Array:
	var out: Array = []
	if doc.is_empty():
		out.append(FxBlame.finding(LEVEL_ERROR, LAYER_ASSEMBLY, "没有可诊断的文档（工程没打开）",
			"用 --fx-arg=<path.fxproj> 指定工程，或先在界面里打开一个工程。", ""))
		return out
	var nodes: Array = doc.get("nodes", [])
	var known := {}
	for raw in nodes:
		if not raw is Dictionary:
			continue
		var node: Dictionary = raw
		var node_id := String(node.get("id", ""))
		var type_id := String(node.get("type", ""))
		known[node_id] = true
		var def: FxNodeDef = FxCatalog.def(type_id)
		if def == null:
			out.append(FxBlame.finding(LEVEL_ERROR, LAYER_PLUGIN,
				"节点 %s 的类型 %s 在本机找不到定义" % [node_id, type_id],
				"提供该类型的插件没装或被停用。装回插件即可；这不是内核问题。",
				"节点 %s" % node_id, "(未安装)"))
			continue
		if def.op == &"":
			out.append(FxBlame.finding(LEVEL_ERROR, LAYER_PLUGIN,
				"节点 %s（%s）没有声明算子" % [node_id, type_id],
				"定义里 op 为空：节点拖出来只会报「缺少算子实现」。", def.source_file,
				def.owner_plugin))
		elif not FxOpRegistry.has_op(def.op):
			out.append(FxBlame.finding(LEVEL_ERROR, LAYER_PLUGIN,
				"节点 %s（%s）的算子 %s 没有实现" % [node_id, type_id, String(def.op)],
				"节点定义了但没人注册这个 op。改法在插件侧：补实现或改 op 名。",
				def.source_file, def.owner_plugin))
		out.append_array(_check_node_params(node, def))
	if String(doc.get("output", "")).is_empty():
		out.append(FxBlame.finding(LEVEL_WARN, LAYER_ASSEMBLY, "工程没有指定输出节点",
			"没有输出节点时整帧不会求值：在棋盘上右键某个节点设为输出。", ""))
	elif not known.has(String(doc.get("output", ""))):
		out.append(FxBlame.finding(LEVEL_ERROR, LAYER_ASSEMBLY,
			"输出节点 %s 不在节点表里" % String(doc.get("output", "")),
			"工程文件残缺：输出指向一个已经不存在的节点。", ""))
	out.append_array(_check_edges(doc))
	return out


## 参数层面：留了定义里没有的键、或者默认值自己就落在范围外。
static func _check_node_params(node: Dictionary, def: FxNodeDef) -> Array:
	var out: Array = []
	var params: Variant = node.get("params", {})
	if not params is Dictionary:
		return out
	var node_id := String(node.get("id", ""))
	var ids := {}
	for spec in def.params:
		ids[String(spec.get("id", ""))] = spec
	for key in (params as Dictionary).keys():
		var path := String(key)
		if ids.has(path):
			continue
		out.append(FxBlame.finding(LEVEL_WARN, LAYER_PLUGIN,
			"节点 %s 留着定义里没有的参数「%s」" % [node_id, path],
			"参数被改名/删掉了，工程里还留着旧键：算子读不到它，用户改它也不会有反应。"
				+ "迁移在插件侧做（读旧键→写新键），或者重新拖一个节点。",
			"节点 %s" % node_id, def.owner_plugin))
	for spec in def.params:
		var kind := String(spec.get("kind", "float"))
		if kind != "float" and kind != "int":
			continue
		if not spec.has("min") or not spec.has("max"):
			continue
		var pid := String(spec.get("id", ""))
		var fallback := float(spec.get("default", 0.0))
		var low := float(spec.get("min"))
		var high := float(spec.get("max"))
		if fallback < low or fallback > high:
			out.append(FxBlame.finding(LEVEL_WARN, LAYER_PLUGIN,
				"节点 %s 的「%s」默认值 %s 落在范围 [%s, %s] 之外"
					% [node_id, String(spec.get("label", pid)), str(fallback), str(low), str(high)],
				"拖出来就是非法值，滑块一动会跳到边界 —— 用户看到的是「这个节点一碰就坏」。",
				def.source_file, def.owner_plugin))
	return out


## 边的两端必须都存在：节点存在是「装配」的事，端口存在是「定义」的事。
static func _check_edges(doc: Dictionary) -> Array:
	var out: Array = []
	var nodes := {}
	for raw in doc.get("nodes", []):
		if raw is Dictionary:
			nodes[String((raw as Dictionary).get("id", ""))] = raw
	for raw_edge in doc.get("edges", []):
		if not raw_edge is Dictionary:
			continue
		var edge: Dictionary = raw_edge
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		var from_port := String(edge.get("from_port", ""))
		var to_port := String(edge.get("to_port", ""))
		for side in [["from", from_id, from_port, "输出"], ["to", to_id, to_port, "输入"]]:
			var role := String(side[3])
			var node_id := String(side[1])
			var port_id := String(side[2])
			if not nodes.has(node_id):
				out.append(FxBlame.finding(LEVEL_ERROR, LAYER_ASSEMBLY,
					"连线指着不存在的节点 %s（%s 端）" % [node_id, role],
					"工程文件残缺：用另一份备份，或删掉这条连线。", ""))
				continue
			var node: Dictionary = nodes[node_id]
			var def: FxNodeDef = FxCatalog.def(node.get("type", ""))
			if def == null:
				continue  # 类型缺失已经单独报过，不重复刷屏
			if not def.port_provider.is_empty():
				# 端口由 provider 现场生成（子图按内部端点、输出节点按图层数）：
				# 静态定义里本来就没有，硬查会把每一条正常连线都报成错误。
				continue
			if _accepts_port(def, port_id, role == "输入"):
				continue
			out.append(FxBlame.finding(LEVEL_ERROR, LAYER_PLUGIN,
				"节点 %s（%s）没有%s端口「%s」" % [node_id, String(node.get("type", "")), role, port_id],
				"端口被改名/删除了，工程还连着旧名字：这条连线永远不生效，画面看起来就是"
					+ "「上游怎么改都没反应」。迁移由定义方插件负责。",
				def.source_file, def.owner_plugin))
	return out


## 端口是否被这个定义承认。
##
## 这里的「端口」比定义里那份 `inputs` 大：**可连线的参数也是端口**
## （执行器按参数 id 回填），漏掉这一条会把每一条「连线驱动参数」都误报成错误。
## 输出侧只认 `outputs`。
static func _accepts_port(def: FxNodeDef, port_id: String, is_input: bool) -> bool:
	var ports: Array = def.inputs if is_input else def.outputs
	for p in ports:
		if String((p as Dictionary).get("id", "")) == port_id:
			return true
	if not is_input:
		return false
	for spec in def.params:
		if String((spec as Dictionary).get("id", "")) != port_id:
			continue
		if bool((spec as Dictionary).get("bindable", true)):
			return true
	return false


## 工程包自述（manifest.json）与「本机装了什么」的对照。
##
## 这一节回答的是**环境**问题：工程随包带了哪些插件、本机少哪一个。
## 它比「节点类型找不到」更早、更直接：先看少了谁，再谈为什么没画面。
static func _check_manifest(manifest: Dictionary) -> Array:
	var out: Array = []
	if manifest.is_empty():
		return out
	var format_version := String(manifest.get("host_version", ""))
	if not format_version.is_empty() and format_version != "0.1":
		out.append(FxBlame.finding(LEVEL_ERROR, LAYER_ASSEMBLY,
			"工程格式 %s 与当前内核（0.1）不符" % format_version,
			"不读、不猜、不迁移：用对应版本的应用打开，或让作者用当前版本重导出。", ""))
	var installed := {}
	for raw in FxRegistry.plugin_infos:
		installed[String((raw as Dictionary).get("id", ""))] = true
	for raw_id in (manifest.get("plugins", []) as Array):
		var pid := String(raw_id)
		if pid.is_empty() or installed.has(pid):
			continue
		out.append(FxBlame.finding(LEVEL_WARN, LAYER_ASSEMBLY,
			"工程随包带了插件 %s，本机没有（没装或被停用）" % pid,
			"先把它装回来/启用，再看这个工程有没有真问题：缺插件时一切「节点找不到」都是它的后果。", ""))
	return out


## 求值一次：既检查「跑不跑得动」，也给出逐节点耗时（只报数）。
static func _evaluate(doc: Dictionary) -> Dictionary:
	var out: Array = []
	if doc.is_empty():
		return {"findings": out, "timings": {}, "frame_ms": 0.0}
	var runner := FxGraphRunner.new()
	var started := Time.get_ticks_usec()
	var result: Dictionary = runner.run(doc, 0.0)
	var frame_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var totals: Dictionary = {}
	if runner.ctx != null:
		totals = (runner.ctx.timing_totals as Dictionary).duplicate()
	if result.get("image") == null:
		out.append(FxBlame.finding(LEVEL_ERROR, LAYER_PLUGIN,
			"求值没有产出图像",
			"先看上面的「算子没有实现」与端口问题；两者都干净时，问题在该输出链上的算子。",
			"输出 %s" % String(doc.get("output", "")), _node_owner(String(doc.get("output", "")))))
	for raw in (result.get("warnings", []) as Array):
		var text := String(raw)
		var owner := _owner_from_node_id(text)
		out.append(FxBlame.finding(LEVEL_WARN, LAYER_PLUGIN if not owner.is_empty() else LAYER_ASSEMBLY,
			"求值告警：%s" % text,
			"告警带节点 id 时归属可判；没有 id 的告警说明上报点缺上下文，"
				+ "在插件侧补上节点 id 才能继续追。", "", owner))
	var timings := {}
	var nodes: Array = doc.get("nodes", [])
	var limit: int = mini(nodes.size(), 64)
	for i in range(limit):
		var node: Dictionary = nodes[i]
		var node_id := String(node.get("id", ""))
		if totals.has(node_id):
			timings[node_id] = float(totals[node_id])
	return {"findings": out, "timings": timings, "frame_ms": frame_ms}


# ================= 事实与工具 =================

static func _facts(doc: Dictionary) -> Dictionary:
	var facts := {"name": String(doc.get("meta", {}).get("name", "未命名")),
		"nodes": 0, "edges": 0, "canvas": "?", "duration": 1.0, "fps": 30,
		"types": {}, "defined": 0, "implemented": 0, "owners": []}
	if doc.is_empty():
		return facts
	var canvas := FxGraphDoc.canvas(doc)
	var timeline: Dictionary = FxGraphDoc.timeline(doc)
	var types := {}
	var owners := {}
	var defined := 0
	var implemented := 0
	for raw in doc.get("nodes", []):
		if not raw is Dictionary:
			continue
		var type_id := String((raw as Dictionary).get("type", ""))
		types[type_id] = true
		var def: FxNodeDef = FxCatalog.def(type_id)
		if def != null:
			defined += 1
			if not def.owner_plugin.is_empty():
				owners[def.owner_plugin] = true
			if FxOpRegistry.has_op(def.op):
				implemented += 1
	facts["nodes"] = (doc.get("nodes", []) as Array).size()
	facts["edges"] = (doc.get("edges", []) as Array).size()
	facts["canvas"] = "%d×%d" % [canvas.x, canvas.y]
	facts["duration"] = float(timeline.get("duration", 1.0))
	facts["fps"] = int(timeline.get("fps", 30))
	facts["types"] = types
	facts["defined"] = defined
	facts["implemented"] = implemented
	var owner_list: Array = owners.keys()
	owner_list.sort()
	facts["owners"] = owner_list
	return facts


## op id → 第一提供者插件（同一 op 可被多个插件实现，这里只取来显示）。
static func _op_owner(op_id: String) -> String:
	for raw in FxRegistry.ledger:
		var entry: Dictionary = raw
		if String(entry.get("kind", "")) != "op":
			continue
		if String(entry.get("key", "")) != op_id:
			continue
		return String(entry.get("owner", ""))
	return ""


## 节点 id → 所属插件（用当前工程或当前目录里的定义反查）。
static func _node_owner(node_id: String) -> String:
	if node_id.is_empty():
		return ""
	var doc: Dictionary = _last_doc
	for raw in doc.get("nodes", []):
		if not raw is Dictionary:
			continue
		var node: Dictionary = raw
		if String(node.get("id", "")) != node_id:
			continue
		var def: FxNodeDef = FxCatalog.def(node.get("type", ""))
		if def == null:
			return "(未安装)"
		return def.owner_plugin
	return ""


## 告警文本里如果出现某个节点 id，就把这条告警归给那个节点的插件。
static func _owner_from_node_id(text: String) -> String:
	for raw in _last_doc.get("nodes", []):
		if not raw is Dictionary:
			continue
		var node_id := String((raw as Dictionary).get("id", ""))
		if node_id.length() < 3:
			continue
		if text.contains(node_id):
			return _node_owner(node_id)
	return ""


static func _normalize_path(raw: String) -> String:
	var path := raw.replace("\\", "/")
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	if path.begins_with("/") or (path.length() > 2 and path[1] == ":"):
		return path
	return "res://" + path.trim_prefix("./")


## 只读解析一个工程：**不打开它、不解素材、不动工作台**。
##
## 为什么不去调 editor.document 的 open_path：
##   1. 诊断不该改变用户当前打开的东西（跑完一次检查把工程换掉，是不可接受的行为）；
##   2. 解包素材会往 user:// 写文件，而诊断可能只是 CI 里跑一次；
##   3. 打开工程后立刻退出，引擎会在退出阶段刷一串静态字符串告警 —— 那不是本工程的问题，
##      但会混进日志里，让人以为诊断自己坏了。
##
## 因此这里只做一件事：把包里的图文档与清单**读出来**。条目名是工程格式的一部分
## （`project.fxgraph.json` / `manifest.json`），格式不认就直接报装配错误，不猜。
## 公开给同插件的其它命令复用（diag.compile 读同一份工程）。
## 只读语义在这里只有一处实现 —— 解包、版本校验、素材重绑都不能有第二份。
static func read_project(path: String) -> Dictionary:
	return _read_project(path)


static func _read_project(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "message": "文件不存在：%s" % path}
	if path.get_extension().to_lower() == "fxgraph":
		var json_doc: Dictionary = _parse_doc(FileAccess.get_file_as_string(path))
		if json_doc.is_empty():
			return {"ok": false, "message": "不是合法的图文档：%s" % path}
		return {"ok": true, "doc": json_doc, "manifest": {}, "message": ""}
	var reader := ZIPReader.new()
	if reader.open(path) != OK:
		return {"ok": false, "message": "ZIP 打不开：%s" % path}
	var manifest: Dictionary = {}
	if reader.file_exists("manifest.json"):
		var parsed: Variant = JSON.parse_string(
			reader.read_file("manifest.json").get_string_from_utf8())
		if parsed is Dictionary:
			manifest = parsed
	if not reader.file_exists("project.fxgraph.json"):
		reader.close()
		return {"ok": false, "message": "工程包里没有 project.fxgraph.json", "manifest": manifest}
	var doc := _parse_doc(reader.read_file("project.fxgraph.json").get_string_from_utf8())
	if doc.is_empty():
		reader.close()
		return {"ok": false, "message": "工程包里的图文档不是合法 JSON", "manifest": manifest}
	# 包里的路径是**包内相对**的（子图 json、贴图都在 assets/ 下）。求值前必须把它们
	# 换成真实文件，否则「子图文件找不到」这类告警会把一次正常的检查读成缺陷。
	_materialize(reader, doc, manifest, path)
	reader.close()
	return {"ok": true, "doc": doc, "manifest": manifest, "message": ""}


## 把包内素材解到诊断专属的临时目录，并**只在内存文档里**改写路径。
##
## 为什么解到盘上而不是造一个内存补丁层：求值器读的是真实文件（Image.load、子图读盘），
## 没有虚拟文件系统可插。目录放 `user://diag_projects/<工程名>/`，与用户工程的目录分开，
## 不碰工作台、不进帧缓存；重复诊断时同名文件直接复用。
static func _materialize(reader: ZIPReader, doc: Dictionary, manifest: Dictionary,
		path: String) -> void:
	var target_dir := "user://diag_projects".path_join(path.get_file().get_basename())
	for raw in (manifest.get("assets", []) as Array):
		if not raw is Dictionary:
			continue
		var asset: Dictionary = raw
		var entry := String(asset.get("entry", ""))
		if entry.is_empty() or not reader.file_exists(entry):
			continue
		if not DirAccess.dir_exists_absolute(target_dir):
			DirAccess.make_dir_recursive_absolute(target_dir)
		var to := target_dir.path_join(entry.get_file())
		if not FileAccess.file_exists(to):
			var data: PackedByteArray = reader.read_file(entry)
			var out := FileAccess.open(to, FileAccess.WRITE)
			if out == null:
				continue
			out.store_buffer(data)
			out.close()
		var node_id := String(asset.get("node", ""))
		var param_id := String(asset.get("param", ""))
		if node_id.is_empty() or param_id.is_empty():
			continue
		var node: Dictionary = FxGraphDoc.node(doc, node_id)
		if node.is_empty():
			continue
		var params: Variant = node.get("params", {})
		if params is Dictionary:
			(params as Dictionary)[param_id] = to


static func _parse_doc(text: String) -> Dictionary:
	if text.is_empty():
		return {}
	var raw: Variant = JSON.parse_string(text)
	if not raw is Dictionary:
		return {}
	return FxGraphDoc.normalize(raw as Dictionary)


static func _current_doc(ctx: Dictionary) -> Dictionary:
	var store: Variant = ctx.get("store")
	var doc: Dictionary = {}
	if store != null and store.get("doc") is Dictionary:
		doc = store.get("doc") as Dictionary
	_last_doc = doc
	return doc
