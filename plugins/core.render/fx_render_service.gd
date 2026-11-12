class_name FxRenderService
extends FxRenderHost
## 渲染管线服务：把“文档 + 时间”变成“最终图像 + 每个节点的预览”。
##
## 它是 `FxRenderHost` 的**插件侧实现**：基座只声明契约（store / playing /
## rendered / stats_changed / playback_changed / setup / apply_policy / invalidate），
## 停用本插件后外壳会自动拿到一个什么都不做的空呈现器，而不是崩掉。
##
## 这是基座里唯一知道何时该渲染的地方。面板不各自跑执行器：
##   · 图面板订阅 node_previewed 更新节点缩略图；
##   · 预览面板订阅 rendered 更新大图；
##   · 状态栏订阅 stats_changed 显示耗时/节点数。
##
## 播放策略（清晰度优先）现在**不再写死在这里**：
##   · 每帧向 FxQualityPolicy 代理询问一次策略；插件可以贡献 provider 局部覆盖
##     质量档、算子质量系数、预览上限、缓存、节流，以及任意自定义旋钮；
##   · 策略里的 options 原样注入 FxEvalContext，算子用 ctx.option() 读取；
##   · **输出链永不降采样**：output_final / 配方渲染始终保持画布全分辨率，
##     这一条是基座守住的不变量，插件不能覆盖；
##   · 渲染慢就按实测耗时自适应节流，不排队堆积，时间轴仍按真实时间推进。

signal node_previewed(node_id: String, image: Image)
## 本帧每个节点解析后的参数：被连线驱动的参数靠它实时显示上游值。
signal node_params_resolved(params_by_node: Dictionary)
## 帧缓存状态（已缓存 / 正在算 / 共多少帧）。时间轴标尺与状态栏都订阅它。
signal cache_changed(stats: Dictionary)
## 缓存帧的逐节点缩略图：只有**展开**的节点会出现在这里。
## 播放只读缓存，没有逐节点中间图，这个信号是「小图跟着动画动」的唯一来源。
signal frame_previews(index: int, previews: Dictionary)

## store / quality / playing / auto_render 与 rendered / stats_changed /
## playback_changed 三个信号都来自基座契约 FxRenderHost，这里不再重复声明。
var runner := FxGraphRunner.new()

## 后台线程求帧：界面线程不再被渲染阻塞。后端没声明 thread_safe 时自动关闭。
var threaded: bool = false
var _worker: FxRenderWorker = null
## 上一帧「必须主线程」的判定结果，用来发现前提翻转。
var _main_thread_blocked: bool = false
## 提交给工作线程的文档快照：只有文档真的变了才重新复制。
var _snapshot: Dictionary = {}
var _snapshot_rev: int = -1
var _pending_invalidate: bool = false
## 求帧世代：文档失效、播放启停都会 +1。工作线程的结果自带提交时的世代，
## 回来时不匹配就只归档进帧缓存，绝不发布 —— 否则「停止播放」后一个在途的
## 旧急件会把播放中某一帧当成暂停画面贴上来（用户看到的旧数据覆盖）。
var _epoch: int = 0

## 逐帧缓存与后台预渲染：让播放只读缓存、永不在界面线程求值。
var cache := FxFrameCache.new()
## 缓存帧的缩略图伴随层（只装展开节点的小图，纯内存、有容量上限）。
var previews := FxPreviewTrack.new()
var prefetcher: FxFramePrefetcher = null
## 编辑器报上来的「当前展开的节点」。收起的节点不该产生任何预览计算。
var _preview_focus: Array[String] = []
## 缩略图趟的节流：缺图时最多每 1.5 秒补起一趟，别让它把预渲染队列踢来踢去。
var _preview_pass_clock: float = 0.0
## 缩略图趟是否跑过：跑过还一张图都没收到，说明焦点节点没有图像输出，
## 这时要退避，不然播放期间会每隔 1.5 秒把整段重算一遍。
var _preview_pass_ran: bool = false
## 缩略图尺寸上限（像素）：小图看不出差别，越小小图趟越快。
const PREVIEW_THUMB := 72
## 每个节点最近一次「真的推出去了」小图对应的帧号。
## 节点卡片右上角那颗小圆点就靠它判断「这一帧的小图烘焙好了没有」——
## 状态必须是事实（小图真的到位了），不能靠「预渲染在跑」猜。
var _preview_frame: Dictionary = {}
## 曾经真的产出过小图的节点（不论哪一帧）。用来区分「这一帧还没算」与
## 「这个节点根本没有图像输出」—— 前者要显示等待，后者才显示灰色横杠。
var _preview_known: Dictionary = {}
## 最近一次推送的帧号：同一帧不重复推（暂停态巡检每 0.25s 会问一次）。
var _preview_sent: int = -1
var _cache_dirty: bool = true
## 上一次看到的文档内容身份。渲染只信它：通知说「变了」而身份没变时什么都不做。
var _content_seen: int = -1
var _cache_clock: float = 0.0
var _cache_emit_clock: float = 0.0
var _idle_clock: float = 0.0
## 文档「稳定期」计时：内容一改就归零，只有连续安静 CONTENT_SETTLE 秒才认为
## 这一版就是最终形态，才允许定桶与排队预渲染。
var _settle: float = 0.0
const CONTENT_SETTLE := 0.35
## 上一次看到的文档世代（content_key 高位）。世代变化 = 换文档，需要稳定期。
var _content_generation: int = -1
var _prefetch_reported: bool = false
var _prefetch_revision: int = -1
## 缓存开关（设置项 render.cache / render.prefetch），每 0.25s 读一次。
var _cache_on: bool = true
var _prefetch_on: bool = true
## 0 = 按 CPU 核数自动（最多 6 条并行线程）。
var _prefetch_workers: int = 0
## 空闲多久开始后台预渲染。文档一装载就排上，参数改动 0.18s 防抖后重排；
## 旧实现等 0.9s 且每次 set_time 都把计时归零，播放前后永远排不上。
const PREFETCH_IDLE_DELAY := 0.18
## 播放帧号：按帧号逐帧推进，绝不允许因为「这一帧算不出来」就跳号。
## 推进规则本身由 `FxClockBroker` 选出的时间插件提供（默认 core.timeline）；
## 这里只保存「当前该显示第几帧」这个组合结果，不实现时钟。
var _play_frame: int = 0
## 缺帧挂起的累计时长：超过 STALL_LIMIT 就放行一帧，避免缓存全红时永久卡住。
## 0.35 秒是「人耳能接受的停顿上限」：再久就不如放行、让画面稍微跳一下。
var _stall: float = 0.0
const STALL_LIMIT := 0.35
var clock: RefCounted = null
var _published_frame: int = -1
## 这一帧贴上去的是不是精确帧。贴的是播放档伴随图时，精确帧一到还要再贴一次，
## 否则屏幕上会永远留着那版糊的（用户说的「停下来还是糊的」）。
var _published_exact: bool = false
var _setting_play_time: bool = false
## 播放时「命中缓存 / 未命中」的计数，状态栏与诊断都会读。
var cache_hits: int = 0
var cache_misses: int = 0
## 贴的是伴随层（低质量预览）的次数：只用于诊断，永远不算「命中」。
var cache_approx: int = 0
## 预渲染还没追上时，把这些帧号优先补算（播放头附近优先）。
var _urgent_frame: int = -1
## 已经提交给工作线程的急件帧号，避免同一帧每 process 重复提交。
var _urgent_submitted: int = -1
var _stats_emit_clock: float = 0.0
## GPU 发布增强的结果按帧留一份：锐化是确定性纯函数，
## 播放循环第二圈起不该为同一帧再跑一次 compute。
var _display_cache: Dictionary = {}
var _display_fingerprint: String = ""
## 显示缓存的世代：内容（不是帧号）变了，整张表作废。
var _display_content: int = -1

