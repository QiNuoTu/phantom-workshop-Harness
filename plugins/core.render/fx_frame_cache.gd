class_name FxFrameCache
extends RefCounted
## 逐帧缓存：把「某一帧画出来是什么样」存到**一个紧密二进制文件**里。
##
## 三种状态（时间轴标尺上的小色块就是它）：
##   STATE_EMPTY   红 · 没算过
##   STATE_PENDING 黄 · 正在算 / 只算过低质量预览
##   STATE_READY   绿 · 已按精确质量算完（内存或磁盘里有一份）
##
## 为什么不一张帧一个 PNG：
##   · PNG 编码 192×108 实测 ~11ms/帧，60 帧就是 0.7 秒纯浪费；
##   · 60 个小文件各有一次 open/close，播放时随机读还要反复开文件；
##   · 紧密文件按「帧号 × 定长 = 偏移」直接 seek 一帧，零编码、零解码，
##     只需一次 open + 一次 get_buffer，帧数据就是 RGBA8 原始字节。
##
## 文件格式（单文件 frames.fxc，小端）：
##   [0..63]   头：magic/version/宽/高/帧数/帧字节数/fps/时长
##   [64..]    每帧 1 字节的位图（1 = 这一格已写入）
##   [64+N..]  N 个定长帧，每帧 w*h*4 字节 RGBA8
## 读第 i 帧 = seek(64 + N + i * frame_bytes) 后读 frame_bytes 字节。
##
## 位置与配额：
##   · 默认放在**软件本体 exe 同级**的 fx_cache/frames/ 下（无写权限或
##     从 Godot 编辑器运行时自动回退 user://，不污染引擎安装目录）；
##   · 可切到 user:// 或纯内存模式；纯内存模式按可配上限淘汰，避免占用过大；
##   · 磁盘模式按总大小上限做 LRU 自动清理（新桶建立 / 启动时各跑一次），
##     当前正在用的桶永不被清。
##
## 线程：预渲染线程调 put()，主线程读状态，状态都在互斥量里改；
## 磁盘写另有一把锁，6 条线程只会串行化那 83KB 的 seek+store。

const STATE_EMPTY := 0
const STATE_PENDING := 1
const STATE_READY := 2
## 只给界面看：有线程**正在**为这一格干活（预渲染 / 急件 / 实时候选）。
## 它不是缓存状态 —— 不落盘、不参与任何求值与分发判断，
## 所以绝不能用 `state()` 返回：播放的挂起条件会误以为「这一格已经有图了」。
const STATE_RENDERING := 3

const MAGIC := 0x43465846  # "FXFC"
## v2：v1 的位图把播放档急件也标成了精确帧，磁盘上留下一批「绿但其实糊」的帧。
## 抬版本让所有 v1 桶自动作废重算 —— 缓存可以重算，画面不能骗人。
const VERSION := 2
const HEADER_SIZE := 64
const FILE_NAME := "frames.fxc"

var enabled: bool = true
var root_dir: String = "user://cache/frames"
var location: String = "exe"
var max_disk_bytes: int = 512 * 1024 * 1024
var memory_budget: int = 128 * 1024 * 1024
var disk_enabled: bool = true

