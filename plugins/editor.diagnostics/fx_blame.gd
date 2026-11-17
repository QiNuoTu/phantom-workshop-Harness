class_name FxBlame
extends RefCounted
## 归因诊断：把每一条问题判给「内核」「某个插件」或「装配」，而不是笼统地报一句失败。
##
## 为什么单独做成插件而不是塞进基座：
##   · 它需要读账本、注册表、目录、启动报告——这些都是公开契约，插件能读全；
##   · 归因逻辑本身会演进，塞进基座就等于让「排查工具」变成不可卸载的内核负担。
##
## 判据（尽量只用可验证的事实，不猜）：
##   1. 基座源码里出现插件 `class_name` → 内核问题（该插件一停用，基座编译就废）；
##   2. 贡献的账本项带 owner → 该 owner 就是责任人；
##   3. 节点定义的算子缺失 → 节点定义所属插件；
##   4. 节点定义与算子分属两个插件 → 定义方（跨插件依赖没在 plugin.json 声明）；
##   5. 启停/依赖/供给冲突 → 声明方插件；
##   6. 启动错误：先认 `scope` 归属声明（kernel / assembly / plugin:<id>），
##      没声明才回落到「文本里有没有插件痕迹」的旧规则。
##
## 用法：
##   godot --headless --path . -- --fx-diagnose --fx-run=diag.blame
## 或者在「帮助」菜单里点「归因诊断」。

const KERNEL_ROOT := "res://scripts/graph"
const PLUGIN_ROOT := "res://plugins"
const VERSION_FILE := "res://version.json"

const LEVEL_ERROR := "error"
const LEVEL_WARN := "warn"
const LEVEL_INFO := "info"

const LAYER_KERNEL := "kernel"
const LAYER_PLUGIN := "plugin"
const LAYER_ASSEMBLY := "assembly"

const LAYER_LABEL := {
	LAYER_KERNEL: "内核",
	LAYER_PLUGIN: "插件",
	LAYER_ASSEMBLY: "装配",
}
const LEVEL_MARK := {LEVEL_ERROR: "✗", LEVEL_WARN: "!", LEVEL_INFO: "·"}


# ================= 对外 =================

static func cmd_report(ctx: Dictionary) -> void:
	var store: Variant = ctx.get("store")
	# 结构检查之外还要查一次**当前文档**：「同一份事实有两个来源」这类缺陷
	# 在注册表里看不出来，只有看文档才看得见（见 _check_bindings）。
	var doc: Dictionary = {}
	if store != null and store.get("doc") is Dictionary:
		doc = store.get("doc") as Dictionary
	var data := report(doc)
	print(render(data))
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("status"):
		var counts: Dictionary = data.get("by_level", {})
		shell.call("status", "归因诊断：错误 %d · 警告 %d · 归属 内核 %d / 插件 %d / 装配 %d" % [
			int(counts.get(LEVEL_ERROR, 0)), int(counts.get(LEVEL_WARN, 0)),
			int((data.get("by_layer", {}) as Dictionary).get(LAYER_KERNEL, 0)),
			int((data.get("by_layer", {}) as Dictionary).get(LAYER_PLUGIN, 0)),
			int((data.get("by_layer", {}) as Dictionary).get(LAYER_ASSEMBLY, 0)),
		])


static func report(doc: Dictionary = {}) -> Dictionary:
	var findings: Array = []
	findings.append_array(_check_kernel_boundary())
	findings.append_array(_check_boot_errors())
	findings.append_array(_check_ledger_errors())
	findings.append_array(_check_dependencies())
	findings.append_array(_check_catalog())
	findings.append_array(_check_contracts())
	findings.append_array(_check_bindings(doc))
	findings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var la := _level_rank(String(a.get("level", LEVEL_INFO)))
		var lb := _level_rank(String(b.get("level", LEVEL_INFO)))
		if la != lb:
			return la < lb
		return String(a.get("layer", "")) < String(b.get("layer", ""))
	)
	var by_level := {LEVEL_ERROR: 0, LEVEL_WARN: 0, LEVEL_INFO: 0}
	var by_layer := {LAYER_KERNEL: 0, LAYER_PLUGIN: 0, LAYER_ASSEMBLY: 0}
	for raw in findings:
		var item: Dictionary = raw
		var level := String(item.get("level", LEVEL_INFO))
		by_level[level] = int(by_level.get(level, 0)) + 1
		if level == LEVEL_INFO:
			continue
		var layer := String(item.get("layer", LAYER_ASSEMBLY))
		by_layer[layer] = int(by_layer.get(layer, 0)) + 1
	return {
		"findings": findings,
		"by_level": by_level,
		"by_layer": by_layer,
		"ok": int(by_level[LEVEL_ERROR]) == 0,
	}


