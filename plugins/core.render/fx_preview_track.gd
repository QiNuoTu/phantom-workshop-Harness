class_name FxPreviewTrack
extends RefCounted
## 缓存帧的**缩略图伴随层**：只保留「展开状态的节点」的小图。
##
## 为什么需要它：播放只读 `FxFrameCache`，缓存里只有整帧合成结果，
## 没有逐节点中间图。于是节点卡片上的预览在播放期间只能冻住 ——
## 用户看到的就是「动画在跑、小图不动」。
##
## 做法：预渲染在算每一帧时顺手把**展开节点**的缩略图留下来（收起的节点
## 连求值都不会做，`FxGraphRunner.preview_nodes` 直接跳过），播放推进到该帧
## 时把对应的一张图推给编辑器。收起的节点永远不产生、也不接收预览。
##
## 容量约束：帧数上限 + 总字节上限双向淘汰（先进先出）。缩略图只有几十像素，
## 60 帧 × 8 个展开节点通常不到 1 MB；纯内存层，不落盘。

## 帧数上限（环形淘汰）。
const DEFAULT_MAX_FRAMES := 240
## 字节上限，防止一次展开太多节点把内存吃掉。
const DEFAULT_MAX_BYTES := 24 * 1024 * 1024

var max_frames: int = DEFAULT_MAX_FRAMES
var max_bytes: int = DEFAULT_MAX_BYTES

var _frames: Dictionary = {}
var _order: Array[int] = []
var _bytes: int = 0
var _mutex := Mutex.new()


## 存一帧的缩略图集合（{node_id: Image}）。工作线程会并发调用。
func put(index: int, previews: Dictionary) -> void:
	if index < 0 or previews.is_empty():
		return
	var stored: Dictionary = {}
	var cost := 0
	for key in previews.keys():
		var image: Variant = previews[key]
		if not image is Image:
			continue
		var copy: Image = (image as Image).duplicate()
		if copy.is_empty():
			continue
		stored[String(key)] = copy
		cost += copy.get_width() * copy.get_height() * 4
	if stored.is_empty():
		return
	_mutex.lock()
	if _frames.has(index):
		_bytes -= int((_frames[index] as Dictionary).get("cost", 0))
		_order.erase(index)
	_frames[index] = {"cost": cost, "items": stored}
	_order.append(index)
	_bytes += cost
	while _order.size() > maxi(max_frames, 1) \
			or (_bytes > max_bytes and _order.size() > 1):
		var oldest: int = _order[0]
		_order.remove_at(0)
		var entry: Dictionary = _frames.get(oldest, {})
		_bytes -= int(entry.get("cost", 0))
		_frames.erase(oldest)
	_mutex.unlock()


## 取一帧的缩略图集合；没有就返回空字典。调用方只读，不要改图。
func get_frame(index: int) -> Dictionary:
	_mutex.lock()
	var entry: Dictionary = _frames.get(index, {})
	var items: Dictionary = entry.get("items", {})
	_mutex.unlock()
	return items


func has_frame(index: int) -> bool:
	_mutex.lock()
	var has := _frames.has(index)
	_mutex.unlock()
	return has


func clear() -> void:
	_mutex.lock()
	_frames.clear()
	_order.clear()
	_bytes = 0
	_mutex.unlock()


func stats() -> Dictionary:
	_mutex.lock()
	var out := {
		"frames": _frames.size(),
		"bytes": _bytes,
		"max_frames": max_frames,
		"max_bytes": max_bytes,
	}
	_mutex.unlock()
	return out