var _mutex := Mutex.new()
var _disk_mutex := Mutex.new()
var _fingerprint: String = ""
var _fps: int = 30
var _duration: float = 1.0
var _count: int = 0
var _states: PackedByteArray = PackedByteArray()
## 每帧是在哪个「内容身份」上算出来的。
##
## 为什么必须记：桶的重建按指纹走，可指纹只看「拓扑 + 参数 + 画布」的合成哈希，
## 而预渲染线程与主线程是并发的 —— 第 N 版文档算的帧，完全可能在这一桶里活到第 N+1 版。
## 只认「算它的那一刻的文档」才是安全的分发条件；否则屏幕上会出现一张
## 谁也不认领的旧图，而且它每次都「绿色就绪」，看着毫无异常。
var _identities: PackedInt64Array = PackedInt64Array()
## 这一格的垫图是按哪个画布倍率算的（0 = 不是垫图 / 不知道）。
## 它只服务「说清楚现在看到的是什么」：状态栏写「草稿 f0 1/8」，
## 比只说「草稿」有用得多 —— 用户要判断「还要不要再等」。
var _draft_scale: PackedFloat32Array = PackedFloat32Array()
## 谁正在算这一格（界面用的瞬时事实，不落盘）。由渲染服务每帧整批覆盖：
## 「谁在算」只有调度方知道，缓存只负责把它画出来，不负责猜。
var _rendering: PackedByteArray = PackedByteArray()
var _dir: String = ""
## index -> Image
var _memory: Dictionary = {}
var _memory_order: Array[int] = []
var _memory_bytes: int = 0
var _last_disk_write_ms: int = 0
var _disk_bytes_cache: int = -1
var _file_ready: bool = false
var _file_size: Vector2i = Vector2i.ZERO
## 当前桶的帧尺寸（来自文档画布）。紧密文件是定长偏移布局，
## 混入一张不同尺寸的图会整桶错位 —— 写和读都必须校验。
var _frame_size: Vector2i = Vector2i.ZERO
## 内容分段的哈希（nodes / edges / meta），只在换桶时算一次。
## 用途是归因：指纹变了到底是图变了、连线变了，还是 meta 抖了。
var _parts: Dictionary = {}
## 逐节点/逐连线的哈希（配合 `_parts` 定位「这一段里是谁变了」），同样只在换桶时算。
var _detail: Dictionary = {}
## 最近一次 prepare 的结果（`last_build()` 返回它）。诊断用，不在主路径上做判断。
var _last_build: Dictionary = {}


# ================= 配置 =================

## 由渲染服务每 0.25s 读设置后调用。root 变了会让下一次 prepare 换桶。
func configure(loc: String, max_mb: int, memory_mb: int) -> void:
	var new_root := _resolve_root(loc)
	_mutex.lock()
	var root_changed := new_root != root_dir
	root_dir = new_root
	location = loc
	max_disk_bytes = maxi(max_mb, 16) * 1024 * 1024
	memory_budget = maxi(memory_mb, 16) * 1024 * 1024
	disk_enabled = loc != "memory"
	if root_changed:
		_fingerprint = ""
		_dir = ""
		_disk_bytes_cache = -1
	_mutex.unlock()
	if root_changed:
		prune()


## exe 同级目录；开发工具 / 无写权限时回退，绝不把缓存丢进引擎安装目录。
static func _resolve_root(loc: String) -> String:
	if loc == "user":
		return "user://cache/frames"
	if loc == "memory":
		return "user://cache/frames"  # 不写盘，只是留一个名义路径
	var exe := OS.get_executable_path()
	var base := exe.get_base_dir()
	var tool := exe.get_file().to_lower()
	if tool.contains("godot") or Engine.is_editor_hint():
		return "user://cache/frames"
	var candidate := base.path_join("fx_cache").path_join("frames")
	# 真的试一次，Program Files 之类的只读位置会自动回退。
	var err := DirAccess.make_dir_recursive_absolute(candidate)
	if err != OK and not DirAccess.dir_exists_absolute(candidate):
		return "user://cache/frames"
	var probe := FileAccess.open(candidate.path_join(".write_test"), FileAccess.WRITE)
	if probe == null:
		return "user://cache/frames"
	probe.close()
	DirAccess.remove_absolute(candidate.path_join(".write_test"))
	return candidate


# ================= 生命周期 =================

