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
## 本帧各节点的**输出值**摘要（纯数值/向量/布尔节点用它显示「算出来是多少」）。
signal node_values_resolved(values_by_node: Dictionary)
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
## IR 剪枝计划：按 (文档内容身份, 预览根集合) 缓存，避免每帧重编译。
## core.compile 停用时 FxCapabilities.providers("graph.compile") 为空 → 计划为 {}。
var _compile_plan: Dictionary = {}
var _compile_plan_rev: int = -999999
var _compile_plan_roots: String = "\u001Finit"
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
## 换桶之后要把当前帧补算回来。桶被重建时绿格全清，如果没人重画，
## 预览就会空着等用户「动一下」—— 这正是「预览有时候有 bug」的来源之一。
var _refill_after_rebuild: bool = false
## 节点小图这条独立管线的两个旋钮（来自设置，见 quality.preview_*）。
## 它们**只作用于缩略图趟**：精确帧缓存与输出预览永不走这两档。
var _preview_operator: float = 0.5
var _preview_refresh: float = 1.5
## 上一次定桶时的文档修订号：用来区分「内容真的改了」与「改了但没发通知」。
var _build_rev: int = -1
## 0 = 按 CPU 核数自动（最多 6 条并行线程）。
var _prefetch_workers: int = 0
## 空闲多久开始后台预渲染。文档一装载就排上，参数改动 0.18s 防抖后重排；
## 旧实现等 0.9s 且每次 set_time 都把计时归零，播放前后永远排不上。
const PREFETCH_IDLE_DELAY := 0.18
## 草稿趟的起跑延迟：比精确趟短得多。它便宜，而且用户等的就是这一眼。
const DRAFT_PASS_IDLE_DELAY := 0.12
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
## 显示缓存所属的画布尺寸。画布是显示缓存的布局前提（图会被拉伸到画布框里）。
var _display_canvas: Vector2i = Vector2i.ZERO

var _dirty: bool = true
var _cooldown: float = 0.0
var _last_image: Image = null
## 暂停态「屏幕上这一张」的身份（内容身份:帧号）。
## 它只用来回答一个问题：屏幕上这张是不是**当前文档的精确帧**。
var _pinned_key: String = ""
var _last_stats: Dictionary = {}
var _last_node_params: Dictionary = {}
var _last_node_values: Dictionary = {}
## 最近一次解析出的质量策略，供设置面板/诊断读取。
var policy: Dictionary = {}
## 在飞登记：时间轴标尺的橘色格。`_rendering_stamp` 是上一次的集合（用于只在变化时推送）。
var _inflight_live: int = -1
var _rendering_stamp: String = ""
## 哪个桶已经跑过草稿趟了。草稿趟每个桶只跑一次（之后由精确趟逐帧替换）。
var _draft_pass_fp: String = ""

# ================= 动态质量：草稿帧 =================

## 阶梯：先 1/8 画布（最快，形状/颜色大致对），没等到精确帧就升到 1/4、1/2。
## 档位不是「画质选项」，而是「先给多少」—— 精确帧一到就整体替换。
const DRAFT_STEPS: Array[float] = [0.125, 0.25, 0.5]
## 同一档至少等这么久再升档：升太快等于每档都没算完就扔掉，白烧 CPU。
const DRAFT_STEP_HOLD := 0.12
## 草稿线程与它的状态。`draft == null` 表示这条通道不可用（无线程 / 被关掉）。
var draft: FxDraftWorker = null
var _draft_on: bool = true
## 当前草稿对应的（帧号, 内容身份, 阶梯档）。内容一变全部归零重来。
var _draft_index: int = -1
var _draft_rev: int = -1
## 草稿对应的播放世代。播放启停会清空所有在飞结果（`_epoch`），
## 草稿也必须跟着作废 —— 否则「播放前算的那张」会被当成播放中的垫图，
## 而且旧状态（阶梯已耗尽）会挡住播放开始后的重新提交。
var _draft_epoch: int = -1
var _draft_step: int = 0
var _draft_clock: float = 0.0
## 这一帧的阶梯已经走到顶：不再重算（精确帧自己会来）。
var _draft_exhausted: bool = false
## 草稿专用的文档快照（不与精确帧共用一份：两条线程同时读同一份字典没必要冒险）。
var _draft_doc: Dictionary = {}
var _draft_doc_rev: int = -1
## 最近一次草稿的实测数据（诊断 / 测试读）。
var _draft_report: Dictionary = {}


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
	_preview_operator = clampf(float(policy.get("preview_operator", 0.5)), 0.0, 1.0)
	_preview_refresh = clampf(float(policy.get("preview_refresh_ms", 1500)) / 1000.0, 0.12, 5.0)
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
	# 动态质量：草稿帧是「显示层」的能力，所以只受一条设置与线程前提约束，
	# 与缓存/预渲染开关互不牵连（关掉缓存也该能看见东西）。
	_draft_on = bool(FxSettings.typed_value("render.draft", true)) and FxNative.thread_safe()
	_sync_draft_worker()


## 草稿线程的启停。线程起不来就永久关掉这条通道：
## 每 0.25s 重试一次失败的系统调用没有任何意义，只会把日志刷满。
func _sync_draft_worker() -> void:
	if _draft_on and draft == null:
		var worker := FxDraftWorker.new()
		if worker.start():
			draft = worker
		else:
			_draft_on = false
	elif not _draft_on and draft != null:
		draft.stop()
		draft = null


## 当前帧号（时间轴标尺上的小色块按它对齐）。
func frame_index() -> int:
	return cache.index_for_time(store.current_time) if store != null else 0


func frame_count() -> int:
	return cache.frame_count()


## 时间轴标尺问的是「这一格该画什么颜色」，所以要带上「正在算」这一档。
## 缓存语义（能不能用）仍然只有 `cache.state()` 一个答案。
func cache_state(index: int) -> int:
	return cache.display_state(index)


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
## 求值根 = 展开的节点 ∪ 当前选中的节点。
## 这不只是给预览用：**剪枝必须按这个集合判活**，否则用户正在看的旁支节点会被删掉。
func _preview_roots() -> Array:
	var roots: Array = _preview_focus.duplicate()
	if store != null:
		var selected := String(store.selected_id)
		if not selected.is_empty() and not roots.has(selected):
			roots.append(selected)
	return roots


