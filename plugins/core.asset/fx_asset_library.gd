class_name FxAssetLibrary
extends RefCounted
## pixelfx 序列帧素材库：扫描**本插件目录**下的 Aseprite JSON + PNG。
## 素材跟着插件走（plugins/core.asset/assets/handcrafted），不进 PCK，可整目录删除。
##
## 只做三件事：发现素材、按 id 取元数据、按帧号切出一张 Image。
## 不认识节点、画布或时间轴；渲染逻辑在 FxOpsAsset 里。
##
## 缓存策略：完整的 sprite sheet 很大（1280×1152），只保留最近 6 张；
## 帧图每次从 sheet 切 region，尺寸小、开销可接受，也避免 244 套素材全驻内存。

const ROOT_RELATIVE := "plugins/core.asset/assets/handcrafted"
const MAX_SHEETS := 6

static var _entries: Dictionary = {}
static var _order: Array[String] = []
static var _loaded: bool = false

static var _sheets: Dictionary = {}
static var _sheet_order: Array[String] = []
## 跨线程锁：预渲染的 2–6 条线程会**同时**取素材（不变量 31：这类按内容缓存的
## 东西必须自己保证并发安全，别指望「很少改，撞不上」）。
##
## 没有它时的真机表现：一条线程在 `_sheets` 里做 LRU 淘汰（`erase`），
## 另一条正在读同一格 —— C++ 里直接
## `ERROR: Parameter "_p" is null. at: _unref (core/variant/dictionary.cpp)`
## 然后进程被信号打死（exit 132/139），日志里只有一段看不懂的 backtrace。
## 那把锁只护**表结构**，解码（几十毫秒的 PNG）留在锁外，否则六条线程互相等。
static var _lock := Mutex.new()


static func ensure_loaded() -> void:
	_lock.lock()
	if _loaded:
		_lock.unlock()
		return
	_loaded = true
	_entries.clear()
	_order.clear()
	var roots := FxResourceRoot.existing_roots(ROOT_RELATIVE)
	for root in roots:
		# _scan → _register 在这把锁**里面**跑，所以 _register 自己不再取锁。
		_scan(root)
	_order.sort()
	var count := _order.size()
	_lock.unlock()
	print("FxAssetLibrary：%d 套 pixelfx 素材（%d 个资源根）" % [count, roots.size()])


## 安装/卸载素材包后重扫。返回逆操作不适用，扫描结果本身是派生值，重扫即可。
static func refresh() -> void:
	_lock.lock()
	_loaded = false
	_sheets.clear()
	_sheet_order.clear()
	_lock.unlock()
	ensure_loaded()


static func roots() -> Array[String]:
	return FxResourceRoot.existing_roots(ROOT_RELATIVE)


static func _scan(dir_path: String, root: String = "") -> void:
	var scan_root := root if not root.is_empty() else dir_path
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			if name != "." and name != "..":
				_scan(full, scan_root)
		elif name.to_lower().ends_with(".json"):
			_register(full, scan_root)
		name = dir.get_next()
	dir.list_dir_end()