static func render(data: Dictionary = {}) -> String:
	var info := data if not data.is_empty() else report()
	var findings: Array = info.get("findings", [])
	var by_level: Dictionary = info.get("by_level", {})
	var by_layer: Dictionary = info.get("by_layer", {})
	var versions := read_versions()
	var lines: Array[String] = []
	lines.append("== 归因诊断 ==")
	lines.append("内核契约 %s · 应用 %s · 工程格式 %s · 插件 %d" % [
		String(versions.get("kernel", "?")), String(versions.get("app", "?")),
		String(versions.get("project_format", "?")), FxRegistry.plugin_infos.size(),
	])
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
	lines.append("── 汇总 ──")
	lines.append("错误 %d · 警告 %d · 信息 %d ｜ 需要动手：内核 %d / 插件 %d / 装配 %d" % [
		int(by_level.get(LEVEL_ERROR, 0)), int(by_level.get(LEVEL_WARN, 0)),
		int(by_level.get(LEVEL_INFO, 0)),
		int(by_layer.get(LAYER_KERNEL, 0)), int(by_layer.get(LAYER_PLUGIN, 0)),
		int(by_layer.get(LAYER_ASSEMBLY, 0)),
	])
	return "\n".join(lines)


static func read_versions() -> Dictionary:
	if not FileAccess.file_exists(VERSION_FILE):
		return {}
	var text := FileAccess.get_file_as_string(VERSION_FILE)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


# ================= 检查项 =================

## 1) 基座源码里出现插件类名：这是**内核**的问题，不是插件的问题。
## 只要那个插件被停用或删除，scripts/graph 就编译不过 —— 基座不再可独立成立。
static func _check_kernel_boundary() -> Array:
	var owners := _plugin_class_owners()
	if owners.is_empty():
		return []
	var out: Array = []
	for file in _gd_files(KERNEL_ROOT):
		var text := _strip_comments(_read(file))
		if text.is_empty():
			continue
		var words := _words_of(text)
		for raw_name in owners.keys():
			var symbol := String(raw_name)
			if not words.has(symbol):
				continue
			out.append(_finding(LEVEL_ERROR, LAYER_KERNEL,
				"基座引用了插件类名 %s（来自 %s）" % [symbol, String(owners[raw_name])],
				"停用/删除该插件后 scripts/graph 编译失败。改法：定义基座契约，或把这段逻辑挪回插件（由插件贡献诊断/数据）。",
				String(file).replace("res://", "")))
	return out


## 2) 启动报告里的错误：先看**归属声明**，没有声明才回到文本推断。
##
## 旧实现只有文本推断，于是「插件目录缺清单」这类装配问题会被判成内核 ——
## 因为错误文本里恰好没有插件 id。归属声明是基座的 `FxBoot.error(where, msg, scope)`，
## 装配步骤自己知道自己在干嘛，比正则可靠。
static func _check_boot_errors() -> Array:
	var out: Array = []
	for raw in FxBoot.errors():
		var item: Dictionary = raw
		var where := String(item.get("where", ""))
		var message := String(item.get("message", ""))
		var scope := String(item.get("scope", ""))
		if scope == "assembly":
			out.append(_finding(LEVEL_ERROR, LAYER_ASSEMBLY,
				"启动错误［%s］%s" % [where, message],
				"发生在装配阶段（扫插件目录 / 读清单 / 协调供给键）：先看目录结构与 plugin.json，别急着改内核。", ""))
			continue
		if scope.begins_with("plugin:"):
			var scoped_owner := scope.substr(7)
			out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN,
				"启动错误［%s］%s" % [where, message],
				"由插件 %s 造成：先看它的 plugin.json / 脚本解析。" % scoped_owner, "", scoped_owner))
			continue
		if scope == "kernel":
			out.append(_finding(LEVEL_ERROR, LAYER_KERNEL,
				"启动错误［%s］%s" % [where, message],
				"由基座启动步骤自报，可直接按内核问题排查。", ""))
			continue
		var owner := _owner_from_text(where)
		if owner.is_empty():
			owner = _owner_from_text(message)
		if owner.is_empty():
			out.append(_finding(LEVEL_ERROR, LAYER_KERNEL,
				"启动错误［%s］%s" % [where, message],
				"这条错误没有声明归属，文本里也没有插件痕迹，暂按内核启动步骤排查。", ""))
		else:
			out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN,
				"启动错误［%s］%s" % [where, message],
				"由插件 %s 造成（文本推断）：先看它的 plugin.json / 脚本解析。" % owner, "", owner))
	return out