func prepare(doc: Dictionary, fps: int, duration: float,
		frame_size: Vector2i = Vector2i.ZERO) -> void:
	var fp := fingerprint_of(doc, fps, duration)
	var count := maxi(int(round(maxf(duration, 0.0) * float(maxi(fps, 1)))), 1)
	_mutex.lock()
	var size_changed := frame_size.x > 0 and _frame_size.x > 0 and frame_size != _frame_size
	var changed := fp != _fingerprint or size_changed
	var fp_before := _fingerprint
	var count_before := _count
	var parts_before := _parts
	var detail_before := _detail
	_frame_size = frame_size
	_fingerprint = fp
	_fps = maxi(fps, 1)
	_duration = maxf(duration, 0.0)
	if not changed and _count == count:
		_mutex.unlock()
		_last_build = {
			"rebuilt": false, "cleared": 0,
			"fp_before": fp_before, "fp_after": fp,
			"count_before": count_before, "count_after": count,
			"parts_before": parts_before, "parts_after": _parts,
		}
		return
	_count = count
	_states = PackedByteArray()
	_states.resize(count)
	_states.fill(STATE_EMPTY)
	_rendering = PackedByteArray()
	_rendering.resize(count)
	_rendering.fill(0)
	# 身份不落盘：磁盘里的帧是不是当前文档的，由桶目录（指纹）自己保证。
	_identities = PackedInt64Array()
	_identities.resize(count)
	_identities.fill(-1)
	_draft_scale = PackedFloat32Array()
	_draft_scale.resize(count)
	_draft_scale.fill(0.0)
	_memory.clear()
	_memory_order.clear()
	_memory_bytes = 0
	_dir = root_dir.path_join(fp)
	_disk_bytes_cache = -1
	_file_ready = false
	_file_size = Vector2i.ZERO
	# 同一份文档以前算过：把紧密文件里已有的帧直接标绿，省掉重算。
	var ready := 0
	for index in _disk_indices():
		if index >= 0 and index < _count:
			_states[index] = STATE_READY
			ready += 1
	_parts = parts_of(doc)
	_detail = detail_of(doc)
	_mutex.unlock()
	_last_build = {
		"rebuilt": true, "cleared": maxi(0, count_before - ready),
		"fp_before": fp_before, "fp_after": fp,
		"count_before": count_before, "count_after": count,
		"parts_before": parts_before, "parts_after": _parts,
		"detail_before": detail_before, "detail_after": _detail,
		"ready_from_disk": ready, "frame_size": frame_size,
	}
	if disk_enabled:
		prune()


## 最近一次 `prepare` 的结果：是否真的换了桶、清掉几格、指纹与分段前后值。
## 只读快照，调用方（诊断）不需要理解桶的内部结构。
func last_build() -> Dictionary:
	return _last_build.duplicate(true)


static func fingerprint_of(doc: Dictionary, fps: int, duration: float) -> String:
	var raw := JSON.stringify(content_of(doc))
	return "%d_%d_%d" % [raw.hash(), maxi(fps, 1), int(round(maxf(duration, 0.0) * 1000.0))]


## 只保留「会改变像素」的字段：位置、尺寸、收起状态、分组框矩形都是纯布局。
## 拖动节点后指纹必须保持不变，否则整段缓存会因一次拖拽全部作废。
##
## 判据是「这个字段能不能改变输出的像素」，不是「它在不在文档里」：
##   · 节点 `pos`/`size` —— 卡片摆在哪、多大，不影响求值；
##   · 节点 `collapsed` —— 只决定卡片是否折叠，参数照样生效；
##   · 连线折点 `pos` —— 走线形状；
##   · 分组框 `rect` —— 框本身不参与求值，挪一下框不该让整段缓存作废。
## 反过来 `frames[].nodes`（成员归属）留在这里不管：它同样不影响像素，
## 但它跟着节点增删一起变，抹掉也省不下重建，留着让指纹更直观。
static func content_of(doc: Dictionary) -> Dictionary:
	var copy := doc.duplicate(true)
	for item in copy.get("nodes", []):
		var node_data: Dictionary = item
		node_data.erase("pos")
		node_data.erase("size")
		node_data.erase("collapsed")
		# 分辨率档**会**改变像素，所以不能像布局字段那样一律抹掉；
		# 但值为 1.0（等于没声明）时抹掉，这样旧工程与「显式写 1.0」指纹相同，
		# 不会因为一次无意义的回写把整段缓存白算一遍。
		# 就地判值而不调 FxGraphDoc：缓存层只该认数据结构，不该认识图插件的类。
		var raw_scale: Variant = node_data.get("res_scale", 1.0)
		if not (raw_scale is float or raw_scale is int) or float(raw_scale) >= 0.999:
			node_data.erase("res_scale")
	for item in copy.get("edges", []):
		(item as Dictionary).erase("pos")
	for item in copy.get("frames", []):
		(item as Dictionary).erase("rect")
	return copy


## 逐节点 / 逐连线的单独哈希：归因用。
## `parts_of` 只回答「哪一段变了」，这里回答「这一段里是谁变了」——
## 没有它，一个 103 节点的工程里改了哪一格只能靠猜。
## 键在页面内唯一且稳定：节点用 id，连线用「源:口>目标:口」。
static func detail_of(doc: Dictionary) -> Dictionary:
	var content := content_of(doc)
	var nodes := {}
	for item in content.get("nodes", []):
		var node_data: Dictionary = item
		nodes[String(node_data.get("id", ""))] = JSON.stringify(node_data).hash()
	var edges := {}
	for item in content.get("edges", []):
		var edge: Dictionary = item
		var key := "%s:%s>%s:%s" % [
			String(edge.get("from", "")), String(edge.get("from_port", "")),
			String(edge.get("to", "")), String(edge.get("to_port", "")),
		]
		edges[key] = JSON.stringify(edge).hash()
	return {"nodes": nodes, "edges": edges}