static func _register(json_path: String, root: String) -> void:
	var text := FileAccess.get_file_as_string(json_path)
	if text.is_empty():
		return
	var raw: Variant = JSON.parse_string(text)
	if not raw is Dictionary:
		return
	var data: Dictionary = raw
	var frames_raw: Variant = data.get("frames", [])
	var frames: Array = []
	if frames_raw is Array:
		for item in frames_raw:
			if item is Dictionary:
				var rect: Dictionary = (item as Dictionary).get("frame", {})
				if rect is Dictionary and int(rect.get("w", 0)) > 0:
					frames.append(Rect2i(int(rect.get("x", 0)), int(rect.get("y", 0)),
						int(rect.get("w", 0)), int(rect.get("h", 0))))
	elif frames_raw is Dictionary:
		for key in (frames_raw as Dictionary).keys():
			var item2: Variant = (frames_raw as Dictionary)[key]
			if item2 is Dictionary:
				var rect2: Dictionary = (item2 as Dictionary).get("frame", {})
				if rect2 is Dictionary and int(rect2.get("w", 0)) > 0:
					frames.append(Rect2i(int(rect2.get("x", 0)), int(rect2.get("y", 0)),
						int(rect2.get("w", 0)), int(rect2.get("h", 0))))
	if frames.is_empty():
		return
	var rel := json_path.trim_prefix(root + "/").trim_prefix(root).trim_prefix("/").get_basename()
	var meta: Dictionary = data.get("meta", {})
	var pfx: Dictionary = meta.get("pixelfx", {})
	var id := String(pfx.get("id", rel))
	var image_name := String(meta.get("image", json_path.get_file().get_basename() + ".png"))
	var image_path := json_path.get_base_dir().path_join(image_name)
	if not FileAccess.file_exists(image_path):
		return
	var frame_size := Vector2i(frames[0].size.x, frames[0].size.y)
	var pfx_size: Variant = pfx.get("frameSize", null)
	if pfx_size is Array and (pfx_size as Array).size() >= 2:
		frame_size = Vector2i(int((pfx_size as Array)[0]), int((pfx_size as Array)[1]))
	var pivot := Vector2i(int(frame_size.x / 2), frame_size.y)
	var pfx_pivot: Variant = pfx.get("pivot", null)
	if pfx_pivot is Array and (pfx_pivot as Array).size() >= 2:
		pivot = Vector2i(int((pfx_pivot as Array)[0]), int((pfx_pivot as Array)[1]))
	var entry := {
		"id": id,
		"name": String(pfx.get("name", rel.get_file().capitalize())),
		"category": rel.get_slice("/", 0),
		"json_path": json_path,
		"image_path": image_path,
		"frames": frames,
		"frame_count": frames.size(),
		"frame_size": frame_size,
		"pivot": pivot,
		"fps": maxi(1, int(pfx.get("fps", 30))),
		"loop": bool(pfx.get("loop", true)),
	}
	if not _entries.has(id):
		_entries[id] = entry
		_order.append(id)


static func all() -> Array[Dictionary]:
	ensure_loaded()
	var out: Array[Dictionary] = []
	_lock.lock()
	for id in _order:
		var data: Variant = _entries.get(id)
		if data is Dictionary:
			out.append(data)
	_lock.unlock()
	return out


static func entry(id: String) -> Dictionary:
	ensure_loaded()
	_lock.lock()
	var data: Dictionary = _entries.get(id, {})
	_lock.unlock()
	return data


static func has(id: String) -> bool:
	ensure_loaded()
	_lock.lock()
	var found := _entries.has(id)
	_lock.unlock()
	return found


## 取整张 sheet（带 LRU）。返回 {image, frames, frame_size, pivot, fps, loop}。
##
## 读 / 解码 / 装表分三段：查表持锁（微秒级），解码在锁外（几十毫秒），
## 装表再持锁并做一次「别人是不是已经装好了」的复查。这样六条预渲染线程
## 不会因为一张 1280×1152 的 PNG 互相排队，也不会同时把它装两遍。
static func sheet(id: String) -> Dictionary:
	var data := entry(id)
	if data.is_empty():
		return {}
	var key := String(data.get("json_path", ""))
	_lock.lock()
	var hit: Variant = _sheets.get(key)
	_lock.unlock()
	if hit is Dictionary:
		return hit
	var image := Image.load_from_file(String(data.get("image_path", "")))
	if image == null:
		return {}
	var cached := {
		"image": image,
		"frames": data.get("frames", []),
		"frame_size": data.get("frame_size", Vector2i(128, 128)),
	}
	_lock.lock()
	# 锁外解码期间，另一条线程可能已经装好了同一张：以先到的为准。
	var existing: Variant = _sheets.get(key)
	if existing is Dictionary:
		_lock.unlock()
		return existing
	_sheets[key] = cached
	_sheet_order.append(key)
	while _sheet_order.size() > MAX_SHEETS:
		var oldest: String = _sheet_order.pop_front()
		_sheets.erase(oldest)
	_lock.unlock()
	return cached


## 按帧号切一张 Image。frame 会自动按素材帧数取模（loop）或夹取。
static func frame_image(id: String, frame: int, loop: bool = true) -> Image:
	var cached := sheet(id)
	if cached.is_empty():
		return null
	var frames: Array = cached.get("frames", [])
	if frames.is_empty():
		return null
	var index := frame
	if loop:
		index = posmod(index, frames.size())
	else:
		index = clampi(index, 0, frames.size() - 1)
	var rect: Rect2i = frames[index]
	return (cached.get("image") as Image).get_region(rect)