## 3) 账本里的错误项自带 owner：直接用，不用猜。
static func _check_ledger_errors() -> Array:
	var out: Array = []
	for raw in FxRegistry.ledger:
		var entry: Dictionary = raw
		if String(entry.get("kind", "")) != "error":
			continue
		var owner := String(entry.get("owner", ""))
		out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN if owner != "" else LAYER_KERNEL,
			String(entry.get("value", "")),
			"这条错误在账本里登记，停用该插件即可撤回；修好后再启用。",
			"", owner))
	return out


## 4) 依赖与启停：缺供给键 / 依赖环 / 未激活。
static func _check_dependencies() -> Array:
	var out: Array = []
	var dep: Dictionary = FxPluginHost.dependency_report()
	for raw in dep.get("missing", []):
		var item: Dictionary = raw
		var pid := String(item.get("plugin", ""))
		out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN,
			"插件 %s 声明的注入键 %s 没有提供者，无法激活" % [pid, String(item.get("key", ""))],
			"要么补一个提供该键的插件，要么删掉这条 inject。", "", pid))
	for raw_cycle in dep.get("cycles", []):
		var cycle: Array = raw_cycle if raw_cycle is Array else []
		if cycle.is_empty():
			continue
		var names: Array[String] = []
		for pid in cycle:
			names.append(String(pid))
		out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN,
			"依赖环：%s" % " → ".join(names),
			"环上的每个插件都永远激活不了；按论文 §6.5 把双向交互拆成两条单向绑定。",
			"", String(names[0])))
	var disabled := FxPluginHost.disabled_ids()
	for raw_pid in dep.get("inactive", []):
		var pid := String(raw_pid)
		if disabled.has(pid):
			continue
		out.append(_finding(LEVEL_WARN, LAYER_PLUGIN,
			"插件 %s 未激活" % pid,
			"看它的依赖是否被停用；依赖未满足时它会静默不生效。", "", pid))
	return out


## 5) 节点定义与算子：缺实现、跨插件借算子、归属丢失。
static func _check_catalog() -> Array:
	var out: Array = []
	for raw in FxCatalog.all():
		var def: FxNodeDef = raw
		var id := String(def.id)
		var owner := def.owner_plugin
		if owner.is_empty():
			out.append(_finding(LEVEL_WARN, LAYER_ASSEMBLY,
				"节点 %s 找不到所属插件（账本里没有对应 node_file）" % id,
				"节点归属由账本反查；归属为空说明定义文件没走贡献点注册。", "", ""))
			continue
		if def.op == &"":
			out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN,
				"节点 %s 没有声明算子（op 为空）" % id,
				"执行器拿到它只会报「缺少算子实现」。", def.source_file, owner))
			continue
		if not FxOpRegistry.has_op(def.op):
			out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN,
				"节点 %s 的算子 %s 没有实现" % [id, String(def.op)],
				"节点定义了但没人注册这个 op：算子表里查不到。", def.source_file, owner))
			continue
		var provider := String(_op_owner_of(String(def.op), owner))
		if not provider.is_empty():
			out.append(_finding(LEVEL_WARN, LAYER_PLUGIN,
				"节点 %s 定义在 %s，算子 %s 只由 %s 实现" % [id, owner, String(def.op), provider],
				"这是跨插件依赖，但 plugin.json 里没有声明 %s 的注入键：停用它时该节点会静默失效。"
					% provider,
				def.source_file, owner))
	return out