var _dirty: bool = true
var _cooldown: float = 0.0
var _last_image: Image = null
var _last_stats: Dictionary = {}
var _last_node_params: Dictionary = {}
## 最近一次解析出的质量策略，供设置面板/诊断读取。
var policy: Dictionary = {}


func setup(p_store: FxDocumentStore) -> void:
	store = p_store
	if not store.changed.is_connected(_on_store_changed):
		store.changed.connect(_on_store_changed)
	if not runner.node_previewed.is_connected(_on_runner_preview):
		runner.node_previewed.connect(_on_runner_preview)
	# 轨道 solo/mute 由 store 持有，执行器只拿到一个谓词，核心不依赖 UI。
	runner.track_enabled = Callable(self, "_track_enabled")
	apply_policy()
	_configure_threading()
	_read_cache_settings()
	# 时间维度：向服务代理要一个时钟。插件被停用时用 core.render 的最小降级实现，
	# 保证「帧号连续」这条不变量始终成立，但基座里没有任何时间推进代码。
	clock = FxClockBroker.create()
	if clock == null:
		clock = FxLinearClock.create()
	_content_seen = store.content_key()
	_content_generation = int(_content_seen / 1048576)
	_prime_cache()


## 向多路代理询问本帧策略；ctx 只含事实，不含任何插件专有语义。
## 解析当前质量策略。force_paused 给后台预渲染用：它要算的是**与导出一致**的
## 精确帧，不能因为「此刻正好在播」就按播放档（quality=0）去算，
## 否则后台会把一堆低质量帧当成精确帧写满缓存。
func resolve_policy(force_paused: bool = false) -> Dictionary:
	var meta_seed: Variant = FxGraphDoc.meta_value(store.doc, "seed", 1) if store != null else 1
	var canvas := FxGraphDoc.canvas(store.doc) if store != null else Vector2i(128, 128)
	var nodes: Array = store.doc.get("nodes", []) if store != null else []
	return FxQualityPolicy.resolve({
		"playing": playing and not force_paused, "width": canvas.x, "height": canvas.y,
		"node_count": nodes.size(), "t": store.current_time if store != null else 0.0,
		"paused_quality": quality, "seed": meta_seed,
	})


func apply_policy() -> void:
	policy = resolve_policy()
	runner.quality = int(policy.get("quality", 1))
	runner.operator_quality = float(policy.get("operator_quality", 1.0))
	runner.options = policy.duplicate(true)
	runner.preview_limit = int(policy.get("preview_limit", 128))
	runner.capture_previews = bool(policy.get("capture_previews", true))
	runner.static_cache_enabled = bool(policy.get("static_cache", true))
	_apply_preview_scope()


## 线程开关：设置项 render.threaded + 后端是否声明 thread_safe。
## 关掉时退回主线程同步求帧 —— 行为一致，只是会占用界面时间。
func _configure_threading() -> void:
	var backend := FxRenderBroker.instance()
	var safe := backend != null and backend.has_method("thread_safe") \
		and bool(backend.call("thread_safe"))
	# 原生算子只要有一个声明了「非线程安全」，整条链就回主线程：
	# C++ 侧的可变状态不该由我们隔着 ABI 猜，宁可少一条线程也不冒险。
	# GPU 节点不再把整帧拉回主线程：它们通过 FxRenderGate 的 GPU 泵桥接，
	# 只占用主线程每帧几毫秒；600ms 的图求值始终留在工作线程。
	var want := bool(FxSettings.typed_value("render.threaded", true)) and safe \
		and FxNative.thread_safe()
	if want and _worker == null:
		var worker := FxRenderWorker.new()
		if worker.start():
			_worker = worker
	elif not want and _worker != null:
		_worker.stop()
		_worker = null
	threaded = _worker != null
	if not threaded:
		_snapshot = {}
		_snapshot_rev = -1


## 图里有没有 GPU 标记节点（诊断用）。
## 注意：这**不再**决定线程模型 —— GPU 节点改由 FxRenderGate 的主线程泵桥接。
##
## 不做缓存：修订号会把「换了一张图」和「同一张图改内容」混在一起（新建文档后
## 修订号同样从 0 开始），缓存过一次就会漏判。一张图几十个节点，逐帧扫一遍的
## 代价远小于「GPU 算子被丢到工作线程」的后果。
func _graph_needs_main_thread() -> bool:
	if store == null:
		return false
	for item in store.doc.get("nodes", []):
		if not (item is Dictionary):
			continue
		var def := FxCatalog.def(String((item as Dictionary).get("type", "")))
		if def != null and def.gpu:
			return true
	return false


func is_threaded() -> bool:
	return threaded


# ================= 帧缓存 / 预渲染 =================

func _read_cache_settings() -> void:
	_cache_on = bool(FxSettings.typed_value("render.cache", true))
	_prefetch_on = bool(FxSettings.typed_value("render.prefetch", true))
	_prefetch_workers = clampi(int(FxSettings.typed_value("render.prefetch_workers", 0)), 0, 8)
	cache.configure(
		String(FxSettings.typed_value("render.cache_location", "exe")),
		int(FxSettings.typed_value("render.cache_max_mb", 512)),
		int(FxSettings.typed_value("render.cache_memory_mb", 128)))
	cache.enabled = _cache_on