static func _typed_roots(raw: Array) -> Array[String]:
	var out: Array[String] = []
	for item in raw:
		var id := String(item)
		if not id.is_empty() and not out.has(id):
			out.append(id)
	return out


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
	# 但那一趟在「整段精确帧没算完」时会被跳过；暂停态又没有别的推送时机。
	# 这里主动要一次重算，新的 preview_roots 当帧就生效，不必等下一次交互。
	request_render(0.02)


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
	_cache_ensure_fingerprint(fps, duration, "preview")
	var focus: Dictionary = {}
	for id in _preview_focus:
		focus[id] = true
	_preview_pass_clock = _preview_refresh
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
		# 小图自己的算子质量：不再硬编码 0.5，也不再被精确趟的档位带着走。
		"operator_quality": _preview_operator,
		"preview_only": true,
		"preview_nodes": focus,
		"preview_roots": _preview_roots(),
		"compile_plan": _plan_for_current_doc(),
		# 用用户设的边长：旧实现这里写死 PREVIEW_THUMB=72，
		# 于是「节点预览边长」调到 192 也没用，后台算出来的还是 72。
		"preview_limit": runner.preview_limit,
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
	_cache_ensure_fingerprint(fps, duration, "prefetch")
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
		"preview_roots": _preview_roots(),
		"compile_plan": _plan_for_current_doc(),
		"preview_limit": runner.preview_limit,
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
	_draft_pass_fp = ""
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


## 把「谁正在算」翻译成标尺上的橘色。
##
## 每帧一次，只有集合变了才写缓存并推信号：橘色是**瞬时事实**，
## 迟 0.25 秒（`_emit_cache` 的节流）就会变成「一格一格随机闪」。
## 数据只有两个来源，都是调度器自己的账本，不猜：
##   · 预渲染派发出去的帧号（缩略图趟不算，它不产出可缓存帧）；
##   · 单帧工作线程手上那一帧（提交时登记，结果回来即清）。
func _refresh_rendering_marks() -> void:
	var busy: Array = []
	if prefetcher != null:
		busy.append_array(prefetcher.inflight())
	if _worker != null and _worker.busy() and _inflight_live >= 0 \
			and not busy.has(_inflight_live):
		busy.append(_inflight_live)
	# 草稿线程也是一条真的在算的线程：正在算的那一帧同样该是橘的。
	if draft != null and draft.busy() and _draft_index >= 0 and not busy.has(_draft_index):
		busy.append(_draft_index)
	var stamp := str(busy)
	if stamp == _rendering_stamp:
		return
	_rendering_stamp = stamp
	cache.set_rendering(busy)
	_emit_cache(true)


## 每帧的缓存维护：指纹、预渲染进度、空闲调度。都很轻。
func _tick_cache(delta: float) -> void:
	if store == null:
		return
	_cache_emit_clock -= delta
	_cache_clock -= delta
	# 播放要按帧缓存推进：桶还没建好时按播放等于「没有帧号可走」。
	# 巡检每 0.25s 才定一次桶，这里把「播放中且没桶」这一种情况提前钉住，
	# 免得按下播放后的前两百毫秒一动不动（用户读成「卡住了」）。
	if playing and cache.frame_count() == 0:
		var tl_play := FxGraphDoc.timeline(store.doc)
		_cache_ensure_fingerprint(maxi(int(tl_play.get("fps", 30)), 1),
			maxf(float(tl_play.get("duration", 1.0)), 0.0), "play")
	_idle_clock += delta
	_settle += delta
	_preview_pass_clock -= delta
	_refresh_rendering_marks()
	if _cache_clock <= 0.0:
		_cache_clock = 0.25
		_read_cache_settings()
		# 文档还在稳定期里就不定桶：装载工程之后参数面板还会回写一轮，
		# 现在算出的指纹大概率不是最终的，桶会被换掉、预渲染成果白费。
		if _settle >= CONTENT_SETTLE:
			var tl := FxGraphDoc.timeline(store.doc)
			_cache_ensure_fingerprint(maxi(int(tl.get("fps", 30)), 1),
				maxf(float(tl.get("duration", 1.0)), 0.0), "tick")
	# 换桶后的补算：桶是新的，绿格全空，当前帧必须重新算一遍贴回去。
	# 播放中不补 —— 播放头本来就会往前走，缺帧由播放急件通道处理。
	if _refill_after_rebuild:
		if playing:
			_refill_after_rebuild = false
		elif cache.state(frame_index()) == FxFrameCache.STATE_READY:
			_refill_after_rebuild = false
			# 桶里已经有精确帧了，但屏幕上还是换桶前那张 —— 这里补贴一次。
			_pinned_key = ""
			_pin_ready_frame()
		elif _settle >= CONTENT_SETTLE:
			_refill_after_rebuild = false
			request_render()
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
	if _cache_dirty:
		return
	# 先草稿、后精确：一次内容变化（含改画布）之后，整段先用**缩小画布**填满，
	# 再逐帧被精确帧替换。顺序反过来的话，用户要先盯着一片红等几分钟
	# ——「改完画布就像坏了」正是这个顺序造成的。
	if _draft_on and int(cache.stats().get("missing", 0)) > 0 			and _draft_pass_fp != cache.fingerprint() \
			and _idle_clock >= DRAFT_PASS_IDLE_DELAY:
		if not prefetching() and start_draft_pass():
			return
	if _idle_clock < PREFETCH_IDLE_DELAY:
		return
	if prefetching() or int(cache.stats().get("missing", 0)) == 0:
		return
	start_prefetch(false)


## 草稿趟：整段按 1/8 画布算一遍，结果只进「垫图层」（黄格）。
##
## 与精确趟共用同一条预渲染通道（同一批线程、同一套取消/指纹检查），
## 区别只有三个：画布倍率、写 exact=false、不跑汇点。这么做的好处是
## 「先给看」不需要另起一套调度器 —— 播放、改画布、改参数都自动受益。
func start_draft_pass() -> bool:
	# 与自动预渲染同一口径：无头不跑（那里没有「看一眼」这回事）。
	if DisplayServer.get_name() == "headless":
		return false
	_ensure_prefetcher()
	if prefetcher == null or store == null or store.doc.is_empty():
		return false
	if prefetching():
		return false
	# 整段垫图要能装进内存预算才划算：垫图存在帧缓存里（定长布局要求画布尺寸），
	# 大画布下「60 帧 × 画布尺寸」自己就会把预算撑爆 —— 那时垫图互相挤掉，
	# 播放变成「贴一张丢一张」，比没有垫图更糟。这种工程只靠当前帧草稿兜底。
	var canvas := FxGraphDoc.canvas(store.doc)
	var bytes := canvas.x * canvas.y * 4 * maxi(cache.frame_count(), 1)
	if float(bytes) > float(cache.memory_budget) * 0.6:
		_draft_pass_fp = cache.fingerprint()
		return false
	var tl := FxGraphDoc.timeline(store.doc)
	var fps := maxi(int(tl.get("fps", 30)), 1)
	var duration := maxf(float(tl.get("duration", 1.0)), 0.0)
	_cache_ensure_fingerprint(fps, duration, "draft")
	_prefetch_revision = FxRegistry.revision
	_prefetch_reported = true
	# 队列顺序：播放头 / 急件优先，其次当前帧 —— 草稿趟也要「先给用户正在看的那几帧」。
	var priority := frame_index()
	if playing:
		priority = _play_frame
	if _urgent_frame >= 0:
		priority = _urgent_frame
	prefetcher.enqueue({
		"doc": store.doc.duplicate(true),
		"fps": fps,
		"count": cache.frame_count(),
		"from": 0,
		"priority": priority,
		# 草稿不出缩略图、不跑汇点：它只负责「有东西可看」。
		"preview_nodes": {},
		"preview_roots": [],
		"compile_plan": _plan_for_current_doc(),
		"signature": _doc_revision(),
		"fingerprint": cache.fingerprint(),
		"policy": resolve_policy(true),
		"revision": _prefetch_revision,
		"draft_scale": DRAFT_STEPS[0],
		"operator_quality": float(policy.get("draft_operator_quality", 0.35)),
		"label": "草稿",
	})
	_draft_pass_fp = cache.fingerprint()
	return true


