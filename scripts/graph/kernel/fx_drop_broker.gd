class_name FxDropBroker
extends RefCounted
## 拖拽导入的服务代理（论文 §6.2）。
##
## 蓝图只做三件事：算出落点的图坐标、把文件列表交给代理、把结果显示到状态栏。
## 「PNG 变纹理节点、图集变序列帧节点、以后还有什么格式」全在插件里，
## 停用插件后拖拽自然失效，蓝图代码一行都不用改。
##
## 贡献项（FxPlugin.drop_handlers()）：
##   {id, order, extensions: ["png", ...], handler(ctx) -> int|{count, message}}
## handler 拿到 ctx：{files, position, shell, store, editor}。
## extensions 省略表示「什么文件都接」（自己判断）。

static func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in FxRegistry.drop_handlers:
		out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


static func provider_ids() -> Array[String]:
	var out: Array[String] = []
	for entry in entries():
		out.append(String(entry.get("id", "")))
	return out


## 有没有 provider 能接这批文件（用于「不认识就别拦」）。
static func can_handle(files: Array) -> bool:
	for entry in entries():
		if _matches(entry, files):
			return true
	return false


static func handle(ctx: Dictionary) -> Dictionary:
	var files: Array = ctx.get("files", [])
	var last_message := ""
	for entry in entries():
		if not _matches(entry, files):
			continue
		var handler: Callable = entry.get("handler", Callable())
		if not handler.is_valid():
			continue
		var result: Variant = handler.call(ctx)
		if result is Dictionary:
			var data: Dictionary = result
			var count := int(data.get("count", 0))
			last_message = String(data.get("message", ""))
			if count > 0:
				return {"count": count, "message": last_message, "provider": String(entry.get("id", ""))}
		elif result is int and int(result) > 0:
			return {"count": int(result), "message": last_message, "provider": String(entry.get("id", ""))}
	return {"count": 0, "message": last_message}


## 声明的扩展名与落下的文件有交集才算命中；没声明扩展名的 provider 通吃。
static func _matches(entry: Dictionary, files: Array) -> bool:
	var wanted: Variant = entry.get("extensions", null)
	if not wanted is Array or (wanted as Array).is_empty():
		return true
	var allowed := {}
	for raw in wanted:
		allowed[String(raw).to_lower()] = true
	for raw2 in files:
		var path := String(raw2)
		var ext := path.get_extension().to_lower()
		if allowed.has(ext):
			return true
		# 目录拖进来时扩展名为空，交给 provider 自己看（图集目录 / 序列帧目录）。
		if ext.is_empty() and DirAccess.dir_exists_absolute(path):
			return true
	return false