## 当前帧号（时间轴标尺上的小色块按它对齐）。
func frame_index() -> int:
	return cache.index_for_time(store.current_time) if store != null else 0


func frame_count() -> int:
	return cache.frame_count()


func cache_state(index: int) -> int:
	return cache.state(index)


func cache_stats() -> Dictionary:
	return cache.stats(prefetch_progress())


func prefetch_progress() -> Dictionary:
	return prefetcher.progress() if prefetcher != null else {}


func prefetching() -> bool:
	return prefetcher != null and prefetcher.active()


## 预渲染线程是否正忙（不论跑的是精确帧还是缩略图趟）。
func prefetcher_busy() -> bool:
	if prefetcher == null:
		return false
	return bool(prefetcher.progress().get("active", false))


## 手动预渲染：从头把整段动画算一遍（命令、菜单、设置面板都可以调）。
## 正在播 / 后端不能上线程 / 图里有 GPU 节点时不硬来，返回 false 让调用方提示。
## 编辑器告诉服务「哪些节点现在是展开的」。
## 只有它们需要随帧刷新的缩略图；收起的节点连预览求值都跳过。
## 焦点变化会作废旧图，并在播放中重起一趟缩略图预渲染。
func set_preview_focus(ids: Array) -> void:
	var next: Array[String] = []
	for raw in ids:
		var id := String(raw)
		if not id.is_empty() and not next.has(id):
			next.append(id)
	next.sort()
	if next == _preview_focus:
		return
	_preview_focus = next
	previews.clear()
	# 焦点一变，旧的「已烘焙」记录就不作数了：那颗小圆点必须回到未就绪。
	_preview_frame.clear()
	_preview_pass_clock = 0.0
	_preview_pass_ran = false
	# 不论在不在播都立刻备一趟：暂停时算好，按播放立刻就有小图。
	start_preview_pass()


func preview_focus() -> Array[String]:
	return _preview_focus.duplicate()


## 缩略图趟：用低质量、只算展开节点、**不写帧缓存**地把整段小图补齐。
## 它只服务于「播放中节点卡片跟着动画动」，与精确帧缓存互不覆盖。
func start_preview_pass() -> bool:
	if _preview_focus.is_empty() or store == null or store.doc.is_empty():
		return false
	# 先保精确帧：整段还没算完时不抢预渲染队列。
	if int(cache.stats().get("missing", 0)) > 0:
		return false
	if not _prefetch_allowed():
		return false
	_ensure_prefetcher()
	if prefetcher == null or prefetching():
		return false
	var tl := FxGraphDoc.timeline(store.doc)
	var fps := maxi(int(tl.get("fps", 30)), 1)
	var duration := maxf(float(tl.get("duration", 1.0)), 0.0)
	_cache_ensure_fingerprint(fps, duration)
	var focus: Dictionary = {}
	for id in _preview_focus:
		focus[id] = true
	_preview_pass_clock = 1.5
	_preview_pass_ran = true
	prefetcher.enqueue({
		"doc": store.doc.duplicate(true),
		"fps": fps,
		"count": cache.frame_count(),
		"from": 0,
		"priority": _play_frame if playing else 0,
		"signature": _doc_revision(),
		"fingerprint": cache.fingerprint(),
		"policy": resolve_policy(),
		"revision": FxRegistry.revision,
		"label": "缩略图",
		"quality": 0,
		"preview_only": true,
		"preview_nodes": focus,
		"preview_limit": PREVIEW_THUMB,
		"preview_track": previews,
	})
	return true


func start_prefetch(manual: bool = true) -> bool:
	if not manual and DisplayServer.get_name() == "headless":
		return false
	_ensure_prefetcher()
	if prefetcher == null or store == null or store.doc.is_empty():
		return false
	if prefetching():
		return true
	var tl := FxGraphDoc.timeline(store.doc)
	var fps := maxi(int(tl.get("fps", 30)), 1)
	var duration := maxf(float(tl.get("duration", 1.0)), 0.0)
	_cache_ensure_fingerprint(fps, duration)
	_prefetch_revision = FxRegistry.revision
	_prefetch_reported = true
	var priority := _urgent_frame
	if priority < 0 and playing:
		priority = _play_frame
	var focus: Dictionary = {}
	for id in _preview_focus:
		focus[id] = true
	prefetcher.enqueue({
		"doc": store.doc.duplicate(true),
		"fps": fps,
		"count": cache.frame_count(),
		"from": 0,
		"priority": priority,
		"preview_nodes": focus,
		"preview_limit": PREVIEW_THUMB,
		"preview_track": previews,
		"signature": _doc_revision(),
		"fingerprint": cache.fingerprint(),
		# 后台要的是精确帧：即便此刻正在播放，也按暂停档解析策略。
		"policy": resolve_policy(true),
		"revision": _prefetch_revision,
		"label": "预渲染",
	})
	return true


func cancel_prefetch() -> void:
	if prefetcher != null:
		prefetcher.cancel()
	_prefetch_reported = false


## 清理缓存：返回释放的磁盘字节数（状态栏报「释放了多少」）。
func clear_cache() -> int:
	cancel_prefetch()
	var freed := cache.clear_all()
	_cache_dirty = true
	_urgent_submitted = -1
	_published_frame = -1
	_display_cache.clear()
	_display_fingerprint = ""
	previews.clear()
	_emit_cache(true)
	return freed


func _ensure_prefetcher() -> void:
	if not _prefetch_allowed():
		if prefetcher != null:
			prefetcher.stop()
			prefetcher = null
			_prefetch_reported = false
		return
	if prefetcher != null:
		return
	var worker := FxFramePrefetcher.new()
	worker.bind(cache)
	if worker.start(_prefetch_workers):
		prefetcher = worker


func _prefetch_allowed() -> bool:
	if not _prefetch_on:
		return false
	# 预渲染线程只跑 CPU 求值（GPU 资源交给主线程的 postprocess 发布通道），
	# 因此不再要求「当前后端 thread_safe」。旧实现在 GPU 后端下直接禁用预渲染，
	# 于是切 GPU 就只剩主线程逐帧硬算 —— 既跳帧又卡 UI。
	# 播放期间也要继续补帧：那正是最需要缓存的时候。
	return FxNative.thread_safe()