## 文档刚装载：把桶标记成待建，等稳定期结束后的巡检来定桶。
## 这里**不能**用「桶还空着就顺手建一个」的写法：打开工程前桶里是上一份文档
## （示例文档 30 帧），那样会跳过重建，于是帧数、指纹、标尺全停在上一份文档上，
## 预渲染也永远不会被判定成「缺帧」。归档侧已有稳定期保护，不会写入错误桶。
func _prime_cache() -> void:
	if store == null or store.doc.is_empty():
		return
	_cache_dirty = true
	_settle = 0.0


## 定桶。`reason` 只用于归因（谁引起这次定桶），不参与任何判断分支。
## 换桶是**破坏性**动作：`prepare()` 会把每一格状态清成 EMPTY，标尺上的绿格随之消失。
## 所以「谁在重建」必须可查 —— 见 FxCacheTrace 与 diag.cache。
func _cache_ensure_fingerprint(fps: int, duration: float, reason: String = "tick") -> void:
	var canvas := FxGraphDoc.canvas(store.doc)
	# 帧尺寸就是紧密文件的布局参数：画布一变，旧桶的每一格都装不进去。
	# 所以「桶的尺寸 != 当前画布」本身就是一个换桶理由，**不能**只看 `_cache_dirty`
	# —— 只要有谁漏了置脏，屏幕就会永远停在旧尺寸上（换尺寸后画面坏掉的真身）。
	if not _cache_dirty and cache.frame_count() > 0 and cache.frame_size() == canvas:
		return
	var before := cache.fingerprint()
	var count_before := cache.frame_count()
	var rev_now := _doc_revision()
	# 桶的帧尺寸来自文档画布：任何异形帧（旧文档 / 空文档求出来的）都不得写入。
	cache.prepare(store.doc, fps, duration, canvas)
	var build := cache.last_build()
	if cache.fingerprint() != before:
		# 图变了：手上那次预渲染算的是上一版画面，直接作废。
		cancel_prefetch()
	var rebuilt := bool(build.get("rebuilt", false))
	# 「内容变了，但修订号没变」= 有人直接改了 store.doc，绕过了 mutate / attach。
	# 这类写入不会通知任何订阅者，界面上表现为「什么都没发生，缓存却换了」。
	# 不猜是谁，只把它标出来 —— 定位留给上面的逐节点明细。
	var silent := rebuilt and _build_rev >= 0 and rev_now == _build_rev
	if rebuilt:
		_build_rev = rev_now
	var event := {
		"reason": reason,
		"fp_before": before,
		"fp_after": cache.fingerprint(),
		"count_before": count_before,
		"count_after": cache.frame_count(),
		"rebuilt": rebuilt,
		"cleared": int(build.get("cleared", 0)),
		"parts_before": build.get("parts_before", {}),
		"parts_after": build.get("parts_after", {}),
		"detail_before": build.get("detail_before", {}),
		"detail_after": build.get("detail_after", {}),
		"dirty": _cache_dirty,
		"settle": _settle,
		"generation": _content_generation,
		"revision": rev_now,
		"silent": silent,
		"playing": playing,
		"frame_size": FxGraphDoc.canvas(store.doc),
	}
	# 只有真的换桶才写日志：不然每 0.25s 一次巡检就把环形缓冲刷满，
	# 真正的那次重建反而被挤掉。被跳过的定桶只累加计数（见 skip 分支）。
	if rebuilt:
		FxCacheTrace.record(FxCacheTrace.KIND_BUCKET, event)
		# 换桶是破坏性的：绿格全没了。当前帧若不在新桶里，就得补算一次，
		# 否则预览会空着，直到用户碰一下界面为止。补算在 `_tick_cache` 里排队，
		# 不在这里同步触发 —— 定桶可能正发生在发布/归档路径中间。
		_refill_after_rebuild = true
	else:
		FxCacheTrace.record("bucket-skip", event)
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


## 节点小图这条管线的当前参数（诊断与测试读它，不参与任何判断分支）。
## 「输出预览」的分辨率由 `display_scale` 单独控制，缓存与导出不受它影响。
func preview_pipeline_config() -> Dictionary:
	return {
		"limit": runner.preview_limit,
		"operator": _preview_operator,
		"refresh": _preview_refresh,
		"output_downscale": bool(policy.get("output_downscale", false)),
		"display_scale": _display_scale(),
		"capture": runner.capture_previews,
		# 动态质量：草稿通道是否可用、阶梯档位、最近一次实测。
		"draft": _draft_on and draft != null,
		"draft_steps": DRAFT_STEPS.duplicate(),
		"draft_last": _draft_report.duplicate(),
	}


## 公开给诊断命令读：当前生效的求值根（展开 ∪ 选中）。
func preview_roots() -> Array:
	return _preview_roots()