## 7) 绑定型参数（节点声明 `binds`）：文档里必须存 0。
##
## 这类参数读的是**文档某一处**的值（画布宽/高就是），不是自己的数据。
## 存了非 0 的覆盖值意味着「同一份事实有两个来源」：输出帧尺寸会和帧缓存的
## 定长布局不一致，每一帧都被尺寸闸门丢掉 —— 画面卡死、不报错、日志干净。
## 这类缺陷在注册表里看不出来，只有看文档才看得见，所以它需要 doc。
static func _check_bindings(doc: Dictionary) -> Array:
	var out: Array = []
	if doc.is_empty():
		return out
	for raw in doc.get("nodes", []):
		if not raw is Dictionary:
			continue
		var node: Dictionary = raw
		var node_id := String(node.get("id", ""))
		var params: Variant = node.get("params", {})
		if not params is Dictionary:
			continue
		var def: FxNodeDef = FxCatalog.def(node.get("type", ""))
		if def == null:
			continue
		for key in (params as Dictionary).keys():
			var path := String(key)
			var spec := def.param(path)
			var binds := String(spec.get("binds", ""))
			if binds.is_empty():
				continue
			var value := int(FxValue.as_number((params as Dictionary)[path], 0.0))
			if value == 0:
				continue
			out.append(_finding(LEVEL_ERROR, LAYER_PLUGIN,
				"节点 %s 的「%s」存了覆盖值 %d，而它只是 %s 的视图"
					% [node_id, String(spec.get("label", path)), value, binds],
				"清成 0，尺寸改到文档画布上：绑定型参数只有一个来源，两个来源会让输出帧尺寸与帧缓存布局对不上。",
				"节点 %s" % node_id, def.owner_plugin))
	return out


## 6) 版本：三套版本号是否齐备、插件版本是否可比较。
static func _check_contracts() -> Array:
	var out: Array = []
	var versions := read_versions()
	var kernel_version := String(versions.get("kernel", ""))
	if versions.is_empty():
		out.append(_finding(LEVEL_ERROR, LAYER_KERNEL,
			"缺少 %s：内核契约版本没有单一真源" % VERSION_FILE.replace("res://", ""),
			"建立 {app, kernel, project_format} 三个字段，诊断与宿主都读它。", ""))
		return out
	if not FxContract.is_valid(kernel_version):
		out.append(_finding(LEVEL_ERROR, LAYER_KERNEL,
			"内核契约版本 %s 不是可比较的版本号" % kernel_version,
			"用 x.y.z；预发布后缀写在后面（如 0.1.0-alpha）。", ""))
	var loose: Array[String] = []
	var unconstrained := 0
	for raw in FxRegistry.plugin_infos:
		var info: Dictionary = raw
		var pid := String(info.get("id", ""))
		var version := String(info.get("version", ""))
		if not FxContract.is_valid(version):
			loose.append("%s=%s" % [pid, version])
		var contract := ""
		var manifest := _manifest_of(pid)
		if manifest.get("contract", null) is String:
			contract = String(manifest["contract"])
		if contract.is_empty():
			unconstrained += 1
			continue
		if not FxContract.satisfies(kernel_version, contract):
			out.append(_finding(LEVEL_ERROR, LAYER_ASSEMBLY,
				"插件 %s 要求内核 %s，当前内核 %s" % [pid, contract, kernel_version],
				"版本不兼容：要么升级内核，要么停用该插件；不要靠「能跑就算过」。", "", pid))
	if not loose.is_empty():
		out.append(_finding(LEVEL_INFO, LAYER_PLUGIN,
			"%d 个插件的 version 不是三段式：%s" % [loose.size(), _join_head(loose, 6)],
			"两段式版本无法表达兼容区间；统一成 x.y.z。", ""))
	if unconstrained > 0:
		out.append(_finding(LEVEL_INFO, LAYER_ASSEMBLY,
			"%d/%d 个插件没有声明 contract（内核契约区间）" % [
				unconstrained, FxRegistry.plugin_infos.size()],
			"补 \"contract\": \">=0.1.0 <0.2.0\"，让「插件能不能装在这版内核上」可查。", ""))
	return out


# ================= 工具 =================

static func _finding(level: String, layer: String, message: String, hint: String,
		at: String = "", owner: String = "") -> Dictionary:
	return {"level": level, "layer": layer, "message": message,
		"hint": hint, "at": at, "owner": owner}


static func _level_rank(level: String) -> int:
	match level:
		LEVEL_ERROR:
			return 0
		LEVEL_WARN:
			return 1
	return 2