## 每帧的缓存维护：指纹、预渲染进度、空闲调度。都很轻。
func _tick_cache(delta: float) -> void:
	if store == null:
		return
	_cache_emit_clock -= delta
	_cache_clock -= delta
	_idle_clock += delta
	_settle += delta
	_preview_pass_clock -= delta
	if _cache_clock <= 0.0:
		_cache_clock = 0.25
		_read_cache_settings()
		# 文档还在稳定期里就不定桶：装载工程之后参数面板还会回写一轮，
		# 现在算出的指纹大概率不是最终的，桶会被换掉、预渲染成果白费。
		if _settle >= CONTENT_SETTLE:
			var tl := FxGraphDoc.timeline(store.doc)
			_cache_ensure_fingerprint(maxi(int(tl.get("fps", 30)), 1),
				maxf(float(tl.get("duration", 1.0)), 0.0))
	if prefetcher != null:
		var p := prefetcher.progress()
		var still := bool(p.get("active", false))
		if still or _prefetch_reported:
			var finished := _prefetch_reported and not still
			if not still:
				_prefetch_reported = false
			_emit_cache(finished)
		if still and FxRegistry.revision != _prefetch_revision:
			# 插件刚被启停/重载：停掉这次预渲染，等新的执行器就绪再说。
			prefetcher.cancel()
			_prefetch_reported = false
	# 内容稳定后立刻把整段排上。播放期间也继续补：先算播放头后面的帧。
	# 注意只看 _cache_dirty（指纹是否就绪），不看 _dirty（是否还有一帧待重画）——
	# 旧实现用 _dirty 判断，而播放/交互永远有脏帧，预渲染几乎没机会启动。
	# 播放中且展开节点的缩略图还没就绪：补一趟「只算小图」的轻量预渲染。
	# 精确帧缓存已经在绿的时候它也会跑（缓存里没有逐节点中间图）。
	# 播放中要「当前帧的小图已经备好」，暂停中要「展开的节点有图可看」——
	# 两种情况都靠这一条补趟，否则展开节点后卡片会一直空着等下一次播放。
	var want_index := _play_frame if playing else frame_index()
	if not _preview_focus.is_empty() and _preview_pass_clock <= 0.0 \
			and not prefetcher_busy() and not previews.has_frame(want_index):
		if _preview_pass_ran and int(previews.stats().get("frames", 0)) == 0:
			# 跑过一趟却一张都没收到：焦点节点没有图像输出，退避半分钟。
			_preview_pass_clock = 30.0
		else:
			start_preview_pass()
	# 暂停态没有别的推送时机：缩略图趟备好了就把当前帧的小图交给卡片。
	if not playing:
		_emit_frame_previews(want_index)
	if not _prefetch_on or not auto_render:
		return
	if _idle_clock < PREFETCH_IDLE_DELAY or _cache_dirty:
		return
	if prefetching() or int(cache.stats().get("missing", 0)) == 0:
		return
	start_prefetch(false)


## 文档刚装载：把桶标记成待建，等稳定期结束后的巡检来定桶。
## 这里**不能**用「桶还空着就顺手建一个」的写法：打开工程前桶里是上一份文档
## （示例文档 30 帧），那样会跳过重建，于是帧数、指纹、标尺全停在上一份文档上，
## 预渲染也永远不会被判定成「缺帧」。归档侧已有稳定期保护，不会写入错误桶。
func _prime_cache() -> void:
	if store == null or store.doc.is_empty():
		return
	_cache_dirty = true
	_settle = 0.0


func _cache_ensure_fingerprint(fps: int, duration: float) -> void:
	if not _cache_dirty and cache.frame_count() > 0:
		return
	var before := cache.fingerprint()
	# 桶的帧尺寸来自文档画布：任何异形帧（旧文档 / 空文档求出来的）都不得写入。
	cache.prepare(store.doc, fps, duration, FxGraphDoc.canvas(store.doc))
	if cache.fingerprint() != before:
		# 图变了：手上那次预渲染算的是上一版画面，直接作废。
		cancel_prefetch()
	_cache_dirty = false


## 预渲染进度不经过 _publish（预览没重画），所以这里同时刷新一次统计条，
## 避免「标尺已经全绿、状态栏还停在 1/30」这种两张皮。
func _emit_cache(force: bool = false) -> void:
	if not force and _cache_emit_clock > 0.0:
		return
	_cache_emit_clock = 0.25
	var snapshot := cache.stats(prefetch_progress())
	cache_changed.emit(snapshot)
	var stats := _last_stats.duplicate()
	stats["cache"] = snapshot
	stats_changed.emit(stats)


## 文档修订号：快照只在修订号变化时重做（深拷贝有成本，不能每帧来一次）。
func _doc_revision() -> int:
	return store.content_key() if store != null else -1


func last_image() -> Image:
	return _last_image


func last_stats() -> Dictionary:
	return _last_stats


func last_node_params() -> Dictionary:
	return _last_node_params


func is_playing() -> bool:
	return playing


func set_playing(value: bool) -> void:
	if playing == value:
		return
	# 世代翻转：所有在途结果（播放急件 / 上一暂停态的实时求帧）立即变成历史。
	_epoch += 1
	playing = value
	var pinned := false
	if playing:
		# 从当前播放头对应的帧号起播，帧号连续；不取消后台预渲染 ——
		# 播放期间正是最需要把后面几帧补出来的时候。
		_play_frame = cache.index_for_time(store.current_time if store != null else 0.0)
		if clock != null:
			clock.call("reset", _play_frame)
		_published_frame = -1
		_published_exact = false
		cache_hits = 0
		cache_misses = 0
		cache_approx = 0
		_stall = 0.0
		_urgent_frame = -1
		_urgent_submitted = -1
		_last_stats.erase("cached")
		_last_stats.erase("frame")
		_last_stats.erase("buffering")
	else:
		_idle_clock = PREFETCH_IDLE_DELAY
		_published_frame = -1
		_urgent_frame = -1
		_urgent_submitted = -1
		_last_stats.erase("cached")
		_last_stats.erase("frame")
		_last_stats.erase("buffering")
		# 停止 = 立刻显示「当前播放头那一帧」。缓存命中就直接贴图，
		# 而且**不再重算**：暂停态那次 600ms 的交互求值是低质量预览，
		# 发布回来只会把刚定格好的精确缓存帧盖掉（用户看到的「旧数据覆盖」）。
		pinned = _show_frame_at_current_time()
	apply_policy()
	runner.invalidate_cache()
	if not pinned:
		# 只在当前帧还没算出来时才补算；命中缓存时保持精确帧不动。
		request_render()
	playback_changed.emit(playing)


## 停止播放时把画面钉在当前时间的帧上（只读缓存，不触发求值）。
func _show_frame_at_current_time() -> bool:
	if store == null or not _cache_on:
		return false
	var index := cache.index_for_time(store.current_time)
	# 只认精确帧：标成待补的（只有播放档预览）不算「这一帧好了」，
	# 否则停播定格会把一张糊图钉在屏幕上。
	if index < 0 or cache.state(index) != FxFrameCache.STATE_READY:
		return false
	var image := cache.fetch(index)
	if image == null:
		return false
	_publish_cached(image, index, true)
	return true