## 向 graph.compile 能力查询本版文档的剪枝计划。
## 只用字符串能力键 + 纯数据返回，渲染服务不认识 FxIRCompiler 这个类名；
## 插件停用 → providers 为空 → 返回 {} → 求值器走未剪枝的原行为。
## 同步路径、工作线程、后台预渲染三条路径都调用这里，拿到的是**同一份计划**，
## 所以「实时预览」与「最终渲染」不会在剪枝上分叉。
func _plan_for_current_doc() -> Dictionary:
	if store == null or store.doc.is_empty():
		return {}
	var rev := _doc_revision()
	var roots: Array = _preview_roots()
	var sorted: Array[String] = []
	for item in roots:
		sorted.append(String(item))
	sorted.sort()
	var roots_key := ",".join(PackedStringArray(sorted))
	if rev == _compile_plan_rev and roots_key == _compile_plan_roots:
		return _compile_plan
	_compile_plan_rev = rev
	_compile_plan_roots = roots_key
	_compile_plan = {}
	var providers := FxCapabilities.providers("graph.compile")
	if providers.is_empty():
		return {}
	var handler: Callable = providers[0].get("apply", Callable())
	if not handler.is_valid():
		return {}
	var snapshot: Dictionary = store.doc.duplicate(true)
	var plan: Variant = handler.call(snapshot, roots)
	if plan is Dictionary:
		_compile_plan = plan
	return _compile_plan


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


## 暂停态：当前帧在缓存里**有图**（精确帧或垫图）就贴上去，画质更好的后来居上。
##
## 为什么必须有这一步：暂停时的画面只有两条路会变 ——
##   ① 实时求帧的结果回来（装载期那一帧可能算的是**半成品文档**）；
##   ② 按停播放时贴一次缓存帧（`set_playing(false)` 里那一次）。
## 「实时帧先贴、精确帧后到」这个顺序两条都不覆盖，于是屏幕会停在旧的那张上。
## 用户看到的就是「改了参数没效果」「画面不回来」，而日志里一切正常。
##
## 贴垫图（PENDING）是后来补上的一档：从前只有精确帧才配上屏，于是「帧没算好」
## 等于「屏幕上是上一版的图」—— 改画布、改参数的头几百毫秒全是错的画面。
## 现在先贴垫图（状态栏会写「草稿 1/8」），精确帧到了再原地换掉。
##
## 判定用「内容身份 + 帧号 + 画质档」：内容一变钥匙就变，天然不会贴上一版文档的帧；
## 画质档进钥匙，是为了让「垫图 → 精确帧」这一步也能再贴一次。
func _pin_ready_frame() -> void:
	if store == null or not _cache_on:
		return
	var index := cache.index_for_time(store.current_time)
	# 还有待重画的帧时不抢先贴：`_publish_cached` 会把 `_dirty` 清掉，
	# 那一帧就再也不会算了。
	if _dirty:
		return
	var state := cache.state(index)
	if state != FxFrameCache.STATE_READY and state != FxFrameCache.STATE_PENDING:
		return
	if not cache.accepts(index, _doc_revision()):
		return
	# 2 = 精确帧，1 = 垫图。精确帧永远压过垫图。
	var key := "%d:%d:q%d" % [_doc_revision(), index, 2 if state == FxFrameCache.STATE_READY else 1]
	if key == _pinned_key:
		return
	var image := cache.fetch(index)
	if image == null or image.get_size() != _canvas_size():
		return
	_publish_cached(image, index, true, state != FxFrameCache.STATE_READY)
	_pinned_key = key


## 停止播放时把画面钉在当前时间的帧上（只读缓存，不触发求值）。
func _show_frame_at_current_time() -> bool:
	if store == null or not _cache_on:
		return false
	var index := cache.index_for_time(store.current_time)
	# 只认精确帧：标成待补的（只有播放档预览）不算「这一帧好了」，
	# 否则停播定格会把一张糊图钉在屏幕上。
	if index < 0 or cache.state(index) != FxFrameCache.STATE_READY:
		return false
	# 还要认内容身份：桶里那张可能是上一版文档算的（预渲染与主线程并发写），
	# 贴上去就是「看着绿色就绪、其实不是这份文档」。
	if not cache.accepts(index, _doc_revision()):
		return false
	var image := cache.fetch(index)
	# 尺寸不符 = 这一格装的是别的画布的图（换尺寸窗口 / 磁盘旧桶）：
	# 当没命中，让后台按当前画布重算，绝不能贴上去。
	if image == null or image.get_size() != _canvas_size():
		return false
	_publish_cached(image, index, true)
	# 记下「屏幕上这张」是谁：否则按停播放那次贴完，下一帧 `_pin_ready_frame`
	# 还会把同一帧再贴一次 —— 表现是「停止时发布了 2 张定格帧」。
	_pinned_key = "%d:%d:q2" % [_doc_revision(), index]
	return true


func toggle_playback() -> void:
	set_playing(not playing)


func request_render(debounce: float = 0.0) -> void:
	_dirty = true
	_cooldown = minf(_cooldown, debounce) if debounce > 0.0 else 0.0


## 失效分三档。**档位由「什么变了」决定，不由「谁调的」决定**：
##
##   · `content`  —— 像素内容身份变了（改参数、换图结构、切后端）。
##                   桶必须重建，绿格全部作废，在途结果按世代丢弃。
##   · `derived`  —— 内容没变，但**算它的方式**变了（质量档、算子系数、GPU 算子开关）。
##                   桶里已有的精确帧仍然精确，保留；作废的是派生缓存：
##                   执行器跨帧静态表、节点样张、显示层。
##   · `display`  —— 只影响贴到屏幕的那一步（锐化强度一类后处理）。
##                   连求值结果都不用动，只丢显示缓存并重贴一次。
##
## 旧实现只有一个档：任何设置变化都走 `content`。于是「调一下预渲染线程数」和
## 「改一个节点参数」付出的代价完全一样 —— 整段缓存重建、标尺绿格清零。
## 这正是「数据没变也在重建」最粗的那一层来源。
func invalidate(kind: String = "content", source: String = "") -> void:
	# 键名用 `tier` 而不是 `kind`：事件自身的 kind 由 FxCacheTrace.record 写入，
	# 同名字段会被覆盖 —— 这是归因日志最容易犯的错（本轮的测试当场抓到了）。
	FxCacheTrace.record(FxCacheTrace.KIND_INVALIDATE, {
		"tier": kind, "source": source,
		"revision": _doc_revision(), "generation": _content_generation,
		"settle": _settle, "playing": playing,
		"ready": int(cache.stats().get("ready", 0)),
		"frame_count": cache.frame_count(),
	})
	match kind:
		"display":
			_display_cache.clear()
			_display_fingerprint = ""
			request_render()
			return
		"derived":
			# 执行器静态缓存与样张都按「上一版求值参数」算的，必须重建。
			runner.invalidate_cache()
			FxNodePreview.clear_cache()
			# 在途结果按旧参数算，但也确实是对应帧的图像：不丢，留给归档判定
			# （它自带 frame_quality / frame_operator_quality，不会被误标成精确）。
			_pending_invalidate = true
			_display_cache.clear()
			_display_fingerprint = ""
			request_render()
			return
		_:
			runner.invalidate_cache()
			FxNodePreview.clear_cache()
			_cache_dirty = true
			_pending_invalidate = true
			_epoch += 1
			request_render()


