class_name FxProjectArchive
extends RefCounted
## 工程包：`.fxproj`（ZIP）与 `.fxgraph`（纯文本）两种格式的全部读写逻辑。
##
## 纯文本的后缀就是 `.fxgraph`，内容本身是 JSON —— 不再缀一层 `.json` 造出
## `名字.fxgraph.json` 这种「后缀套后缀」的怪名字。老的 `.fxgraph.json`
## 仍然照常打开；另存时统一收成 `.fxgraph`。
##
## 与 FxDocumentActions（UI/命令）分开，是为了能在无头环境里被测试直接调用：
## 这一层不碰界面、不弹对话框，只做「文档 ↔ 文件」和依赖分析。
##
## .fxproj 布局：
##   project.fxgraph.json         图文档
##   manifest.json               资产 / 插件 / 支持版本清单
##   __phantom__/reserved.bin    512 字节预留区（版本写在最前面的 magic 里）
##   assets/<...>                打包进来的外部素材
##   plugins/<id>/...            打包进来的插件目录
##
## 预留区是刻意留白的：后面加签名、缩略图、校验和都不用换格式。
## 读不到版本号 → 视为老工程，直接用当前版本打开；版本不匹配 → 由 UI 询问。

const ZIP_EXT := "fxproj"
## 纯文本工程后缀。内容就是 JSON，但文件名不再多一个 `.json`。
const TEXT_EXT := "fxgraph"
## 兼容老工程：`.fxgraph.json` 读得开，写出去时收成 `.fxgraph`。
const LEGACY_TEXT_EXT := "fxgraph.json"
const HOST_VERSION := "1.0"
const SUPPORTED_VERSIONS := ["1.0"]
const ENTRY_DOC := "project.fxgraph.json"
const ENTRY_MANIFEST := "manifest.json"
const IMAGE_EXTS := ["png", "webp", "jpg", "jpeg", "bmp", "tga", "svg", "json", "ttf", "otf"]
const MAX_KEEP_AUTOSAVES := 20

static var _owner_cache: Dictionary = {}
## 便携版可能碰上只读的用户目录；探测一次，之后所有配置/解包都走可写根。
static var _writable_root: String = ""


static func is_zip_path(path: String) -> bool:
	return path.to_lower().ends_with("." + ZIP_EXT)


## 可写根：优先 user://，不行就退回 exe 旁边的 userdata/。
## 打包后的程序在某些受管环境里拿不到用户目录写权限，这时日志、最近列表、
## 解包出来的素材都得有个去处，而不是静默失败。
static func writable_root() -> String:
	if not _writable_root.is_empty():
		return _writable_root
	var probe := "user://.fx_write_probe"
	var file := FileAccess.open(probe, FileAccess.WRITE)
	if file != null:
		file.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(probe))
		_writable_root = "user://"
		return _writable_root
	var exe_dir := OS.get_executable_path().get_base_dir()
	if not exe_dir.is_empty():
		_writable_root = exe_dir.path_join("userdata")
		if not DirAccess.dir_exists_absolute(_writable_root):
			DirAccess.make_dir_recursive_absolute(_writable_root)
		return _writable_root
	_writable_root = "user://"
	return _writable_root


static func config_path(name: String) -> String:
	return writable_root().path_join(name)


static func normalize_path(path: String, as_zip: bool) -> String:
	var stem := stem_of(path)
	if stem.is_empty():
		return ""
	return stem + ("." + ZIP_EXT if as_zip else "." + TEXT_EXT)


## 这个路径是不是纯文本工程（新旧后缀都算）。
static func is_text_path(path: String) -> bool:
	var lower := path.strip_edges().to_lower()
	return lower.ends_with("." + TEXT_EXT) or lower.ends_with("." + LEGACY_TEXT_EXT)


