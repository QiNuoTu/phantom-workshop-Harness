class_name TimelineOps
extends RefCounted
## 关键帧编辑的**唯一写入口**：纯函数式地改文档里的轨道，不碰界面、不认识节点视图。
##
## 为什么要有这一层：
##   · 时间线、右栏、脚本、AI 都可能改关键帧，但"移动一组帧之后索引怎么变、
##     撞到同一时刻谁覆盖谁、删空一条轨道该退回什么值"这些规则只能有一份；
##   · 面板拖动时需要**一次手势 = 一次落盘**（撤销栈才干净），所以这里收的是
##     "一批条目 + 一个增量"，而不是逐帧回调。
##
## 条目格式（与 UI 的选择集一致）：
##   {"node_id": String, "path": String, "index": int}
## 所有函数都返回**新的条目列表**（索引已按新顺序修正），调用方可直接拿去重建选择集。

const EPSILON: float = 0.0005


## 取某条轨道的定义 {track:[…], interp:…}；不存在返回空字典。
static func track_of(doc: Dictionary, node_id: String, path: String) -> Dictionary:
	var entry: Dictionary = FxGraphDoc.node(doc, node_id)
	if entry.is_empty():
		return {}
	var value: Variant = FxCatalog.value_at(entry.get("params", {}), path)
	if value is Dictionary and (value as Dictionary).has("track"):
		return value
	return {}


## 同一 (node, path) 的条目分组：{key: {"node_id","path","items":[{"index", …}]}}
static func _group(items: Array) -> Dictionary:
	var groups: Dictionary = {}
	for raw in items:
		if not raw is Dictionary:
			continue
		var item: Dictionary = raw
		var key: String = "%s/%s" % [String(item.get("node_id", "")), String(item.get("path", ""))]
		if not groups.has(key):
			groups[key] = {"node_id": String(item.get("node_id", "")),
				"path": String(item.get("path", "")), "indices": []}
		((groups[key] as Dictionary)["indices"] as Array).append(int(item.get("index", -1)))
	return groups


## 时间对齐：同一轨道里两条帧落在一起时，后来者覆盖先到的。
static func _dedupe(keys: Array) -> Array:
	var out: Array = []
	for raw in keys:
		if not raw is Array or (raw as Array).size() < 2:
			continue
		var entry: Array = [float(raw[0]), raw[1]]
		var replaced: bool = false
		for i in range(out.size()):
			if absf(float((out[i] as Array)[0]) - entry[0]) < EPSILON:
				out[i] = entry
				replaced = true
				break
		if not replaced:
			out.append(entry)
	out.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	return out


## 平移 / 改值。dt 秒，dv 是数值增量（区间帧两端一起动）。
## 返回新条目列表；顺序可能因为排序变化，索引已修正。
static func move(doc: Dictionary, items: Array, dt: float, dv: float) -> Array:
	var fresh: Array = []
	var groups: Dictionary = _group(items)
	for key in groups.keys():
		var group: Dictionary = groups[key]
		var node_id: String = String(group["node_id"])
		var path: String = String(group["path"])
		var def: Dictionary = track_of(doc, node_id, path)
		if def.is_empty():
			continue
		var keys: Array = (def["track"] as Array).duplicate(true)
		var picked: Dictionary = {}
		for raw_index in (group["indices"] as Array):
			var index: int = int(raw_index)
			if index < 0 or index >= keys.size():
				continue
			var entry: Array = keys[index]
			var moved: Array = [clampf(float(entry[0]) + dt, 0.0, _duration_of(doc)),
				_shift_value(entry[1], dv)]
			picked[index] = moved
		if picked.is_empty():
			continue
		# 未选中的帧保留原样，选中的换成新值；同一轨道里落点相撞时后者覆盖
		var merged: Array = []
		for i in range(keys.size()):
			merged.append(picked[i] if picked.has(i) else keys[i])
		var cleaned: Array = _dedupe(merged)
		def["track"] = cleaned
		# 修正索引：按"新时间 + 值"回查，避免排序后选择集错位
		for index in picked.keys():
			var target: Array = picked[index]
			var found: int = _find(cleaned, target)
			fresh.append({"node_id": node_id, "path": path, "index": found,
				"time": float(target[0]), "value": target[1]})
	return fresh