## 帧缓存重建的归因日志（只读）。基座契约 `FxRenderHost.cache_trace()` 的实现，
## 诊断命令 diag.cache 经契约读取，不认识本插件的类名。
func cache_trace() -> Array:
	return FxCacheTrace.entries()


func cache_reset_trace() -> void:
	FxCacheTrace.clear()


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
	#
	# **不能直接 `lock()`**。工作线程整帧持着这把锁；含 GPU / 离屏视口算子的那种帧
	# 会「等主线程泵」才继续。主线程要是在这里死等锁，就把泵停了 —— 工作线程永远
	# 等不到它要的那几毫秒，两边互等，整个界面卡死（真机表现：导出/样板图一旦赶上
	# 后台正在算，窗口就再也不响应）。所以一边等一边泵，和插件宿主撤贡献时同一套做法。
	var gate := FxRenderGate.mutex()
	var result: Dictionary = {}
	if _lock_gate(gate):
		result = FxRenderBroker.frame(store.doc, frame_time, export_options, runner,
			{"playing": false, "exact": exact})
		gate.unlock()
	else:
		# 等不到就明确报一次，别假装算了一张空图。
		push_warning("FxRenderService：单帧渲染等待闸门超时，已跳过（后台帧可能卡住）")
	runner.quality = old_quality
	runner.capture_previews = old_previews
	runner.operator_quality = old_operator
	runner.options = old_options
	var image: Variant = result.get("image")
	return image as Image


## 拿渲染闸门，但**保持主线程泵在跑**：工作线程的那一帧可能正靠它推进。
## 超时返回 false —— 宁可这一帧失败，也不让主线程永久卡住。
func _lock_gate(gate: Mutex, max_ms: int = 10000) -> bool:
	var deadline := Time.get_ticks_msec() + max_ms
	while true:
		if gate.try_lock():
			return true
		FxRenderGate.pump_main_thread()
		if Time.get_ticks_msec() > deadline:
			return false
		OS.delay_usec(300)
	return false


func _process(delta: float) -> void:
	if store == null:
		return
	# 主线程泵：把工作线程排队的设备请求处理掉（每帧限流）。
	# 基座不认识具体设备，没有插件注册时是一次空调用。
	FxRenderGate.pump_main_thread()
	# 先泵、再重试排队的插件启停：泵让工作线程有机会把这帧算完并放开闸门，
	# 否则「停用插件」这种操作会被一帧的 GPU 泵卡住（详见 FxPluginHost.set_enabled）。
	FxPluginHost.tick()
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
			var suppress := playing
			if not playing:
				# 暂停态还要看**这一帧是不是用户现在要的那一帧**：拖动时间轴时
				# 在途结果算的是几百毫秒前的时刻，贴上去就是「拖完又跳回去」。
				# 它不是错帧，只是过期帧 —— 归档进缓存，不上屏。
				var got_index := int(done.get("frame_index", -1))
				suppress = got_index >= 0 and got_index != frame_index()
			_publish(done, true, suppress)
	# 动态质量：精确帧还没到时先上一张低质量草稿（只影响显示）。
	# 放在发布之后、贴精确帧之前：同一帧里精确帧永远赢。
	_tick_draft(delta)
	# 播放 = 只读缓存。命中就贴图，没命中就保持上一帧并后台补算，
	# 界面线程永远不做 600ms 的逐像素求值。
	if playing:
		_serve_playback_frame()
		return
	# 先看缓存里当前帧有没有到精确态：到了就贴上去（每个内容身份只贴一次）。
	_pin_ready_frame()
	if not auto_render or not _dirty or _cooldown > 0.0:
		return
	if _worker != null:
		# 同一时刻只跑一帧：忙的时候保持 dirty，算完立刻用最新状态重提。
		if not _worker.busy():
			_submit()
	else:
		_render()


# ================= 动态质量：先给一张草稿，再被精确帧替换 =================

## 这一帧是不是已经「真的好了」（精确帧 + 属于当前文档）。
## 草稿通道的每一次判断都以它为前提：好了就绝不拿糊图去盖。
func _exact_ready(index: int) -> bool:
	if not _cache_on or index < 0:
		return false
	if cache.state(index) != FxFrameCache.STATE_READY:
		return false
	return cache.accepts(index, _doc_revision())


## 每帧跑一次：收草稿结果 → 需要的话再排下一档。
##
## 它**不参与**精确帧的任何决策：不发请求、不清 `_dirty`、不写缓存。
## 屏幕上那一张由精确帧「接管」的唯一方式是精确帧自己到了（`_pin_ready_frame`），
## 所以就算草稿线程挂了，最坏结果也只是「回到没有草稿的日子」。
func _tick_draft(delta: float) -> void:
	if draft != null:
		var result := draft.take_result()
		if not result.is_empty():
			_accept_draft(result)
	if not _draft_on or draft == null or store == null:
		return
	var index := _play_frame if playing else frame_index()
	# 精确帧已经在手上：草稿没有任何价值。
	# 注意这里**不看**「有没有卡住」：只要这一帧还没有精确帧，就先给一张垫图 ——
	# 播放要的正是这张垫图（它决定时钟能不能继续走），而不是「卡住了再救」。
	# 旧版本按 `_stall > 0` 才出草稿，于是草稿永远慢半拍：等它算完，播放头已经
	# 被 STALL_LIMIT 放过去了，或者它算的那一帧已经不是当前帧。
	if _exact_ready(index) or _draft_exhausted:
		return
	var rev := _doc_revision()
	if index != _draft_index or rev != _draft_rev or _epoch != _draft_epoch:
		_draft_index = index
		_draft_rev = rev
		_draft_epoch = _epoch
		_draft_step = 0
		_draft_clock = 0.0
		# 换了内容/帧：上一张草稿的上屏记录不再说明任何事，
		# 留着会让诊断把「上一版文档出过草稿」读成「这一版出过」。
		_draft_report.clear()
		_draft_exhausted = false
	if draft.busy():
		return
	_draft_clock += delta
	# 第一档立刻上；之后每档至少等 DRAFT_STEP_HOLD，等不到精确帧再升档。
	# 升到顶就够了：再算一遍最高档只是把同一张图再画一次，精确帧终归会来。
	if _draft_step > 0 and _draft_clock < DRAFT_STEP_HOLD:
		return
	# 播放期只出**最快那一档**：播放要的是「每帧都有东西」，不是「这一帧更好看」。
	# 一帧连算三档会把线程占满，后面的帧反而没垫图，播放就又开始等。
	var steps := 1 if playing else DRAFT_STEPS.size()
	if _draft_step >= steps:
		_draft_exhausted = true
		return
	var scale := DRAFT_STEPS[_draft_step]
	_draft_step += 1
	_draft_clock = 0.0
	_submit_draft(index, scale)