## 去掉已知扩展名的部分（保存面板切格式时要用同一份规则）。
static func stem_of(path: String) -> String:
	var clean := path.strip_edges()
	if clean.is_empty():
		return ""
	var lower := clean.to_lower()
	# 先剥长的老后缀：`名字.fxgraph.json` 要一次剥成 `名字`，不能只掉 `.json`。
	if lower.ends_with("." + LEGACY_TEXT_EXT):
		return clean.substr(0, clean.length() - LEGACY_TEXT_EXT.length() - 1)
	if lower.ends_with("." + TEXT_EXT):
		return clean.substr(0, clean.length() - TEXT_EXT.length() - 1)
	if lower.ends_with("." + ZIP_EXT):
		return clean.substr(0, clean.length() - ZIP_EXT.length() - 1)
	if lower.ends_with(".json"):
		return clean.substr(0, clean.length() - 5)
	return clean


# ================= 版本 / 预留区 =================

## 加载前检查：{found, version, compatible, supported, source}。
## 版本只从 manifest.json 读；没有版本字段（老工程）就直接按当前版本打开。
static func version_status(path: String) -> Dictionary:
	var fallback := {"found": false, "version": "", "compatible": true,
		"supported": SUPPORTED_VERSIONS.duplicate(), "source": "", "error": ""}
	if not is_zip_path(path) or not FileAccess.file_exists(path):
		return fallback
	var reader := ZIPReader.new()
	var err := reader.open(path)
	if err != OK:
		fallback["error"] = error_string(err)
		return fallback
	var version := ""
	var source := ""
	if reader.file_exists(ENTRY_MANIFEST):
		var parsed: Variant = JSON.parse_string(reader.read_file(ENTRY_MANIFEST).get_string_from_utf8())
		if parsed is Dictionary:
			version = String((parsed as Dictionary).get("host_version", "")).strip_edges()
			if not version.is_empty():
				source = ENTRY_MANIFEST
	reader.close()
	if version.is_empty():
		return fallback
	return {
		"found": true,
		"version": version,
		"source": source,
		"compatible": SUPPORTED_VERSIONS.has(version),
		"supported": SUPPORTED_VERSIONS.duplicate(),
		"error": "",
	}


# ================= 写 =================

## options: {include_assets, include_plugins, exclude:[路径或插件 id], omit_version}
##
## 分两步：先 plan_zip() 纯计算出一条条待写条目，再写盘。
## 这样「同步一次写完」和「异步逐个写 + 报进度」共用同一份规划，
## 不会出现两条路径写出不同内容的包。
static func plan_zip(doc: Dictionary, options: Dictionary = {}) -> Dictionary:
	var final_path := normalize_path(String(options.get("path", "")), true)
	if final_path.is_empty():
		return {"ok": false, "message": "路径为空", "entries": [], "manifest": {}}
	var excluded := {}
	for raw in options.get("exclude", []):
		excluded[String(raw)] = true
	var manifest := {
		"format": "phantom.project",
		"version": 1,
		"app": "幻像工坊",
		"name": String(FxGraphDoc.meta_value(doc, "name", "未命名")),
		"host_version": String(options.get("version", HOST_VERSION)),
		"supported_versions": SUPPORTED_VERSIONS.duplicate(),
		"created": Time.get_datetime_string_from_system(false, true),
		"assets": [],
		"plugins": [],
		"excluded": Array(excluded.keys()),
	}
	var entries: Array = [{
		"name": ENTRY_DOC,
		"data": JSON.stringify(doc, "\t").to_utf8_buffer(),
		"kind": "doc",
	}]

	if bool(options.get("include_assets", true)):
		var index := 0
		for item in scan_dependencies(doc).get("assets", []):
			var asset: Dictionary = item
			var source := String(asset.get("path", ""))
			if excluded.has(source) or excluded.has(source.get_file()):
				continue
			var resolved := String(asset.get("resolved", ""))
			if resolved.is_empty() or not FileAccess.file_exists(resolved):
				continue
			var entry := "assets/%03d_%s" % [index, source.get_file()]
			entries.append({
				"name": entry,
				"data": FileAccess.get_file_as_bytes(resolved),
				"kind": "asset",
			})
			(manifest["assets"] as Array).append({
				"source": source, "entry": entry,
				"node": String(asset.get("node", "")), "param": String(asset.get("param", "")),
			})
			index += 1

	if bool(options.get("include_plugins", false)):
		for id in used_plugins(doc):
			if excluded.has(id):
				continue
			var dir := plugin_dir(id)
			if dir.is_empty():
				continue
			var files := _files_under(dir)
			if files.is_empty():
				continue
			for file_path in files:
				var rel := String(file_path).substr(dir.length() + 1)
				entries.append({
					"name": "plugins/%s/%s" % [id, rel],
					"data": FileAccess.get_file_as_bytes(String(file_path)),
					"kind": "plugin",
				})
			(manifest["plugins"] as Array).append(id)

	# omit_version 用来造「没有版本信息的老工程」做兼容测试。
	if bool(options.get("omit_version", false)):
		manifest.erase("host_version")
	entries.append({
		"name": ENTRY_MANIFEST,
		"data": JSON.stringify(manifest, "\t").to_utf8_buffer(),
		"kind": "manifest",
	})
	return {"ok": true, "path": final_path, "entries": entries,
		"manifest": manifest, "message": ""}