static func _join_head(items: Array[String], limit: int) -> String:
	if items.size() <= limit:
		return ", ".join(PackedStringArray(items))
	var head: Array[String] = []
	for i in range(limit):
		head.append(items[i])
	return "%s …" % ", ".join(PackedStringArray(head))


## 插件 id → 它声明的 class_name。基座一旦出现这些名字，就是跨界。
static func _plugin_class_owners() -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open(PLUGIN_ROOT)
	if dir == null:
		return out
	for plugin_id in dir.get_directories():
		var folder := "%s/%s" % [PLUGIN_ROOT, String(plugin_id)]
		var inner := DirAccess.open(folder)
		if inner == null:
			continue
		for file_name in inner.get_files():
			var name := String(file_name)
			if not name.ends_with(".gd"):
				continue
			var text := _read("%s/%s" % [folder, name])
			var at := text.find("class_name ")
			if at < 0:
				continue
			var rest := text.substr(at + "class_name ".length())
			var symbol := ""
			for i in range(rest.length()):
				var c := rest[i]
				if _is_word_char(c):
					symbol += c
				else:
					break
			if not symbol.is_empty():
				out[symbol] = String(plugin_id)
	return out


## op id → 提供它的**所有**插件。同一个 op 可以被多个插件实现（后者覆盖前者），
## 所以「覆盖者」不等于「唯一提供者」：停用覆盖者时原实现还在，不该报缺依赖。
static func _op_owners() -> Dictionary:
	var out: Dictionary = {}
	for raw in FxRegistry.ledger:
		var entry: Dictionary = raw
		if String(entry.get("kind", "")) != "op":
			continue
		var key := String(entry.get("key", ""))
		if key.is_empty():
			continue
		var pid := String(entry.get("owner", ""))
		if not out.has(key):
			out[key] = [] as Array
		var list: Array = out[key]
		if not list.has(pid):
			list.append(pid)
	return out


## 找一个「不是本插件」的实现者；本插件自己有实现就不算跨插件。
static func _op_owner_of(op_id: String, owner: String) -> String:
	var list: Array = _op_owners().get(op_id, [])
	if list.is_empty() or list.has(owner):
		return ""
	return String(list[0])


static func _manifest_of(plugin_id: String) -> Dictionary:
	var path := "%s/%s/plugin.json" % [PLUGIN_ROOT, plugin_id]
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## 从任意文本里认出插件：先认 plugins/<id>/ 路径，再认裸 id。
static func _owner_from_text(text: String) -> String:
	if text.is_empty():
		return ""
	var known: Array[String] = []
	for raw in FxRegistry.plugin_infos:
		known.append(String((raw as Dictionary).get("id", "")))
	for pid in known:
		if text.contains("plugins/%s/" % pid) or text.contains("plugins\\%s\\" % pid):
			return pid
	for pid2 in known:
		if pid2.is_empty():
			continue
		if text.contains(pid2):
			return pid2
	return ""


static func _gd_files(root: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	for file_name in dir.get_files():
		var name := String(file_name)
		if name.ends_with(".gd"):
			out.append("%s/%s" % [root, name])
	for sub in dir.get_directories():
		for nested in _gd_files("%s/%s" % [root, String(sub)]):
			out.append(nested)
	return out


static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


## 去掉注释，避免「文档里提到某个类名」被误判成代码依赖。
## 两种形态都要吃：整行注释（首个非空白字符就是 #）与行尾注释（# 前是空白）。
## 字符串里的 #（十六进制颜色、注释符号本身）前面是引号，不会被切掉。
static func _strip_comments(text: String) -> String:
	var out: Array[String] = []
	for line in text.split("\n"):
		var row := String(line)
		if row.strip_edges().begins_with("#"):
			out.append("")
			continue
		for i in range(row.length()):
			if row[i] != "#":
				continue
			if i == 0 or row[i - 1] == " " or row[i - 1] == "\t":
				row = row.substr(0, i)
				break
		out.append(row)
	return "\n".join(PackedStringArray(out))


static func _words_of(text: String) -> Dictionary:
	var out: Dictionary = {}
	var token := ""
	for i in range(text.length()):
		var c := text[i]
		if _is_word_char(c):
			token += c
			continue
		if not token.is_empty():
			out[token] = true
			token = ""
	if not token.is_empty():
		out[token] = true
	return out


static func _is_word_char(c: String) -> bool:
	if c.is_empty():
		return false
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
		or (c >= "0" and c <= "9") or c == "_"