## 提交一档草稿。快照独立于精确帧那一份：两条线程同时读同一份字典，
## 省下的那点内存不值得拿「跨线程共享可变对象」去换。
func _submit_draft(index: int, scale: float) -> void:
	if draft == null or store == null or store.doc.is_empty():
		return
	apply_policy()
	var rev := _doc_revision()
	if _draft_doc.is_empty() or _draft_doc_rev != rev:
		_draft_doc = store.doc.duplicate(true)
		_draft_doc_rev = rev
	var fps := maxf(float(cache.fps()), 1.0)
	var t := float(clock.call("time_of", index, fps)) if clock != null \
		else float(index) / fps
	draft.submit({
		"doc": _draft_doc,
		"t": t,
		"frame_index": index,
		"canvas_scale": scale,
		"operator_quality": float(policy.get("draft_operator_quality", 0.35)),
		"options": runner.options.duplicate(true),
		"compile_plan": _plan_for_current_doc(),
		"muted": store.muted_tracks.duplicate(),
		"solo": store.solo_tracks.duplicate(),
		"policy": policy.duplicate(true),
		"signature": rev,
		"epoch": _epoch,
		"doc_key": rev,
	})
	_draft_report["scale"] = scale
	_draft_report["index"] = index
	_draft_report["rev"] = rev


## 收一张草稿：只做「缩放 + 上屏」，绝不写缓存、绝不清脏标记。
func _accept_draft(result: Dictionary) -> void:
	var image: Image = result.get("image") as Image
	if image == null or image.is_empty():
		return
	var rev := int(result.get("doc_key", -1))
	if rev != _doc_revision() or int(result.get("epoch", -1)) != _epoch:
		# 算的是上一版文档 / 上一次播放世代：扔掉，别把旧画面贴回去。
		return
	var index := int(result.get("frame_index", -1))
	var want := _canvas_size()
	if want.x <= 0 or want.y <= 0:
		return
	# 播放头已经往前走了 / 用户已经拖到别的帧：这张草稿已经过期。
	# 少了这一条，播放中「卡住时顶上来的草稿」会在两帧之后才到，
	# 把画面往回拽一帧 —— 那种抖动比空白更难查。
	if index != (_play_frame if playing else frame_index()):
		return
	# 精确帧在这段时间里已经就位：草稿到得太晚，直接丢。
	if _exact_ready(index):
		return
	var out := image
	if out.get_size() != want:
		# 草稿是小图，必须放大到画布尺寸：贴图纹理在两档之间换尺寸，
		# 屏幕上的画面会跟着抖一下（尺寸变化本身就是一次重排）。
		out = out.duplicate()
		out.resize(want.x, want.y, Image.INTERPOLATE_BILINEAR)
	# **写进垫图层**（exact = false）：标尺上这一格变黄，播放器把它当「有图可贴」，
	# 于是时钟可以继续往前走 —— 不再为了等精确帧把播放钉死在一帧上。
	# 精确帧到了直接覆盖成绿；`put()` 里「近似帧不许盖精确帧」那条保证不会反向污染。
	cache.put(index, out, false, false, rev, float(result.get("canvas_scale", 0.0)))
	# 不走 `_gpu_display` 的缓存：那里按「内容+帧号」登记，草稿会把糊图登在
	# 精确帧的名下，之后精确帧发布时直接命中糊图 —— 画质就永远上不去了。
	_last_image = out
	# 播放期：这张垫图已经上屏了，记下「这一帧贴过」，
	# 免得下一帧 `_serve_playback_frame` 又把同一张图贴一遍。
	if playing:
		_published_frame = index
		_published_exact = false
	var stats := _last_stats.duplicate()
	stats.erase("buffering")
	stats["draft"] = true
	stats["exact_frame"] = false
	stats["cached"] = false
	stats["frame"] = index
	stats["draft_scale"] = float(result.get("canvas_scale", 0.0))
	stats["draft_size"] = image.get_size()
	stats["ms"] = float((result.get("stats", {}) as Dictionary).get("ms", 0.0))
	# 缓存状态保持真实（这一格仍然没算好），只额外标一层「这是草稿」。
	stats["cache"] = cache.stats(prefetch_progress()) if _cache_on else {}
	_last_stats = stats
	_draft_report["shown"] = index
	_draft_report["shown_scale"] = float(result.get("canvas_scale", 0.0))
	rendered.emit(out, stats)
	if _stats_emit_clock <= 0.0:
		_stats_emit_clock = 0.2
		stats_changed.emit(stats)


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
	# 身份不符 = 这一格装的是上一版文档的图：当作没命中，绝不贴上去。
	if image != null and not cache.accepts(index, _doc_revision()):
		image = null
		state = FxFrameCache.STATE_EMPTY
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
	# 最后一道尺寸闸门：缓存里的这一格如果与当前画布不符（换尺寸窗口、
	# 磁盘上的旧桶），绝不贴上去 —— 一张尺寸不对的图比没有图更难查。
	var want := _canvas_size()
	if image == null or (want.x > 0 and image.get_size() != want):
		_dirty = true
		_cooldown = 0.0
		FxCacheTrace.record("publish-drop", {
			"why": "cache-canvas", "frame": index,
			"got": image.get_size() if image != null else Vector2i.ZERO, "want": want,
		})
		return
	# 所有已展开节点的缩略图都来自这里：不重新求值，只取缓存帧的伴随小图。
	_emit_frame_previews(index)
	var display := _gpu_display(index, image, approx)
	_last_image = display
	var stats := _last_stats.duplicate()
	stats.erase("buffering")
	stats["cached"] = not paused
	stats["frame"] = index
	# approx = 这一帧只有低质量垫图（草稿 / 播放档），精确版还在后台算。
	# 状态栏与测试都靠它区分「真的好了」和「先垫一张」。
	stats["approx"] = approx
	stats["exact_frame"] = not approx
	# `draft` 必须显式赋值（不能只清）：stats 是上一条统计的副本，
	# 上一次草稿的标记会一路跟着后面每一帧 —— 精确帧上屏了，状态栏还写着「草稿」。
	# 反过来，垫图上屏也必须**说清楚**：屏幕糊了却没有任何解释，
	# 用户只会认为渲染坏了。倍率来自缓存里那一格的出处（0 = 不知道）。
	stats["draft"] = approx
	stats["draft_scale"] = cache.draft_scale_of(index) if approx else 0.0
	if paused:
		# 停止播放的「定格帧」不是播放命中：状态栏与测试都不该把它算进帧序列。
		stats["paused"] = true
	else:
		# **必须显式清掉**：stats 是上一条统计的副本，上一次定格留下的 `paused`
		# 会一路跟着后面每一帧 —— 播放中的缓存命中全被算成「定格帧」，
		# 于是「播放发布了几个缓存帧」读成 0。这类残留标记最难查：
		# 每一帧单独看都合理，只有连着数才看得出是旧字段在冒名。
		stats.erase("paused")
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
func _gpu_display(index: int, image: Image, approx: bool = false) -> Image:
	# 垫图（草稿 / 播放档）**不走显示缓存**：缓存键是「内容 + 帧号 + 画布 + 倍率」，
	# 垫图与精确帧用的是同一个键。一旦把糊图存进去，精确帧发布时会直接命中它 ——
	# 画质就永远上不去了，而且每一格都「看着正常」。
	if approx:
		return _postprocess(image)
	var content := store.content_key() if store != null else 0
	var scale := _display_scale()
	var canvas := _canvas_size()
	# 内容身份或画布尺寸变了就整层作废：尺寸不进键的话，
	# 「同一份文档、同一帧号、不同画布」会互相命中，贴上去就是一张尺寸不对的图。
	if content != _display_content or canvas != _display_canvas:
		_display_cache.clear()
		_display_content = content
		_display_canvas = canvas
		_display_fingerprint = cache.fingerprint()
	# 键必须含倍率：同一个内容身份下换个倍率，贴的是另一张图，不能互相命中。
	var key := "%d:%d:%dx%d:s%.3f" % [content, index, canvas.x, canvas.y, scale]
	if _display_cache.has(key):
		return _display_cache[key] as Image
	var out := _postprocess(image)
	if scale < 0.999 and out != null and not out.is_empty():
		# 只缩「贴到屏幕的这一张」。归档与导出拿的是 `raw`，一个像素都没动。
		var target := Vector2i(
			maxi(1, int(round(float(out.get_width()) * scale))),
			maxi(1, int(round(float(out.get_height()) * scale))))
		if target != out.get_size():
			out = out.duplicate()
			out.resize(target.x, target.y, Image.INTERPOLATE_BILINEAR)
	if _display_cache.size() < 512:
		_display_cache[key] = out
	return out