func fingerprint() -> String:
	return _fingerprint


## 内容分段哈希：图 / 连线 / meta 各一个。
## 只有归因才需要「指纹为什么变」——指纹本身是整体哈希，变了以后看不出是谁变的。
static func parts_of(doc: Dictionary) -> Dictionary:
	var content := content_of(doc)
	return {
		"nodes": JSON.stringify(content.get("nodes", [])).hash(),
		"edges": JSON.stringify(content.get("edges", [])).hash(),
		"meta": JSON.stringify(content.get("meta", {})).hash(),
	}


func frame_count() -> int:
	_mutex.lock()
	var value := _count
	_mutex.unlock()
	return value


## 当前桶的帧尺寸（= 定桶那一刻的文档画布）。
## 紧密文件是「帧号 × 定长 = 偏移」的布局，尺寸就是文件格式的一部分；
## 调度方必须能用它验证「画布改了，桶还是旧尺寸吗」。
func frame_size() -> Vector2i:
	_mutex.lock()
	var value := _frame_size
	_mutex.unlock()
	return value


## 整批覆盖「正在算哪些帧」。只影响界面着色，不改变任何缓存语义。
## 用整批覆盖而不是逐格置位/清除：调度方每帧都知道全貌，
## 逐格清除一旦漏掉一格，那一格就会永远橘着（比不显示更糟）。
func set_rendering(indices: Array) -> void:
	_mutex.lock()
	if _rendering.size() != _count:
		_rendering = PackedByteArray()
		_rendering.resize(_count)
		_rendering.fill(0)
	else:
		_rendering.fill(0)
	for item in indices:
		var index := int(item)
		if index >= 0 and index < _count:
			_rendering[index] = 1
	_mutex.unlock()


## 界面用的三色半状态：已就绪 > 正在算 > 缓存状态。
## 它回答的是「标尺这一格该画什么颜色」，不是「这一格能不能用」。
func display_state(index: int) -> int:
	_mutex.lock()
	var value := STATE_EMPTY
	if index >= 0 and index < _count:
		var base := int(_states[index])
		var busy := index < _rendering.size() and int(_rendering[index]) == 1
		value = base if base == STATE_READY else (STATE_RENDERING if busy else base)
	_mutex.unlock()
	return value


func fps() -> int:
	return _fps


func duration() -> float:
	return _duration


func dir_path() -> String:
	_mutex.lock()
	var value := _dir
	_mutex.unlock()
	return value


func file_path() -> String:
	var dir := dir_path()
	return "" if dir.is_empty() else dir.path_join(FILE_NAME)


## 并行预渲染开工前由主线程调一次：目录与紧密文件只建一次。
func ensure_dir() -> void:
	if not disk_enabled:
		return
	var dir := dir_path()
	if dir.is_empty():
		return
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)


func state(index: int) -> int:
	_mutex.lock()
	var value := STATE_EMPTY
	if index >= 0 and index < _count:
		value = int(_states[index])
	_mutex.unlock()
	return value


## 这一格的垫图倍率（0 = 精确帧或不知道）。
func draft_scale_of(index: int) -> float:
	_mutex.lock()
	var value := 0.0
	if index >= 0 and index < _draft_scale.size():
		value = float(_draft_scale[index])
	_mutex.unlock()
	return value


## 这一帧是在哪个内容身份上算出来的（-1 = 不知道，例如从磁盘恢复的老帧）。
func identity_of(index: int) -> int:
	_mutex.lock()
	var value := -1
	if index >= 0 and index < _identities.size():
		value = int(_identities[index])
	_mutex.unlock()
	return value


## 这一帧能不能当作「当前这份文档」的帧来用。
## identity < 0 表示调用方不关心内容身份（导出、纯时间轴巡检），一律放行。
func accepts(index: int, identity: int) -> bool:
	if identity < 0:
		return true
	var stamp := identity_of(index)
	# -1 = 从磁盘恢复的帧（没记身份）：桶目录本身就是内容指纹，
	# 属于这一桶即属于这份内容，放行；写过身份的必须逐字相符。
	return stamp < 0 or stamp == identity