func toggle_playback() -> void:
	set_playing(not playing)


func request_render(debounce: float = 0.0) -> void:
	_dirty = true
	_cooldown = minf(_cooldown, debounce) if debounce > 0.0 else 0.0


func invalidate() -> void:
	runner.invalidate_cache()
	FxNodePreview.clear_cache()
	_cache_dirty = true
	_pending_invalidate = true
	_epoch += 1
	request_render()


## 单节点样张：给「添加节点」面板用。算不出来返回 null（面板会逐级回退）。
## 这就是「节点效果」的数据来源 —— 不是手画的示意图，是真的跑一遍这个节点的算子。
func preview_node(node_type: String, size: Vector2i, t: float = -1.0,
		use_cache: bool = true) -> Image:
	return FxNodePreview.render(node_type, size, t, use_cache)


## 节点能否生成样张（面板据此决定要不要请求，省一次渲染）。
func can_preview_node(node_type: String) -> bool:
	return FxNodePreview.can_render(node_type)


## 立即按指定质量渲染一帧（导出/测试用），不改变播放状态。
func render_once(t: float = -1.0, with_previews: bool = false, exact: bool = true) -> Image:
	var old_quality := runner.quality
	var old_previews := runner.capture_previews
	var old_operator := runner.operator_quality
	var old_options := runner.options
	runner.quality = 1 if exact else 0
	runner.capture_previews = with_previews
	# 导出必须精确：算子质量系数强制 1.0，其余自定义旋钮仍可用。
	runner.operator_quality = 1.0
	var export_options := resolve_policy()
	export_options["operator_quality"] = 1.0
	runner.options = export_options
	# 求帧委托给当前渲染后端；exact 帧永远不允许后端跳帧复用。
	var frame_time := store.current_time if t < 0.0 else t
	# 与后台求帧互斥：导出必须拿到一致的表与素材缓存。
	var gate := FxRenderGate.mutex()
	gate.lock()
	var result := FxRenderBroker.frame(store.doc, frame_time, export_options, runner,
		{"playing": false, "exact": exact})
	gate.unlock()
	runner.quality = old_quality
	runner.capture_previews = old_previews
	runner.operator_quality = old_operator
	runner.options = old_options
	var image: Variant = result.get("image")
	return image as Image


func _process(delta: float) -> void:
	if store == null:
		return
	# 主线程泵：把工作线程排队的设备请求处理掉（每帧限流）。
	# 基座不认识具体设备，没有插件注册时是一次空调用。
	FxRenderGate.pump_main_thread()
	_stats_emit_clock -= delta
	if playing:
		_advance_playback(delta)
	_cooldown -= delta
	_tick_cache(delta)
	# 线程前提会随运行期变化：新装/停用的原生插件可能声明非线程安全，
	# 图里也可能刚加/刚删掉 GPU 节点（着色器）。只在「前提翻转」时重配一次 ——
	# 每帧重配会反复起停线程，反而拖慢。
	var backend := FxRenderBroker.instance()
	var backend_unsafe := backend == null or not backend.thread_safe()
	var blocked := not FxNative.thread_safe() or backend_unsafe
	if blocked != _main_thread_blocked:
		_main_thread_blocked = blocked
		_configure_threading()
	if _worker != null:
		# 非阻塞取结果：工作线程算完一帧就发布，主线程从不等待它。
		var done := _worker.take_result()
		if not done.is_empty():
			# 播放时工作线程算的是「补帧急件」，只写缓存，不抢主画面。
			_publish(done, true, playing)
	# 播放 = 只读缓存。命中就贴图，没命中就保持上一帧并后台补算，
	# 界面线程永远不做 600ms 的逐像素求值。
	if playing:
		_serve_playback_frame()
		return
	if not auto_render or not _dirty or _cooldown > 0.0:
		return
	if _worker != null:
		# 同一时刻只跑一帧：忙的时候保持 dirty，算完立刻用最新状态重提。
		if not _worker.busy():
			_submit()
	else:
		_render()


# ================= 播放：帧号连续 + 只读缓存 =================

## 按真实时间推进，但**每个 process 至多跨一个帧号**。
## 界面掉帧时播放会变慢，可帧号永远连续（0→1→2…），不会出现 0→18 的跳帧。
##
## 还有一条更硬的不变量：**连一张垫图都没有的帧绝不放过去**。
## 旧实现「保持上一帧继续前进」，帧号虽然连续，但用户看到的是同一张图停了一下
## 然后动画跳过去 —— 那就是他们说的「播放会缺帧/闪一下」。现在缺帧时把时钟
## 钉在当前帧等它算好（等待超过 STALL_LIMIT 才放行一次，绝不卡死）；
## 已经有播放档垫图的帧照常推进（标尺上是黄格），精确帧算完再原地替换。
func _advance_playback(delta: float) -> void:
	var count := cache.frame_count()
	if count <= 0 or clock == null:
		return
	var fps := maxf(float(cache.fps()), 1.0)
	# 时间维度只回答「该不该进下一帧、帧号是多少」；空间维度（这一帧的图像）
	# 完全由帧缓存提供。两者在这里才被组合，互不持有对方的状态。
	if not bool(clock.call("advance", delta, fps, count)):
		return
	var next := int(clock.get("frame"))
	# 只有当这一帧**一张图都没有**时才挂起等：伴随层（播放档预览）有图就先贴上去，
	# 标尺上它仍是黄格，精确帧一到再原地换掉。这样既不会「停一下再跳」，
	# 也不会为了等精确帧把播放卡成幻灯片。
	if _cache_on and next != _published_frame \
			and cache.state(next) == FxFrameCache.STATE_EMPTY:
		_stall += delta
		if _stall < STALL_LIMIT:
			# 挂起：时钟退回当前帧，画面保持，后台补这一帧。
			clock.call("reset", _play_frame)
			_urgent_frame = next
			if _worker != null and not _worker.busy() and next != _urgent_submitted:
				_urgent_submitted = next
				_submit(next, "urgent")
			_note_buffering(next)
			return
	_stall = 0.0
	_play_frame = next
	# 时间轴 UI 要跟着走；但这只是一次「时间变化」，不能触发重算或打断预渲染。
	_setting_play_time = true
	store.set_time_silent(float(clock.call("time_of", _play_frame, fps)))
	_setting_play_time = false