## 显示通道的采样倍率。策略里没写就是 1.0（全分辨率）。
## 这是**唯一**读 `display_scale` 的地方：求值、归档、导出全都不认识它。
func _display_scale() -> float:
	return clampf(float(policy.get("display_scale", 1.0)), 0.125, 1.0)


## 当前文档的画布尺寸。**这是屏幕上那一张的唯一合法尺寸**：
## 求值、发布、显示缓存都以它为准，任何异形图都不许上屏。
func _canvas_size() -> Vector2i:
	return FxGraphDoc.canvas(store.doc) if store != null else Vector2i.ZERO


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
	# 同步路径也要带预览根与剪枝计划：不然无头 / 关掉线程时
	# 旁支节点看不到预览，且这一帧会走未剪枝的另一套语义。
	runner.preview_roots = _typed_roots(_preview_roots())
	runner.compile_plan = _plan_for_current_doc()
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
			# 过期结果必须丢掉（它算的是另一份文档），但**不能就这么算了**：
			# 提交时已经把 `_dirty` 清成 false，如果这里只是 return，就没有任何人
			# 会再去请求「现在这份文档」的那一帧 —— 屏幕上就停在旧图上，
			# 直到用户再动一次别的东西。这正是「改了参数没效果 / 画面不回来」
			# 里最难查的一条：不报错、不缺帧、日志上也只是一次静默丢帧。
			_dirty = true
			_cooldown = 0.0
			return
	var raw: Image = result.get("image") as Image
	# 算出来的尺寸必须是当前画布。换尺寸的窗口期里，在途结果算的是上一版画布；
	# 它要是上屏，屏幕就会停在旧尺寸上，而且「一切正常」——只在改了画布才出现。
	if raw != null and not raw.is_empty():
		var want := _canvas_size()
		if want.x > 0 and raw.get_size() != want:
			FxCacheTrace.record("publish-drop", {
				"why": "canvas", "got": raw.get_size(), "want": want,
				"frame": int(result.get("frame_index", -1)),
			})
			_dirty = true
			_cooldown = 0.0
			return
	var params_by_node: Variant = result.get("node_params")
	if params_by_node is Dictionary:
		_last_node_params = params_by_node
	var values_by_node: Variant = result.get("node_values")
	_last_node_values = values_by_node if values_by_node is Dictionary else {}
	var stats: Variant = result.get("stats")
	_last_stats = stats if stats is Dictionary else {}
	_last_stats["quality"] = runner.quality
	_last_stats["operator_quality"] = runner.operator_quality
	# 实时求帧的结果一律不是草稿；是不是精确帧由算它的那一档质量回答。
	_last_stats["draft"] = false
	_last_stats["exact_frame"] = bool(result.get("exact", false))
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
	# 急件的记账必须在这里清：结果回来了（哪怕因为稳定期被拒收）就意味着
	# 「这一帧已经提交过」，不清的话 `_urgent_submitted == next` 会把**后续**的
	# 重新提交永久挡掉 —— 表现为播放卡住，直到 STALL_LIMIT 强制放行一帧。
	# 这是「换文档后立刻按播放」时最明显的一次卡顿，只有值不值得重算的分支能暴露它。
	var done_index := int(result.get("frame_index", -1))
	if done_index >= 0 and _urgent_submitted == done_index:
		_urgent_submitted = -1
	if _inflight_live == done_index:
		_inflight_live = -1
	if _cache_on:
		_last_stats["cache"] = cache.stats(prefetch_progress())
	# 交互帧与缓存帧走**同一个**显示通道：同一帧无论从哪条路径发布，
	# 过不过 GPU 后处理必须一致，否则起播/暂停瞬间会闪一下（细节突然变锐/变钝）。
	var index := int(result.get("frame_index", -1))
	if index < 0 and store != null:
		index = cache.index_for_time(store.current_time)
	# `_last_image` 的定义是「屏幕上这一张」。被压掉的发布没上屏，
	# 就不能改它 —— 否则诊断与探针会把「算完了」读成「已经显示出来了」。
	if not suppress_render:
		_last_image = _gpu_display(index, raw) if index >= 0 else _postprocess(raw)
		rendered.emit(_last_image, _last_stats)
		if _stats_emit_clock <= 0.0:
			_stats_emit_clock = 0.2
			stats_changed.emit(_last_stats)
		node_params_resolved.emit(_last_node_params)
		node_values_resolved.emit(_last_node_values)
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
		maxf(float(tl.get("duration", 1.0)), 0.0), "archive")
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
	# 身份一起写：这一帧是哪份文档算出来的，分发时必须能回答。
	cache.put(index, raw, exact, false, _doc_revision())
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
	_inflight_live = index
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
		"preview_roots": _preview_roots(),
		"compile_plan": _plan_for_current_doc(),
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
	if draft != null:
		draft.stop()
		draft = null
	if _worker != null:
		_worker.stop()
		_worker = null
	threaded = false
	# 后端持有 GPU 资源（compute 管线 / shader RID）。退出时不清，引擎会在
	# 关窗后报 "1 RID of type Compute was leaked"——不影响功能，但那是真的没释放。
	# 放在线程停掉之后：让在途的渲染先结束，再拆资源。
	FxRenderBroker.invalidate()


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
		FxCacheTrace.record(FxCacheTrace.KIND_CHANGE, {
			"keys": keys, "gate": "layout_only", "content": false})
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
		FxCacheTrace.record(FxCacheTrace.KIND_CHANGE, {
			"keys": keys, "gate": "identity_same", "content": false,
			"revision": identity})
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
	var param_changed := _touches_params(keys)
	# 纯时间变化（拖时间轴 / 上一帧 / 下一帧）：**先读缓存，再考虑求值**。
	# 拖动时每个鼠标事件都是一次 set_time，实时求值（示范工程一帧上百毫秒）
	# 永远追不上指针，于是「拖了没反应」—— 而用户拖过的那一段其实早就缓存好了。
	# 缓存命中就当场贴上去、不排求值；没命中才走下面原来的路径。
	# 这也顺手解决「拖动把预渲染挤掉」：拖动不再占用工作线程。
	if timed and not content and not structural and not tracks_changed and not param_changed:
		if _serve_cached_time():
			FxCacheTrace.record(FxCacheTrace.KIND_CHANGE, {
				"keys": keys, "gate": "time_from_cache", "content": false,
				"revision": identity, "time": store.current_time if store != null else 0.0})
			return
	if structural or tracks_changed:
		runner.invalidate_cache()
		FxRenderBroker.invalidate()
	if param_changed:
		# **差量失效**：只丢掉「改动节点的下游闭包」里已经缓存的条目。
		# 旧实现不管改哪一个参数都整表清空，于是改一个末端参数也要从头再算
		# 整条上游链 —— 缓存存在、但改了参数后它一次都不命中。
		# 上游条目的签名没变，仍然有效，这是本条的全部收益所在。
		var changed := _changed_nodes(keys)
		var report := runner.invalidate_downstream(changed)
		FxCacheTrace.record(FxCacheTrace.KIND_CHANGE, {
			"keys": keys, "gate": "downstream",
			"roots": report.get("roots", []),
			"touched": int(report.get("touched", 0)),
			"dropped": int(report.get("dropped", 0)),
			"kept": int(report.get("kept", 0)),
			"revision": identity})
		FxRenderBroker.invalidate()
		# 改参数必须**立刻**换桶：新参数算出的帧不能写进旧内容的桶里。
		# 装载工程的稳定期里例外（那时桶还没定，等稳定了再建）。
		if _settle >= CONTENT_SETTLE:
			_ensure_bucket_now()
	if structural or timed or tracks_changed or param_changed:
		request_render()
	FxCacheTrace.record(FxCacheTrace.KIND_CHANGE, {
		"keys": keys, "gate": "content", "content": content,
		"revision": identity, "generation": _content_generation,
		"structural": structural, "timed": timed,
		"tracks": tracks_changed, "params": param_changed,
		"settle": _settle, "playing": playing})