func index_for_time(t: float) -> int:
	var count := frame_count()
	if count <= 0 or _fps <= 0:
		return 0
	return clampi(int(round(t * float(_fps))), 0, count - 1)


# ================= 写 / 读 =================

## exact = true：精确帧，标绿并落盘；false：低质量预览，只标黄并留在内存。
## force_disk 给预渲染用（顺序写，不走节流）。
func put(index: int, image: Image, exact: bool, force_disk: bool = false,
		identity: int = -1, draft_scale: float = 0.0) -> void:
	if not enabled or image == null or image.is_empty():
		return
	_mutex.lock()
	if index < 0 or index >= _count:
		_mutex.unlock()
		return
	# 拒绝异形帧：曾经有过「打开工程后快照没更新」的 bug，
	# 128×128 的旧文档结果会被写进 192×108 的桶，把定长文件整桶带坏。
	if _frame_size.x > 0 and (image.get_width() != _frame_size.x \
			or image.get_height() != _frame_size.y):
		_mutex.unlock()
		return
	if exact:
		_states[index] = STATE_READY
	elif int(_states[index]) == STATE_READY:
		# 这一格已经是精确帧了：糊的那张**连内存都不许进**。
		# 旧实现只挡「状态降级」，却照样把近似帧写进 `_memory[index]` ——
		# 状态还是绿，取出来却是播放档的糊图。表现是「导出与预览差几个字节」，
		# 以及「看着绿色就绪，按下去画面糊一下」。
		_mutex.unlock()
		return
	else:
		_states[index] = STATE_PENDING
	if index < _identities.size():
		_identities[index] = identity
	if not exact and index < _draft_scale.size():
		_draft_scale[index] = clampf(draft_scale, 0.0, 1.0)
	if _memory.has(index):
		var old: Image = _memory[index]
		_memory_bytes -= old.get_width() * old.get_height() * 4
	else:
		_memory_order.append(index)
	_memory[index] = image
	_memory_bytes += image.get_width() * image.get_height() * 4
	_trim_memory_locked()
	var write := disk_enabled and exact and (force_disk or _can_write_now_locked())
	if write:
		_last_disk_write_ms = Time.get_ticks_msec()
	_mutex.unlock()
	if write:
		_write_frame(index, image)


## 取一帧：内存优先，其次紧密文件按偏移直读（读出来顺手放进内存）。
## 不叫 get()：那是 Object 的保留方法，重写会改变引擎语义。
func fetch(index: int) -> Image:
	_mutex.lock()
	var expected := _frame_size
	if _memory.has(index):
		var hit: Image = _memory[index]
		# 内存层也必须过尺寸校验。旧实现只在磁盘那条路上校验，于是
		# 「画布改了、桶没换」的窗口里，内存里那张旧尺寸的图会被当成命中直接上屏：
		# 屏幕上是一张与画布无关的旧图，而所有状态都显示正常。
		if expected.x <= 0 or hit.get_size() == expected:
			_mutex.unlock()
			return hit
		_memory.erase(index)
		_memory_order.erase(index)
		_memory_bytes -= hit.get_width() * hit.get_height() * 4
	_mutex.unlock()
	if not disk_enabled:
		return null
	var image := _read_frame(index)
	if image != null:
		# 磁盘上可能是上一版留下的异形文件：读回尺寸不对就当没缓存，让后台补算。
		if expected.x > 0 and image.get_size() != expected:
			return null
		# 写回内存热层，但不要再触发一次磁盘写。
		_mutex.lock()
		if not _memory.has(index):
			_memory_order.append(index)
		else:
			_memory_bytes -= (_memory[index] as Image).get_width() * (_memory[index] as Image).get_height() * 4
		_memory[index] = image
		_memory_bytes += image.get_width() * image.get_height() * 4
		_trim_memory_locked()
		_mutex.unlock()
	return image


func has_frame(index: int) -> bool:
	return state(index) == STATE_READY


# ================= 统计 / 清理 =================

## 还有几帧没就绪（给「节点小图烘焙中」这类高频询问用）。
## 比 stats() 轻：不拼字典、不碰磁盘，只在锁里数一遍状态。
func missing() -> int:
	_mutex.lock()
	var ready := 0
	for i in range(_count):
		if int(_states[i]) == STATE_READY:
			ready += 1
	var value := maxi(_count - ready, 0)
	_mutex.unlock()
	return value