## 播放帧服务：命中缓存直接贴图；没命中则保持上一帧，并把这一帧排成后台急件。
func _serve_playback_frame() -> void:
	var index := _play_frame
	# 同一帧已经贴过精确版就收手；贴的是伴随图时，精确帧一到还要再贴一次。
	if index == _published_frame and (_published_exact or not _cache_on):
		return
	var state := cache.state(index) if _cache_on else FxFrameCache.STATE_EMPTY
	var image: Image = cache.fetch(index) if _cache_on else null
	if image != null:
		var precise := state == FxFrameCache.STATE_READY
		if precise:
			cache_hits += 1
		else:
			# 有图可贴但只是播放档预览：画面不黑、不跳，但绝不记成「命中」。
			cache_approx += 1
		_published_frame = index
		_published_exact = precise
		_publish_cached(image, index, false, not precise)
		return
	_published_exact = false
	cache_misses += 1
	_urgent_frame = index
	# 未命中时不重算、不黑屏、不跳号；急件交给工作线程，算完写进对应帧的缓存。
	if _worker != null and not _worker.busy() and index != _urgent_submitted:
		_urgent_submitted = index
		_submit(index, "urgent")
	_note_buffering(index)


## 让状态栏知道「正在缓冲哪一帧」，但别每帧刷字符串。
func _note_buffering(index: int) -> void:
	if _stats_emit_clock > 0.0:
		return
	_stats_emit_clock = 0.2
	var stats := _last_stats.duplicate()
	stats["cache"] = cache.stats(prefetch_progress())
	stats["buffering"] = index
	stats_changed.emit(stats)


## 发布一张缓存帧：只做贴图 + 可选的 GPU 发布后处理，绝不重新求值、绝不写盘。
func _publish_cached(image: Image, index: int, paused: bool = false,
		approx: bool = false) -> void:
	# 所有已展开节点的缩略图都来自这里：不重新求值，只取缓存帧的伴随小图。
	_emit_frame_previews(index)
	var display := _gpu_display(index, image)
	_last_image = display
	var stats := _last_stats.duplicate()
	stats.erase("buffering")
	stats["cached"] = not paused
	stats["frame"] = index
	# approx = 这一帧只有播放档预览，精确版还在后台算。
	# 状态栏与测试都靠它区分「真的好了」和「先垫一张」。
	stats["approx"] = approx
	stats["exact_frame"] = not approx
	if paused:
		# 停止播放的「定格帧」不是播放命中：状态栏与测试都不该把它算进帧序列。
		stats["paused"] = true
	stats["ms"] = 0.0
	stats["cache"] = cache.stats(prefetch_progress())
	_last_stats = stats
	rendered.emit(display, stats)
	if _stats_emit_clock <= 0.0:
		_stats_emit_clock = 0.2
		stats_changed.emit(stats)
	_dirty = false
	_cooldown = 0.0


## 把某一帧的缩略图推给编辑器（只有展开的节点；收起的不在这里）。
## 幂等：同一帧重复调用只发一次，暂停态的巡检不会把卡片当鼓敲。
func _emit_frame_previews(index: int) -> void:
	if _preview_focus.is_empty() or index < 0:
		return
	var items := previews.get_frame(index)
	if items.is_empty():
		return
	if _preview_sent == index:
		return
	_preview_sent = index
	for key in items.keys():
		_preview_frame[String(key)] = index
		_preview_known[String(key)] = true
	frame_previews.emit(index, items)


## 某个节点当前帧的小图状态，连帧号一起给编辑器：
##   {"state": 2, "frame": 12} 第 12 帧的小图已经烘焙好（就是现在显示的那张）
##   {"state": 1, "frame": 13} 播放头在第 13 帧，这张还没算出来，要等
##   {"state": 3} 这个节点没有图像输出，小图永远是空的（灰）
##   {"state": 0} 没展开 / 没有焦点，不显示任何状态
func bake_info(node_id: String) -> Dictionary:
	if node_id.is_empty() or _preview_focus.is_empty() or not _preview_focus.has(node_id):
		return {"state": 0}
	var index := _play_frame if playing else frame_index()
	var baked := int(_preview_frame.get(node_id, -1))
	if baked == index:
		return {"state": 2, "frame": baked, "shown": baked}
	# 已经算出过小图（只是还差这一帧）→ 明确是「等这一帧」，同时说清画面停在哪帧。
	if _preview_known.has(node_id):
		return {"state": 1, "frame": index, "shown": baked}
	# 后台确实在忙也算「等」，不然用户看到灰点会以为这个节点废了。
	if prefetcher_busy() or (_worker != null and _worker.busy()) or cache.missing() > 0:
		return {"state": 1, "frame": index, "shown": baked}
	# 缩略图趟跑过却一张都没有：这些节点本来就没有图像输出。
	if _preview_pass_ran and int(previews.stats().get("frames", 0)) == 0:
		return {"state": 3}
	return {"state": 1, "frame": index}


## 兼容旧调用：只要状态数字。
func preview_state(node_id: String) -> int:
	return int(bake_info(node_id).get("state", 0))


## 发布前的显示副本：GPU 后处理（锐化等）是确定性的，同一帧算一次就够。
## 缓存键必须同时含**内容身份 + 帧号**：参数一改，帧号还是那一个，但画面已经不同了。
## 旧实现只用帧号当键、指纹变了才清，于是「改完参数第一帧」常常直接贴回旧图
## （用户看到的就是一闪而过的旧画面）。
func _gpu_display(index: int, image: Image) -> Image:
	var content := store.content_key() if store != null else 0
	if content != _display_content:
		_display_cache.clear()
		_display_content = content
		_display_fingerprint = cache.fingerprint()
	var key := "%d:%d" % [content, index]
	if _display_cache.has(key):
		return _display_cache[key] as Image
	var out := _postprocess(image)
	if _display_cache.size() < 512:
		_display_cache[key] = out
	return out


## 发布前的主线程通道：GPU 后端在这里跑几毫秒的 compute 增强。
## 缓存里始终存 CPU 原始帧（与导出一致），这里只影响显示。
func _postprocess(image: Image) -> Image:
	if image == null or image.is_empty():
		return image
	var backend := FxRenderBroker.instance()
	if backend == null:
		return image
	var out: Image = backend.postprocess(image, {"playing": playing, "publish": true})
	return out if out != null and not out.is_empty() else image


## 主线程同步求帧（无工作线程 / 导出 / 后端不可线程化时的路径）。
func _render() -> void:
	if store == null or store.doc.is_empty():
		return
	apply_policy()
	if _pending_invalidate:
		runner.invalidate_cache()
		_pending_invalidate = false
	var result := FxRenderBroker.frame(store.doc, store.current_time, policy, runner,
		{"playing": playing, "exact": false})
	_dirty = false
	# 同步路径的预览已由执行器信号发出，这里不再重复发。
	_publish(result, false)