## 纯时间变化时把「这一格已经有精确帧」这件事报给调度器。返回 true 表示
## 「屏幕由缓存接管，别再排求值」。
##
## 只认**精确帧**（`STATE_READY` + 内容身份相符 + 尺寸相符）：垫图照旧走
## 实时/草稿通道，否则「拖到一段只有草稿的区间」会把糊图当成结论钉在屏幕上。
##
## 这里**不直接发布**：调用点正处在 store 的 coeffect 广播中间，在广播里 emit
## 会让订阅者重入 `notify`。只把 `_dirty` 清掉、把上一张的贴图账清掉，
## 由本帧的 `_process` 走既有的 `_pin_ready_frame` 贴图（最晚晚一帧 ≈16ms）。
func _serve_cached_time() -> bool:
	if not _cache_on or store == null:
		return false
	var index := cache.index_for_time(store.current_time)
	if index < 0 or cache.state(index) != FxFrameCache.STATE_READY:
		return false
	if not cache.accepts(index, _doc_revision()):
		return false
	if cache.fetch(index) == null:
		return false
	# 不在这里清 `_pinned_key`：`_pin_ready_frame` 自己按「内容身份 + 帧号 + 画质档」
	# 判重，换帧/换画质自然会重贴。无脑清掉会让**同一帧**再贴一次，
	# 在诊断里表现为「拖了个节点也发了一次 rendered」——那正是判「有没有重算」
	# 的断言最怕的假信号。
	_dirty = false
	_cooldown = 0.0
	return true


## 立刻按当前文档重算一次桶（帧数 / 指纹 / 磁盘已有帧）。
func _ensure_bucket_now() -> void:
	if store == null or store.doc.is_empty():
		return
	var tl := FxGraphDoc.timeline(store.doc)
	_cache_ensure_fingerprint(maxi(int(tl.get("fps", 30)), 1),
		maxf(float(tl.get("duration", 1.0)), 0.0), "param")


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


## 从变更键里取出**是哪些节点**变了：`node:<id>` / `param:<id>:<path>`。
##
## 差量失效要的是节点集合，而不是「有没有参数变化」这个布尔。旧实现只回答了
## 后者，所以只能整表清空 —— 信息在键里一直都在，只是没人去解。
func _changed_nodes(keys: Array) -> Array[String]:
	var out: Array[String] = []
	for key in keys:
		var text := String(key)
		var id := ""
		if text.begins_with("param:"):
			id = text.substr(6).get_slice(":", 0)
		elif text.begins_with("node:"):
			id = text.substr(5)
		if id.is_empty() or out.has(id):
			continue
		out.append(id)
	return out