## 删除。返回删除后的剩余条目数（用于状态栏），并保证轨道不会变成"空轨道"。
static func remove(doc: Dictionary, items: Array) -> int:
	var removed: int = 0
	var groups: Dictionary = _group(items)
	for key in groups.keys():
		var group: Dictionary = groups[key]
		var node_id: String = String(group["node_id"])
		var path: String = String(group["path"])
		var def: Dictionary = track_of(doc, node_id, path)
		if def.is_empty():
			continue
		var keys: Array = (def["track"] as Array).duplicate(true)
		var indices: Array = (group["indices"] as Array).duplicate()
		indices.sort()
		indices.reverse()
		var last_value: Variant = null
		for raw_index in indices:
			var index: int = int(raw_index)
			if index < 0 or index >= keys.size():
				continue
			last_value = keys[index][1]
			keys.remove_at(index)
			removed += 1
		if keys.is_empty():
			# 删空 = 这一层不再动画：把最后那帧的值写成常量，
			# 而不是留下一条空轨道（采样会变成 0，画面会突然消失）。
			_set_param(doc, node_id, path, last_value if last_value != null else 0.0)
		else:
			def["track"] = keys
	return removed


## 复制一批帧（向后偏移 offset 秒，同一轨道内落点相撞则覆盖）。
static func duplicate_keys(doc: Dictionary, items: Array, offset: float) -> Array:
	var fresh: Array = []
	var groups: Dictionary = _group(items)
	for key in groups.keys():
		var group: Dictionary = groups[key]
		var node_id: String = String(group["node_id"])
		var path: String = String(group["path"])
		var def: Dictionary = track_of(doc, node_id, path)
		if def.is_empty():
			continue
		var keys: Array = (def["track"] as Array).duplicate(true)
		var clones: Array = []
		for raw_index in (group["indices"] as Array):
			var index: int = int(raw_index)
			if index < 0 or index >= keys.size():
				continue
			clones.append([clampf(float(keys[index][0]) + offset, 0.0, _duration_of(doc)),
				keys[index][1]])
		if clones.is_empty():
			continue
		var cleaned: Array = _dedupe(keys + clones)
		def["track"] = cleaned
		for clone in clones:
			fresh.append({"node_id": node_id, "path": path,
				"index": _find(cleaned, clone), "time": float(clone[0]), "value": clone[1]})
	return fresh


## 插一帧。time 会被夹进片长；同一时刻已有帧则覆盖。
static func add_key(doc: Dictionary, node_id: String, path: String, time: float,
		value: Variant) -> int:
	var entry: Dictionary = FxGraphDoc.node(doc, node_id)
	if entry.is_empty() or path == "":
		return -1
	var params: Dictionary = (entry.get("params", {}) as Dictionary).duplicate(true)
	var current: Variant = FxCatalog.value_at(params, path)
	var def: Dictionary = current if current is Dictionary and (current as Dictionary).has("track") else {}
	var keys: Array = (def.get("track", []) as Array).duplicate(true)
	var interp: String = String(def.get("interp", "ease"))
	keys = FxTracks.upsert(keys, clampf(time, 0.0, _duration_of(doc)), value,
		_duration_of(doc))
	FxCatalog.apply_path(params, path, {"track": keys, "interp": interp})
	entry["params"] = params
	# 找回落点索引，让调用方可以把新帧选上
	for i in range(keys.size()):
		if absf(float((keys[i] as Array)[0]) - clampf(time, 0.0, _duration_of(doc))) < 0.02:
			return i
	return keys.size() - 1


static func set_interp(doc: Dictionary, node_id: String, path: String, mode: String) -> bool:
	if not mode in ["ease", "linear", "step"]:
		return false
	var def: Dictionary = track_of(doc, node_id, path)
	if def.is_empty():
		return false
	def["interp"] = mode
	return true


## 某个时间点该显示的值（用于"在播放头打帧"与拖动时的读数）。
static func value_at(doc: Dictionary, node_id: String, path: String, time: float) -> Variant:
	var entry: Dictionary = FxGraphDoc.node(doc, node_id)
	if entry.is_empty():
		return null
	var current: Variant = FxCatalog.value_at(entry.get("params", {}), path)
	if current is Dictionary and (current as Dictionary).has("track"):
		return FxTracks.sample(current, time)
	return current


# ================= 内部 =================

static func _duration_of(doc: Dictionary) -> float:
	return maxf(FxTracks.number(doc.get("duration"), 1.0), 0.01)


static func _set_param(doc: Dictionary, node_id: String, path: String, value: Variant) -> void:
	var entry: Dictionary = FxGraphDoc.node(doc, node_id)
	if entry.is_empty():
		return
	var params: Dictionary = (entry.get("params", {}) as Dictionary).duplicate(true)
	FxCatalog.apply_path(params, path, value)
	entry["params"] = params


## 数值增量：标量直接加；区间两端一起加，宽度不变。
static func _shift_value(original: Variant, dv: float) -> Variant:
	if absf(dv) < 0.0000001:
		return original
	if original is Array and (original as Array).size() == 2:
		return [float((original as Array)[0]) + dv, float((original as Array)[1]) + dv]
	if original is bool:
		return original
	return FxTracks.number(original, 0.0) + dv


static func _find(keys: Array, target: Array) -> int:
	for i in range(keys.size()):
		if absf(float((keys[i] as Array)[0]) - float(target[0])) < EPSILON:
			return i
	return -1