## 把一帧结果广播出去。工作线程路径在这里补发节点预览（执行器在工作线程里，
## 不能直接发信号给 UI）。
func _publish(result: Dictionary, from_worker: bool, suppress_render: bool = false) -> void:
	# 结果必须同时属于「当前播放世代」和「当前文档」。
	# epoch 覆盖播放启停 / 文档失效；doc_key 覆盖「换了工程但世代没变」的情形
	# （attach 会把 revision 归零，早期版本因此一直复用启动时的空文档快照）。
	# 过期结果**直接丢弃** —— 连缓存都不写：它算的是另一份文档/另一帧，
	# 归档回去会把正确帧覆盖成旧数据，还会带坏紧密文件的定长布局。
	var job_epoch := int(result.get("epoch", -1))
	var job_key := int(result.get("doc_key", -1))
	if from_worker:
		if (job_epoch >= 0 and job_epoch != _epoch) \
				or (job_key >= 0 and job_key != _doc_revision()):
			return
	var raw: Image = result.get("image") as Image
	var params_by_node: Variant = result.get("node_params")
	if params_by_node is Dictionary:
		_last_node_params = params_by_node
	var stats: Variant = result.get("stats")
	_last_stats = stats if stats is Dictionary else {}
	_last_stats["quality"] = runner.quality
	_last_stats["operator_quality"] = runner.operator_quality
	if from_worker:
		var previews: Variant = result.get("previews")
		if previews is Dictionary:
			var index_for_preview := int(result.get("frame_index", -1))
			for key in (previews as Dictionary).keys():
				var preview: Variant = (previews as Dictionary)[key]
				if preview is Image:
					_preview_frame[String(key)] = index_for_preview
					_preview_known[String(key)] = true
					node_previewed.emit(String(key), preview)
	# 缓存里存的是**CPU 原始帧**（与导出逐像素一致），GPU 发布增强只影响显示。
	_archive_result(result)
	if _cache_on:
		_last_stats["cache"] = cache.stats(prefetch_progress())
	# 交互帧与缓存帧走**同一个**显示通道：同一帧无论从哪条路径发布，
	# 过不过 GPU 后处理必须一致，否则起播/暂停瞬间会闪一下（细节突然变锐/变钝）。
	var index := int(result.get("frame_index", -1))
	if index < 0 and store != null:
		index = cache.index_for_time(store.current_time)
	_last_image = _gpu_display(index, raw) if index >= 0 else _postprocess(raw)
	if not suppress_render:
		rendered.emit(_last_image, _last_stats)
		if _stats_emit_clock <= 0.0:
			_stats_emit_clock = 0.2
			stats_changed.emit(_last_stats)
		node_params_resolved.emit(_last_node_params)
	# 有算子说「这一帧还没准备好」：把它当脏帧，下一帧自动补算（不推进时间）。
	if FxRenderGate.take_reframe():
		_dirty = true
		_cooldown = 0.0
	var ms := float(_last_stats.get("ms", 0.0))
	# 自适应节流只约束「交互重算」；播放期只读缓存，不参与节流，
	# 否则一次 600ms 的求值会把后面十几帧全部挡掉 —— 那正是旧的跳帧来源。
	if suppress_render or not playing or not bool(policy.get("adaptive_throttle", true)):
		_cooldown = 0.0
	else:
		_cooldown = maxf(0.033, ms * float(policy.get("throttle_factor", 0.0006)))


## 把一帧结果归档进帧缓存（不发布）。结果自带帧号：播放时补算的急件必须
## 写回它自己的那一格，不能按「结果回来时的播放头」乱放。
func _archive_result(result: Dictionary) -> void:
	if not _cache_on:
		return
	# 桶还没定下来（刚换文档，稳定期没结束）时不要归档：
	# 这一帧算的是新文档，写进去只会污染上一份文档的桶。
	if _cache_dirty and _settle < CONTENT_SETTLE:
		return
	var raw: Image = result.get("image") as Image
	if raw == null:
		return
	var tl: Dictionary = FxGraphDoc.timeline(store.doc) if store != null else {}
	_cache_ensure_fingerprint(maxi(int(tl.get("fps", 30)), 1),
		maxf(float(tl.get("duration", 1.0)), 0.0))
	var index := int(result.get("frame_index", -1))
	if index < 0:
		index = cache.index_for_time(store.current_time if store != null else 0.0)
	# 「是不是精确帧」由**算它的那一档质量**决定，而不是由「结果回来时在不在播」猜。
	# 播放急件跑在播放档（quality=0、算子 0.5）：这种帧只能进伴随层（黄），
	# 绝不能标绿。旧实现按 exact 一视同仁，于是标尺上还没算的那一段提前变绿，
	# 用户按下去等来的却是糊图 —— 这就是「需要等待的帧提前变绿」。
	var frame_quality := int(result.get("frame_quality", runner.quality))
	var frame_operator := float(result.get("frame_operator_quality", runner.operator_quality))
	var precise := frame_quality >= 1 and frame_operator >= 0.999
	var exact := precise and (bool(result.get("exact", false)) or not playing)
	var was_ready := cache.state(index) == FxFrameCache.STATE_READY
	cache.put(index, raw, exact, false)
	# 状态真的变了就顺手推一次统计：标尺已经绿了、底栏还停在旧数字，
	# 是用户最容易当场发现的那种「两张皮」。_emit_cache 自带 0.25s 节流。
	if exact and not was_ready:
		_emit_cache()


## 提交一帧给工作线程。文档快照与 mute/solo 都转成纯数据，
## 工作线程不回调任何主线程对象。
func _submit(frame_index: int = -1, purpose: String = "live") -> void:
	if store == null or store.doc.is_empty():
		return
	apply_policy()
	var rev := _doc_revision()
	if rev != _snapshot_rev or _snapshot.is_empty():
		_snapshot = store.doc.duplicate(true)
		_snapshot_rev = rev
	_dirty = false
	var invalidate := _pending_invalidate
	_pending_invalidate = false
	var t := store.current_time
	var index := frame_index
	if index >= 0:
		var fps := maxf(float(cache.fps()), 1.0)
		t = float(clock.call("time_of", index, fps)) if clock != null \
			else float(index) / fps
	else:
		index = cache.index_for_time(t)
	_worker.submit({
		"doc": _snapshot,
		"t": t,
		"frame_index": index,
		"signature": rev,
		"quality": runner.quality,
		"operator_quality": runner.operator_quality,
		"options": runner.options.duplicate(true),
		"preview_limit": runner.preview_limit,
		"capture_previews": runner.capture_previews,
		"static_cache": runner.static_cache_enabled,
		"preview_nodes": runner.preview_nodes.duplicate(),
		"muted": store.muted_tracks.duplicate(),
		"solo": store.solo_tracks.duplicate(),
		"policy": policy.duplicate(true),
		"invalidate": invalidate,
		"epoch": _epoch,
		"doc_key": rev,
		"purpose": purpose,
		# 只有当这一帧真的按精确档算时才算「精确帧」。播放档的急件只是
		# 让画面有东西可贴，不能占据标尺上的绿格。
		"exact": frame_index >= 0 and runner.quality >= 1 \
			and float(runner.operator_quality) >= 0.999,
	})