func stats(prefetch: Dictionary = {}) -> Dictionary:
	_mutex.lock()
	var ready := 0
	var pending := 0
	var rendering := 0
	for i in range(_count):
		if i < _rendering.size() and int(_rendering[i]) == 1 \
				and int(_states[i]) != STATE_READY:
			rendering += 1
		match int(_states[i]):
			STATE_READY:
				ready += 1
			STATE_PENDING:
				pending += 1
	var total := _count
	var bytes := _memory_bytes
	_mutex.unlock()
	return {
		"total": total,
		"ready": ready,
		"pending": pending,
		"rendering": rendering,
		"missing": maxi(total - ready, 0),
		"memory_bytes": bytes,
		"disk_bytes": disk_bytes(),
		"location": location,
		"disk_enabled": disk_enabled,
		"prefetch": prefetch,
		"enabled": enabled,
	}


func disk_bytes() -> int:
	_mutex.lock()
	if _disk_bytes_cache >= 0:
		var cached := _disk_bytes_cache
		_mutex.unlock()
		return cached
	_mutex.unlock()
	if not disk_enabled:
		return 0
	var path := file_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return 0
	var total := 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		total = int(f.get_length())
		f.close()
	_mutex.lock()
	_disk_bytes_cache = total
	_mutex.unlock()
	return total


## LRU 自动清理：按桶文件的修改时间从旧到新删，直到总大小回到预算内。
## 当前正在用的桶永远保留。新桶建立 / 启动 / 手动清理时各跑一次。
func prune() -> int:
	if not disk_enabled or not DirAccess.dir_exists_absolute(root_dir):
		return 0
	var current := dir_path()
	var entries: Array[Dictionary] = []
	var total := 0
	for name in DirAccess.get_directories_at(root_dir):
		var sub := root_dir.path_join(String(name))
		var path := sub.path_join(FILE_NAME)
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var size := int(f.get_length())
		f.close()
		total += size
		if sub == current:
			continue
		entries.append({"dir": sub, "size": size, "at": FileAccess.get_modified_time(path)})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["at"]) < int(b["at"]))
	var freed := 0
	for item in entries:
		if total <= max_disk_bytes:
			break
		var sub := String(item["dir"])
		var size := int(item["size"])
		_wipe_dir(sub)
		total -= size
		freed += size
	return freed


func clear() -> void:
	_mutex.lock()
	var dir := _dir
	_memory.clear()
	_memory_order.clear()
	_memory_bytes = 0
	if _count > 0:
		_states = PackedByteArray()
		_states.resize(_count)
		_states.fill(STATE_EMPTY)
		_rendering = PackedByteArray()
		_rendering.resize(_count)
		_rendering.fill(0)
	_disk_bytes_cache = 0
	_file_ready = false
	_mutex.unlock()
	if not dir.is_empty() and disk_enabled:
		_wipe_dir(dir)


func clear_all() -> int:
	var freed := 0
	clear()
	if disk_enabled and DirAccess.dir_exists_absolute(root_dir):
		for name in DirAccess.get_directories_at(root_dir):
			var sub := root_dir.path_join(String(name))
			freed += _dir_bytes(sub)
			_wipe_dir(sub)
	_mutex.lock()
	_disk_bytes_cache = 0
	_file_ready = false
	_mutex.unlock()
	return freed


## 磁盘上哪些帧已经写好了：读头 + 位图，不解码任何像素。
func _disk_indices() -> Array[int]:
	var out: Array[int] = []
	if not disk_enabled:
		return out
	var path := _dir.path_join(FILE_NAME) if not _dir.is_empty() else ""
	if path.is_empty() or not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var info := _read_header(f)
	if info.is_empty() or int(info["count"]) != _count:
		f.close()
		return out
	for i in range(_count):
		f.seek(HEADER_SIZE + i)
		if f.get_8() == 1:
			out.append(i)
	f.close()
	return out


# ================= 紧密文件内部 =================

func _read_header(f: FileAccess) -> Dictionary:
	if int(f.get_length()) < HEADER_SIZE or f.get_32() != MAGIC or f.get_32() != VERSION:
		return {}
	return {
		"width": f.get_32(), "height": f.get_32(),
		"count": f.get_32(), "frame_bytes": f.get_32(),
		"fps": f.get_32(), "duration_ms": f.get_32(),
	}


