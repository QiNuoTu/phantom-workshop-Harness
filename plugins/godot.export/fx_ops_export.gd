class_name FxOpsExport
extends RefCounted
## 导出 / 保存的**节点版本**。
##
## 「软件能做什么」与「图里能表达什么」应该是同一套东西：菜单上能导出，
## 图里就该有节点能导出，否则自动化、批处理、条件导出都得靠人工点菜单。
##
## 写盘是副作用，节点每帧都会被求值，所以统一用 `run` 开关 + 节流：
##   · `run` 默认 false —— 关着的时候不碰磁盘，播放预览绝对安全；
##   · `run` 可以打关键帧 / 接端口，于是「第 10 帧导出一次」也能表达；
##   · 同一个节点 + 同一个目标路径两次写之间至少间隔 MIN_INTERVAL_MS，
##     防止一直开着开关时每帧写一遍。
##
## 输出 ok / path / message 三个端口：下游（或预览节点）能看出到底成功没有。

const MIN_INTERVAL_MS := 1500

## "node_id|目标路径" -> 上次写盘的 ticks
static var _last_fire: Dictionary = {}


## 写图像：接一张图进来，存成 PNG（画布保真，不做任何重采样）。
static func export_image(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var path := _path_of(params, "path")
	if not _armed(node, path, params):
		return _idle(path)
	var image: Variant = inputs.get("image")
	if not image is Image:
		return _fail(ctx, path, "没有接图像输入")
	var err := (image as Image).save_png(path)
	if err != OK:
		# 目录不存在是常见原因，先建再试一次。
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		err = (image as Image).save_png(path)
	if err != OK:
		return _fail(ctx, path, "PNG 写入失败：%s" % error_string(err))
	return _done(ctx, path, "已导出图像：%s" % path.get_file())


## 整个时间轴的 PNG 序列（文件名带帧号，便于在别的软件里当序列读）。
static func export_sequence(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var dir := _path_of(params, "dir")
	if not _armed(node, dir, params):
		return _idle(dir)
	if ctx.doc.is_empty():
		return _fail(ctx, dir, "没有打开文档")
	var result := FxExportService.save_sequence(ctx.doc, dir)
	if not bool(result.get("ok", false)):
		return _fail(ctx, dir, String(result.get("message", "PNG 序列导出失败")))
	var files: Array = result.get("files", [])
	return {
		"ok": true,
		"path": dir,
		"message": String(result.get("message", "已导出 PNG 序列")),
		"count": float(files.size()),
	}


## 精灵表：整段动画拼成一张 PNG，并写同名的帧元数据 JSON。
static func export_sheet(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var path := _path_of(params, "path")
	if not _armed(node, path, params):
		return _idle(path)
	if ctx.doc.is_empty():
		return _fail(ctx, path, "没有打开文档")
	var result := FxExportService.save_sheet(ctx.doc, path)
	if not bool(result.get("ok", false)):
		return _fail(ctx, path, String(result.get("message", "精灵表导出失败")))
	var files: Array = result.get("files", [])
	return {
		"ok": true,
		"path": path,
		"message": String(result.get("message", "已导出精灵表")),
		"count": float(files.size()),
	}


## Godot 粒子场景：.tscn + 内嵌贴图 + 翻转书着色器。
static func export_godot(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var path := _path_of(params, "path")
	if not _armed(node, path, params):
		return _idle(path)
	if ctx.doc.is_empty():
		return _fail(ctx, path, "没有打开文档")
	if not path.ends_with(".tscn"):
		path += ".tscn"
	var result := FxParticleExport.export(ctx.doc, path, {
		"source": FxPortType.as_string(params.get("source", "sheet"), "sheet"),
		"columns": FxPortType.as_int(params.get("columns", 0), 0),
		"lifetime": FxPortType.as_number(params.get("lifetime", 0.0), 0.0),
		"amount": FxPortType.as_int(params.get("amount", 48), 48),
	})
	if not bool(result.get("ok", false)):
		return _fail(ctx, path, String(result.get("message", "粒子场景导出失败")))
	return {
		"ok": true,
		"path": path,
		"message": String(result.get("message", "已导出粒子场景")),
		"count": 0.0,
	}


## 保存当前文档（等价于「文件 → 保存」）：把这张图整体写成一个 .fxgraph。
## 用途是把「图生成图」串起来：跑一帧就落一份工程文件给别的工程嵌套。
static func save_doc(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var path := _path_of(params, "path")
	if not _armed(node, path, params):
		return _idle(path)
	if ctx.doc.is_empty():
		return _fail(ctx, path, "没有打开文档")
	if not path.to_lower().ends_with(".fxgraph") and not path.to_lower().ends_with(".json"):
		path += ".fxgraph"
	var err := FxGraphDoc.save(ctx.doc, path)
	if err != OK:
		return _fail(ctx, path, "文档写入失败：%s" % error_string(err))
	var count: int = (ctx.doc.get("nodes", []) as Array).size()
	return {
		"ok": true,
		"path": path,
		"message": "已保存文档：%s（%d 个节点）" % [path.get_file(), count],
		"count": float(count),
	}


## 测试用：清掉节流记录，让同一个节点可以立刻再写一次。
static func reset_limits() -> void:
	_last_fire.clear()


# ================= 内部 =================

static func _path_of(params: Dictionary, key: String) -> String:
	var raw := FxPortType.as_string(params.get(key, ""), "").strip_edges()
	if raw.is_empty():
		return ""
	# 允许相对路径：以 user:// 为根，避免写到只读目录。
	if raw.begins_with("res://") or raw.begins_with("user://") or raw.is_absolute_path():
		return raw
	return "user://exports/" + raw


## run 开着、且离上次写盘够久才真正动手。
static func _armed(node: Dictionary, path: String, params: Dictionary) -> bool:
	if not FxPortType.as_bool(params.get("run", false), false):
		return false
	if path.is_empty():
		return false
	var key := "%s|%s" % [String(node.get("id", "")), path]
	var now := Time.get_ticks_msec()
	if int(_last_fire.get(key, -1000000)) > now - MIN_INTERVAL_MS:
		return false
	_last_fire[key] = now
	return true


static func _idle(path: String) -> Dictionary:
	return {"ok": false, "path": path, "message": "", "count": 0.0}


static func _done(ctx: FxEvalContext, path: String, message: String) -> Dictionary:
	return {"ok": true, "path": path, "message": message, "count": 1.0}


static func _fail(ctx: FxEvalContext, path: String, message: String) -> Dictionary:
	ctx.warn(message)
	return {"ok": false, "path": path, "message": message, "count": 0.0}