## 退出前停线程：不等它结束就释放会崩在 C++ 里。
func _exit_tree() -> void:
	FxRenderApi.unbind(self)
	previews.clear()
	if prefetcher != null:
		prefetcher.stop()
		prefetcher = null
	if _worker != null:
		_worker.stop()
		_worker = null
	threaded = false


## 播放时预览范围也由策略决定：all / selection_output / none。
func _apply_preview_scope() -> void:
	runner.preview_nodes.clear()
	var scope := String(policy.get("preview_scope", "all"))
	if scope == "all" or not playing:
		return
	if scope == "none":
		runner.capture_previews = false
		return
	var output := FxGraphDoc.output_id(store.doc)
	if not output.is_empty():
		runner.preview_nodes[output] = true
	if not store.selected_id.is_empty():
		runner.preview_nodes[store.selected_id] = true


func _track_enabled(node_id: String, path: String) -> bool:
	if store == null:
		return true
	return store.is_track_animated(FxDocumentStore.track_key(node_id, path))


func _on_runner_preview(node_id: StringName, image: Image) -> void:
	# 主线程同步求帧时执行器直接发信号：小图属于「刚算完的这一帧」。
	_preview_frame[String(node_id)] = frame_index()
	_preview_known[String(node_id)] = true
	node_previewed.emit(String(node_id), image)


func _on_store_changed(keys: Array) -> void:
	# 播放推进时间不算「文档变了」：不能重置空闲计时、不能重算指纹，
	# 否则预渲染每帧都被打断，永远补不完缓存（旧实现最致命的一处）。
	if _setting_play_time:
		return
	# 纯布局变化（拖动节点、批量位置写回）不改变任何一帧的像素：
	# 既不能让缓存指纹换桶，也不该重画。旧实现把它当成「文档变了」，
	# 于是每拖一次节点就把整段缓存作废、后台预渲染从零重来。
	if _is_layout_only(keys):
		return
	# 最后一道闸门：通知说「变了」，但文档的内容身份根本没动 —— 那就是没变。
	# 任何一条未知路径（回滚、写回同值、视图态混进内容键）都被这里挡住，
	# 缓存、画布、预渲染一律不动。渲染只信内容身份，不信通知。
	var identity := _doc_revision()
	var identity_changed := identity != _content_seen
	_content_seen = identity
	# 注意 time 必须放行：交互拖时间轴（set_time）只发 time，但画面确实要重画。
	# 播放推进走 set_time_silent，不会走到这里。
	if not identity_changed and not keys.has("tracks") and not keys.has("time"):
		if keys.has("selection"):
			_apply_preview_scope()
		return
	var content := false
	for key in keys:
		if String(key) != "time":
			content = true
			break
	if content:
		_cache_dirty = true
		_idle_clock = 0.0
		# 只有**换了文档**（世代变了）才需要稳定期与重建桶：装载工程之后参数面板
		# 与节点视图还会回写一轮，那时定桶会白算。改参数不需要等 —— 桶必须立刻换，
		# 否则新算出的帧会被写进上一版内容的桶里。
		var generation := int(_doc_revision() / 1048576)
		if generation != _content_generation:
			_content_generation = generation
			_settle = 0.0
			# 换文档 = 换世代：在途的旧文档求帧结果一律作废，快照强制重做。
			_epoch += 1
			_preview_frame.clear()
			_preview_known.clear()
			_snapshot = {}
			_snapshot_rev = -1
			_pending_invalidate = true
			_prime_cache()
			# 新工程一装载就把预渲染排上：稳定期一过就启动，不等 0.9 秒。
			_idle_clock = PREFETCH_IDLE_DELAY
	if keys.has("selection"):
		_apply_preview_scope()
	var structural := keys.has("structure") or keys.has("canvas") or keys.has("timeline")
	var timed := keys.has("time") or keys.has("doc")
	# solo/mute 改变的是求值结果，不是文档；缓存必须失效并重画。
	var tracks_changed := keys.has("tracks")
	if structural or tracks_changed:
		runner.invalidate_cache()
		FxRenderBroker.invalidate()
	if _touches_params(keys):
		runner.invalidate_cache()
		FxRenderBroker.invalidate()
		# 改参数必须**立刻**换桶：新参数算出的帧不能写进旧内容的桶里。
		# 装载工程的稳定期里例外（那时桶还没定，等稳定了再建）。
		if _settle >= CONTENT_SETTLE:
			_ensure_bucket_now()
	if structural or timed or tracks_changed or _touches_params(keys):
		request_render()


## 立刻按当前文档重算一次桶（帧数 / 指纹 / 磁盘已有帧）。
func _ensure_bucket_now() -> void:
	if store == null or store.doc.is_empty():
		return
	var tl := FxGraphDoc.timeline(store.doc)
	_cache_ensure_fingerprint(maxi(int(tl.get("fps", 30)), 1),
		maxf(float(tl.get("duration", 1.0)), 0.0))


## 只有「节点位置 / 卡片尺寸」这一类改动（配合 commit_batch 自动附加的 doc）。
## 注意不能用「键的数量」判断：commit_batch 一定会追加 doc。
## 这类改动不改变任何一帧的像素，因此既不能让缓存指纹换桶，也不该重画；
## 缩放视图、点一下节点、拖一下卡片都会走到这里 —— 它们全都必须静默。
func _is_layout_only(keys: Array) -> bool:
	if keys.is_empty():
		return false
	var saw_position := false
	for key in keys:
		match String(key):
			"positions", "size":
				saw_position = true
			"doc":
				pass
			_:
				return false
	return saw_position


func _touches_params(keys: Array) -> bool:
	for key in keys:
		var text := String(key)
		if text.begins_with("param:") or text.begins_with("node:"):
			return true
	return false