func _frame_offset(count: int, frame_bytes: int, index: int) -> int:
	return HEADER_SIZE + count + index * frame_bytes


func _ensure_file(size: Vector2i) -> String:
	var dir := dir_path()
	if dir.is_empty():
		return ""
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(FILE_NAME)
	var frame_bytes := size.x * size.y * 4
	var total := _frame_offset(_count, frame_bytes, _count)
	var exists := FileAccess.file_exists(path)
	var need_new := not (exists and _file_ready and _file_size == size)
	if not need_new:
		var check := FileAccess.open(path, FileAccess.READ)
		if check != null:
			var info := _read_header(check)
			check.close()
			need_new = info.is_empty() or int(info.get("width", 0)) != size.x \
				or int(info.get("height", 0)) != size.y \
				or int(info.get("count", 0)) != _count \
				or int(info.get("frame_bytes", 0)) != frame_bytes
	if need_new:
		var blank := PackedByteArray()
		# 头部前 32 字节已经由 8 次 store_32 写好，这里补齐到 64，
		# 后面依次是位图区与定长帧区。
		blank.resize(total - 32)
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return ""
		f.store_32(MAGIC)
		f.store_32(VERSION)
		f.store_32(size.x)
		f.store_32(size.y)
		f.store_32(_count)
		f.store_32(frame_bytes)
		f.store_32(_fps)
		f.store_32(int(round(_duration * 1000.0)))
		f.store_buffer(blank)
		f.flush()
		f.close()
		_file_ready = true
		_file_size = size
		_mutex.lock()
		_disk_bytes_cache = total
		_mutex.unlock()
	return path


func _write_frame(index: int, image: Image) -> void:
	_disk_mutex.lock()
	var size := Vector2i(image.get_width(), image.get_height())
	var path := _ensure_file(size)
	if path.is_empty():
		_disk_mutex.unlock()
		return
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		_disk_mutex.unlock()
		return
	var frame_bytes := size.x * size.y * 4
	var bytes := _rgba_bytes(image, size)
	f.seek(_frame_offset(_count, frame_bytes, index))
	f.store_buffer(bytes)
	f.seek(HEADER_SIZE + index)
	f.store_8(1)
	f.flush()
	f.close()
	_disk_mutex.unlock()


func _read_frame(index: int) -> Image:
	_disk_mutex.lock()
	var path := file_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		_disk_mutex.unlock()
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_disk_mutex.unlock()
		return null
	var info := _read_header(f)
	if info.is_empty() or int(info["count"]) != _count or index < 0 or index >= _count:
		f.close()
		_disk_mutex.unlock()
		return null
	f.seek(HEADER_SIZE + index)
	if f.get_8() != 1:
		f.close()
		_disk_mutex.unlock()
		return null
	var frame_bytes := int(info["frame_bytes"])
	f.seek(_frame_offset(_count, frame_bytes, index))
	var bytes := f.get_buffer(frame_bytes)
	f.close()
	_disk_mutex.unlock()
	if bytes.size() != frame_bytes:
		return null
	return Image.create_from_data(int(info["width"]), int(info["height"]),
		false, Image.FORMAT_RGBA8, bytes)


static func _rgba_bytes(image: Image, size: Vector2i) -> PackedByteArray:
	if image.get_format() == Image.FORMAT_RGBA8 and not image.is_compressed():
		return image.get_data()
	var copy: Image = image.duplicate()
	if copy.is_compressed():
		copy.decompress()
	copy.convert(Image.FORMAT_RGBA8)
	return copy.get_data()


# ================= 内部 =================

func _can_write_now_locked() -> bool:
	return Time.get_ticks_msec() - _last_disk_write_ms >= 220


func _trim_memory_locked() -> void:
	while _memory_bytes > memory_budget and _memory_order.size() > 1:
		var oldest: int = _memory_order.pop_front()
		if not _memory.has(oldest):
			continue
		var image: Image = _memory[oldest]
		_memory_bytes -= image.get_width() * image.get_height() * 4
		_memory.erase(oldest)


static func _dir_bytes(dir: String) -> int:
	var total := 0
	for name in DirAccess.get_files_at(dir):
		var f := FileAccess.open(dir.path_join(String(name)), FileAccess.READ)
		if f != null:
			total += int(f.get_length())
			f.close()
	return total


static func _wipe_dir(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for name in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(String(name)))
	DirAccess.remove_absolute(dir)
