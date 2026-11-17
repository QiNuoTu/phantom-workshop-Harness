class_name FxCacheTrace
extends RefCounted
## 帧缓存的归因日志：**只记事实，不做判断**。
##
## 为什么需要它：`prepares=24` 这类数字很容易测出来，但「谁在重建」只有加埋点才知道。
## 埋点写死在代码里就会长期污染主路径，而临时打印会改变时序、把被观测的现象本身赶跑。
## 所以这里把「重建」与「变更通知」都记进一个定长环形缓冲，诊断命令按需读取：
##
##   · `bucket` —— 帧缓存桶真的重建了（帧状态被清空、标尺绿格被抹掉）；
##   · `change` —— 文档变更通知到达，以及它被哪一道闸门挡下/放行。
##
## 代价：一次重建写一条字典（<1 KB），上限 128 条。重建本身是毫秒级动作，
## 记录开销可以忽略；不在每帧路径上（`change` 只在文档通知时写）。
##
## 它不判断「该不该重建」——那是 `diag.cache` 的活，归因逻辑演进不该动渲染主路径。

## 环形缓冲上限。够覆盖一次「打开工程 + 拖几下 + 改参数 + 播放」的操作序列。
const LIMIT := 128

const KIND_BUCKET := "bucket"
const KIND_CHANGE := "change"
## 一次「失效请求」：谁、要哪一档。桶没重建也可能有失效（比如只丢派生缓存），
## 这类事件不进 bucket 流，但同样是「一次操作引发的代价」，必须能看见。
const KIND_INVALIDATE := "invalidate"

static var _events: Array = []
static var _counts: Dictionary = {}
static var _dropped: int = 0


## 记一条。`data` 里不要放 Image / Node 之类的东西：这条记录可能被诊断打印出来。
static func record(kind: String, data: Dictionary) -> void:
	var entry := data.duplicate()
	entry["kind"] = kind
	entry["at"] = Time.get_ticks_msec() * 0.001
	_events.append(entry)
	if _events.size() > LIMIT:
		# 一次裁掉 1/4，避免每条都 slice 一次（重建风暴里这正好是最热的路径）。
		_events = _events.slice(_events.size() - (LIMIT * 3 / 4))
		_dropped += 1
	var key := kind
	if entry.has("reason"):
		key = "%s:%s" % [kind, String(entry["reason"])]
	_counts[key] = int(_counts.get(key, 0)) + 1


static func entries() -> Array:
	return _events.duplicate()


static func counts() -> Dictionary:
	return _counts.duplicate()


static func dropped() -> int:
	return _dropped


static func clear() -> void:
	_events = []
	_counts = {}
	_dropped = 0


## 按 kind 汇总（`bucket` / `change`），给报告做表头用。
static func count_of(kind: String) -> int:
	var total := 0
	for key in _counts.keys():
		var name := String(key)
		if name == kind or name.begins_with(kind + ":"):
			total += int(_counts[key])
	return total