static func save_zip(doc: Dictionary, path: String, options: Dictionary = {}) -> Dictionary:
	var opts := options.duplicate(true)
	opts["path"] = path
	var plan := plan_zip(doc, opts)
	if not bool(plan.get("ok", false)):
		return {"ok": false, "message": String(plan.get("message", "保存失败"))}
	var final_path := String(plan["path"])
	var packer := ZIPPacker.new()
	var err := packer.open(final_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		return {"ok": false, "message": "ZIP 打不开：%s" % error_string(err)}
	packer.set_compression_level(6)
	for entry in plan["entries"]:
		var item: Dictionary = entry
		_add_entry(packer, String(item["name"]), item["data"])
	packer.close()
	return {"ok": true, "path": final_path, "manifest": plan["manifest"],
		"message": "已保存工程包：%s" % final_path.get_file()}


## 异步版：每写一个条目让出一帧，界面上的进度条能真的走起来。
## 调用方必须 `await`（保存面板就是这么用的）；无界面路径继续用 save_zip()。
static func save_zip_async(doc: Dictionary, path: String, options: Dictionary,
		on_step: Callable = Callable()) -> Dictionary:
	var opts := options.duplicate(true)
	opts["path"] = path
	var plan := plan_zip(doc, opts)
	if not bool(plan.get("ok", false)):
		return {"ok": false, "message": String(plan.get("message", "保存失败"))}
	var final_path := String(plan["path"])
	var entries: Array = plan["entries"]
	var packer := ZIPPacker.new()
	var err := packer.open(final_path, ZIPPacker.APPEND_CREATE)
	if err != OK:
		return {"ok": false, "message": "ZIP 打不开：%s" % error_string(err)}
	packer.set_compression_level(6)
	var total := entries.size()
	for i in range(total):
		var item: Dictionary = entries[i]
		_add_entry(packer, String(item["name"]), item["data"])
		if on_step.is_valid():
			on_step.call(i + 1, total, String(item["name"]))
			await next_frame()
	packer.close()
	return {"ok": true, "path": final_path, "manifest": plan["manifest"],
		"message": "已保存工程包：%s" % final_path.get_file()}


static func next_frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame


static func save_json(doc: Dictionary, path: String) -> int:
	return FxGraphDoc.save(doc, normalize_path(path, false))


static func _add_entry(packer: ZIPPacker, name: String, data: PackedByteArray) -> void:
	packer.start_file(name)
	packer.write_file(data)
	packer.close_file()


# ================= 读 =================

## 返回 {ok, doc, manifest, version_status, extracted_assets, bundled_plugins, message}
static func read_zip(path: String) -> Dictionary:
	var status := version_status(path)
	if not String(status.get("error", "")).is_empty():
		return {"ok": false, "message": String(status["error"]), "version_status": status}
	var reader := ZIPReader.new()
	var err := reader.open(path)
	if err != OK:
		return {"ok": false, "message": "ZIP 读不了：%s" % error_string(err), "version_status": status}
	if not reader.file_exists(ENTRY_DOC):
		reader.close()
		return {"ok": false, "message": "工程包里没有图文档", "version_status": status}
	var raw: Variant = JSON.parse_string(reader.read_file(ENTRY_DOC).get_string_from_utf8())
	if not raw is Dictionary:
		reader.close()
		return {"ok": false, "message": "图文档不是合法 JSON", "version_status": status}
	var doc := FxGraphDoc.normalize(raw)
	var manifest: Dictionary = {}
	if reader.file_exists(ENTRY_MANIFEST):
		var parsed: Variant = JSON.parse_string(reader.read_file(ENTRY_MANIFEST).get_string_from_utf8())
		if parsed is Dictionary:
			manifest = parsed

	# 素材解到 user://projects/<名字>/assets/，并把文档里的路径改成解出来的位置。
	var target_dir := writable_root().path_join("projects").path_join(path.get_file().get_basename())
	if not DirAccess.dir_exists_absolute(target_dir):
		DirAccess.make_dir_recursive_absolute(target_dir)
	var extracted: Array = []
	for item in manifest.get("assets", []):
		var asset: Dictionary = item
		var entry := String(asset.get("entry", ""))
		if entry.is_empty() or not reader.file_exists(entry):
			continue
		var to := target_dir.path_join(entry.get_file())
		var data: PackedByteArray = reader.read_file(entry)
		var out := FileAccess.open(to, FileAccess.WRITE)
		if out == null:
			continue
		out.store_buffer(data)
		out.close()
		_rebind_path(doc, String(asset.get("node", "")), String(asset.get("param", "")), to)
		extracted.append(to)
	var bundled: Array = []
	for plugin_id in manifest.get("plugins", []):
		bundled.append(String(plugin_id))
	reader.close()
	return {
		"ok": true, "doc": doc, "manifest": manifest,
		"version_status": status,
		"extracted_assets": extracted,
		"bundled_plugins": bundled,
		"message": "已加载工程包：%s" % path.get_file(),
	}


## 异步版解包：每解一个素材让出一帧，大工程的加载进度条能真的走。
## 与 read_zip 同语义（测试盯的是同步版），只是把「打开 → 读文档 → 解素材」
## 拆成三步上报；无界面路径继续用 read_zip()。
static func read_zip_async(path: String, on_step: Callable = Callable()) -> Dictionary:
	var status := version_status(path)
	if not String(status.get("error", "")).is_empty():
		return {"ok": false, "message": String(status["error"]), "version_status": status}
	var reader := ZIPReader.new()
	var err := reader.open(path)
	if err != OK:
		return {"ok": false, "message": "ZIP 读不了：%s" % error_string(err), "version_status": status}
	if not reader.file_exists(ENTRY_DOC):
		reader.close()
		return {"ok": false, "message": "工程包里没有图文档", "version_status": status}
	if on_step.is_valid():
		on_step.call(0, 1, "读取工程包")
	await next_frame()
	var raw: Variant = JSON.parse_string(reader.read_file(ENTRY_DOC).get_string_from_utf8())
	if not raw is Dictionary:
		reader.close()
		return {"ok": false, "message": "图文档不是合法 JSON", "version_status": status}
	var doc := FxGraphDoc.normalize(raw)
	if on_step.is_valid():
		on_step.call(0, 1, "解析图文档")
	await next_frame()
	var manifest: Dictionary = {}
	if reader.file_exists(ENTRY_MANIFEST):
		var parsed: Variant = JSON.parse_string(reader.read_file(ENTRY_MANIFEST).get_string_from_utf8())
		if parsed is Dictionary:
			manifest = parsed

	var target_dir := writable_root().path_join("projects").path_join(path.get_file().get_basename())
	if not DirAccess.dir_exists_absolute(target_dir):
		DirAccess.make_dir_recursive_absolute(target_dir)
	var extracted: Array = []
	var asset_entries: Array = manifest.get("assets", [])
	var total := maxi(asset_entries.size(), 1)
	for i in range(asset_entries.size()):
		var asset: Dictionary = asset_entries[i]
		var entry := String(asset.get("entry", ""))
		if entry.is_empty() or not reader.file_exists(entry):
			continue
		var to := target_dir.path_join(entry.get_file())
		var data: PackedByteArray = reader.read_file(entry)
		var out := FileAccess.open(to, FileAccess.WRITE)
		if out == null:
			continue
		out.store_buffer(data)
		out.close()
		_rebind_path(doc, String(asset.get("node", "")), String(asset.get("param", "")), to)
		extracted.append(to)
		if on_step.is_valid():
			on_step.call(i + 1, total, entry.get_file())
		await next_frame()
	var bundled: Array = []
	for plugin_id in manifest.get("plugins", []):
		bundled.append(String(plugin_id))
	reader.close()
	return {
		"ok": true, "doc": doc, "manifest": manifest,
		"version_status": status,
		"extracted_assets": extracted,
		"bundled_plugins": bundled,
		"message": "已加载工程包：%s" % path.get_file(),
	}


static func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return FxGraphDoc.normalize(raw) if raw is Dictionary else {}


## 用户手动修复某条素材路径：把文档里那个参数改成新文件。
static func repair_asset(doc: Dictionary, node_id: String, param_id: String, new_path: String) -> bool:
	return _rebind_path(doc, node_id, param_id, new_path)


static func _rebind_path(doc: Dictionary, node_id: String, param_id: String, value: String) -> bool:
	var node_data := FxGraphDoc.node(doc, node_id)
	if node_data.is_empty():
		return false
	var params: Dictionary = node_data.get("params", {})
	if not params.has(param_id):
		return false
	params[param_id] = value
	node_data["params"] = params
	return true


# ================= 依赖分析 =================

## 遍历参数里的路径 + 节点类型，得到 {assets, plugins, missing_assets, missing_plugins}。
##
## 只统计**输入**路径：`save` / `dir` 这类参数是「要写到哪」，打开工程时文件本来
## 就不存在，把它们算成缺失会让每个带导出节点的工程一开就报缺 5 个素材。
static func scan_dependencies(doc: Dictionary) -> Dictionary:
	var assets: Array = []
	var seen := {}
	for item in doc.get("nodes", []):
		var node_data: Dictionary = item
		var node_id := String(node_data.get("id", ""))
		var node_type := String(node_data.get("type", ""))
		var def := FxCatalog.def(node_type)
		var params: Dictionary = node_data.get("params", {})
		for key in params.keys():
			var value: Variant = params[key]
			if not value is String:
				continue
			var text := String(value).strip_edges()
			if text.is_empty() or not _looks_like_path(text) or seen.has(text):
				continue
			if _is_write_target(def, String(key)):
				continue
			seen[text] = true
			var resolved := _resolve_path(text)
			assets.append({
				"path": text, "resolved": resolved, "ok": not resolved.is_empty(),
				"node": node_id, "param": String(key),
			})
	var owners := plugin_owner_map()
	var used: Array[String] = used_plugins(doc)
	var installed := installed_plugins()
	var plugins: Array = []
	for id in used:
		plugins.append({"id": id, "installed": installed.has(id)})
	var missing_assets: Array = []
	for asset in assets:
		if not bool((asset as Dictionary).get("ok", false)):
			missing_assets.append(asset)
	var missing_plugins: Array = []
	for plugin in plugins:
		if not bool((plugin as Dictionary).get("installed", false)):
			missing_plugins.append(plugin)
	return {
		"assets": assets, "plugins": plugins,
		"missing_assets": missing_assets, "missing_plugins": missing_plugins,
		"plugin_types": owners,
	}


## 这个参数是「输出目标」而不是输入素材：save = 要写的文件，dir = 要写的目录。
## 判据来自节点定义里的 kind（声明式），不按类型 id 硬编码。
static func _is_write_target(def: FxNodeDef, param_id: String) -> bool:
	if def == null:
		return false
	var meta := def.param(param_id)
	return String(meta.get("kind", "")) in ["save", "dir"]


static func _looks_like_path(text: String) -> bool:
	if text.begins_with("res://") or text.begins_with("user://") or text.is_absolute_path():
		return true
	if text.contains("/") or text.contains("\\"):
		return IMAGE_EXTS.has(text.get_extension().to_lower())
	return IMAGE_EXTS.has(text.get_extension().to_lower())


static func _resolve_path(path: String) -> String:
	if FileAccess.file_exists(path):
		return path
	return FxResourceRoot.resolve(path)


## 节点类型 → 提供它的插件 id：从账本里的 node_file 贡献反查，只算一次。
static func plugin_owner_map() -> Dictionary:
	if not _owner_cache.is_empty():
		return _owner_cache
	for entry in FxRegistry.ledger:
		if String(entry.get("kind", "")) != "node_file":
			continue
		var owner := String(entry.get("owner", ""))
		var path := String(entry.get("value", ""))
		if owner.is_empty() or path.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not parsed is Dictionary:
			continue
		for item in (parsed as Dictionary).get("nodes", []):
			if item is Dictionary:
				_owner_cache[String((item as Dictionary).get("id", ""))] = owner
	return _owner_cache


static func invalidate_owner_map() -> void:
	_owner_cache.clear()


static func used_plugins(doc: Dictionary) -> Array[String]:
	var owners := plugin_owner_map()
	var out: Array[String] = []
	for item in doc.get("nodes", []):
		var type := String((item as Dictionary).get("type", ""))
		var owner := String(owners.get(type, ""))
		if not owner.is_empty() and not out.has(owner):
			out.append(owner)
	return out


static func installed_plugins() -> Array[String]:
	var out: Array[String] = []
	for info in FxRegistry.plugin_infos:
		if bool((info as Dictionary).get("enabled", true)):
			out.append(String((info as Dictionary).get("id", "")))
	return out


static func plugin_dir(id: String) -> String:
	for info in FxRegistry.plugin_infos:
		if String((info as Dictionary).get("id", "")) == id:
			return String((info as Dictionary).get("dir", ""))
	return ""


static func _files_under(dir: String) -> Array[String]:
	var out: Array[String] = []
	var pending: Array[String] = [dir]
	while not pending.is_empty():
		var current: String = pending.pop_back()
		for name in DirAccess.get_files_at(current):
			var file := String(name)
			if file.ends_with(".uid"):
				continue
			out.append(current.path_join(file))
		for name2 in DirAccess.get_directories_at(current):
			pending.append(current.path_join(String(name2)))
	return out


# ================= 增量保存 / 自动保存 =================

static func delta_path(project_path: String) -> String:
	return project_path + ".delta"


## 只记录相对基线变化的部分：改动的节点、删掉的节点、连线、meta 与输出。
static func make_delta(base: Dictionary, current: Dictionary) -> Dictionary:
	var delta := {"at": Time.get_datetime_string_from_system(false, true),
		"changed_nodes": [], "removed_nodes": [], "edges": [], "meta": {}, "output": ""}
	var old_nodes := {}
	for item in base.get("nodes", []):
		old_nodes[String((item as Dictionary).get("id", ""))] = item
	var now_ids := {}
	for item2 in current.get("nodes", []):
		var node_data: Dictionary = item2
		var id := String(node_data.get("id", ""))
		now_ids[id] = true
		var before: Variant = old_nodes.get(id, null)
		if before == null or JSON.stringify(node_data) != JSON.stringify(before):
			(delta["changed_nodes"] as Array).append(node_data.duplicate(true))
	for id2 in old_nodes.keys():
		if not now_ids.has(String(id2)):
			(delta["removed_nodes"] as Array).append(String(id2))
	if JSON.stringify(base.get("edges", [])) != JSON.stringify(current.get("edges", [])):
		delta["edges"] = current.get("edges", []).duplicate(true)
	if JSON.stringify(base.get("meta", {})) != JSON.stringify(current.get("meta", {})):
		delta["meta"] = (current.get("meta", {}) as Dictionary).duplicate(true)
	if String(base.get("output", "")) != String(current.get("output", "")):
		delta["output"] = String(current.get("output", ""))
	return delta


static func delta_empty(delta: Dictionary) -> bool:
	return (delta.get("changed_nodes", []) as Array).is_empty() \
		and (delta.get("removed_nodes", []) as Array).is_empty() \
		and (delta.get("edges", []) as Array).is_empty() \
		and (delta.get("meta", {}) as Dictionary).is_empty() \
		and String(delta.get("output", "")).is_empty()


static func apply_delta(base: Dictionary, delta: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	var nodes: Array = result.get("nodes", [])
	for id in delta.get("removed_nodes", []):
		for i in range(nodes.size() - 1, -1, -1):
			if String((nodes[i] as Dictionary).get("id", "")) == String(id):
				nodes.remove_at(i)
	for item in delta.get("changed_nodes", []):
		var node_data: Dictionary = item
		var id2 := String(node_data.get("id", ""))
		var replaced := false
		for i in range(nodes.size()):
			if String((nodes[i] as Dictionary).get("id", "")) == id2:
				nodes[i] = node_data.duplicate(true)
				replaced = true
				break
		if not replaced:
			nodes.append(node_data.duplicate(true))
	result["nodes"] = nodes
	if delta.has("edges"):
		result["edges"] = (delta["edges"] as Array).duplicate(true)
	if not (delta.get("meta", {}) as Dictionary).is_empty():
		result["meta"] = (delta["meta"] as Dictionary).duplicate(true)
	if String(delta.get("output", "")).is_empty() == false:
		result["output"] = String(delta["output"])
	return result


static func read_delta(project_path: String) -> Dictionary:
	var path := delta_path(project_path)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func write_delta(project_path: String, delta: Dictionary) -> Error:
	var file := FileAccess.open(delta_path(project_path), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(delta, "\t"))
	file.close()
	return OK


static func clear_delta(project_path: String) -> void:
	var path := delta_path(project_path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 自动保存：工程文件旁边建一个同名文件夹，文件名带时间戳。
static func autosave_dir(project_path: String) -> String:
	return project_path.get_base_dir().path_join(project_path.get_file().get_basename())


static func autosave_path(project_path: String) -> String:
	var d := Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d" % [
		int(d.get("year", 2026)), int(d.get("month", 1)), int(d.get("day", 1)),
		int(d.get("hour", 0)), int(d.get("minute", 0)), int(d.get("second", 0)),
	]
	return autosave_dir(project_path).path_join("%s_%s.%s" % [
		project_path.get_file().get_basename(), stamp, TEXT_EXT,
	])


static func write_autosave(project_path: String, doc: Dictionary) -> Dictionary:
	var dir := autosave_dir(project_path)
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var path := autosave_path(project_path)
	var err := FxGraphDoc.save(doc, path)
	if err != OK:
		return {"ok": false, "message": error_string(err)}
	_prune_autosaves(dir)
	return {"ok": true, "path": path, "message": "已自动保存 %s" % path.get_file()}


static func _prune_autosaves(dir: String) -> void:
	var files: Array[String] = []
	for name in DirAccess.get_files_at(dir):
		if is_text_path(String(name)):
			files.append(dir.path_join(String(name)))
	files.sort()
	while files.size() > MAX_KEEP_AUTOSAVES:
		var oldest: String = files.pop_front()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(oldest))
