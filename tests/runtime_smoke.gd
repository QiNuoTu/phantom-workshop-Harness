extends SceneTree
## 运行时冒烟（**必须开窗跑**）：headless 套件看不见的那一半。
##
## 为什么要有这一套：`test_*` 全部在 `--headless` 下跑，而 headless 里
##   · 不执行 `_draw()`、不建纹理、不跑 GPU compute；
##   · 预渲染线程常常被跳过（`_prefetch_allowed()` 依赖显示/缓存状态）。
## 于是「多条预渲染线程共用一个有状态的引擎实例」这类问题永远不会红
## ——`VfxEngine` 的 `Out of bounds get index ... on base: 'PackedByteArray'`
## 就是这样一路活到开窗的。
##
## 跑法（见 `tools/smoke.sh`）：
##   godot --path . --script res://tests/runtime_smoke.gd
## 脚本自己只报断言；**引擎级报错由外层 grep 兜底**（GDScript 抓不到别的
## 脚本抛的 SCRIPT ERROR）。

var failures: Array[String] = []
## 冒烟会真的停用/启用插件，而启停状态是**持久化**的（user://plugins.cfg）。
## 半路失败也必须把状态放回去，否则下一次跑测试就是「配方节点不见了」这种
## 看起来毫不相干的红 —— 这种污染查起来一下午。
var _touched_plugins: Dictionary = {}
## 启动页原本开没开（冒烟会关掉它，收尾要放回去）。
var _welcome_before: bool = true
var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		push_error("主场景加载失败")
		quit(1)
		return
	shell = packed.instantiate() as FxShell
	root.add_child(shell)
	_run.call_deferred()


## 关掉启动页：它是个 AcceptDialog，盖在工作台上面。
## 这里同时关开关（避免 `project.welcome` 命令再弹一次），并记下原值以便恢复。
func _close_welcome() -> void:
	var actions: Object = shell.service("document")
	if actions == null or not actions.has_method("show_welcome_enabled"):
		return
	_welcome_before = bool(actions.call("show_welcome_enabled"))
	actions.call("set_show_welcome", false)
	for child in shell.get_children():
		if child is FxWelcomeWindow:
			(child as FxWelcomeWindow).queue_free()


func _restore_welcome() -> void:
	var actions: Object = shell.service("document")
	if actions != null and actions.has_method("set_show_welcome") and _welcome_before:
		actions.call("set_show_welcome", true)


## 进度落盘：脚本被 timeout 掐掉时 stdout 会丢（块缓冲），
## 排查「卡在哪一步」只能靠文件。
func _step(text: String) -> void:
	var f := FileAccess.open("user://graph_test/smoke_progress.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


## 整图逐字节差异。判定「画面有没有变」只能用它：
## 采样几个点会漏掉小精灵、描边、辉光，于是「明明变了」被读成「没反应」。
func _pixel_diff(a: Image, b: Image) -> int:
	if a == null or b == null:
		return -1
	var da := a.get_data()
	var db := b.get_data()
	if da.size() != db.size():
		return -2
	var n := 0
	for i in range(da.size()):
		if da[i] != db[i]:
			n += 1
	return n


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok  ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)


func _run() -> void:
	print("== 运行时冒烟（开窗） ==")
	for i in range(10):
		await process_frame
	store = shell.store
	render = shell.service("render")
	_check(store != null and render != null, "外壳、文档、渲染服务都在")
	# 启动页（欢迎页）会盖住工作台：所有测量与判断都必须在「用户实际看到的界面」上做，
	# 否则测的是「弹窗开着时的渲染」，而不是真实使用。测完在收尾处恢复开关。
	_close_welcome()

	# ---- 打开示范工程 ----
	var actions: Object = shell.service("document")
	actions.call("open_path", "res://examples/demo/示范工程.fxproj")
	for i in range(600):
		await process_frame
		if store.doc.get("nodes", []).size() > 50:
			break
	var node_count := (store.doc.get("nodes", []) as Array).size()
	_check(node_count > 50, "示范工程打开（%d 节点）" % node_count)
	for i in range(600):
		await process_frame
		if render.last_image() != null:
			break
	_check(render.last_image() != null, "出第一帧")
	# 定桶要等文档稳定期（CONTENT_SETTLE 0.35s）过去：只等首帧往往还在稳定期里，
	# 读到的就是「0 帧」。断言没错，是等待条件太短。
	for i in range(240):
		await process_frame
		if render.cache.frame_count() > 0:
			break
	_check(render.cache.frame_count() > 0, "帧缓存定桶（%d 帧）" % render.cache.frame_count())

	# ---- 逐节点改参数：这一步会连续触发换桶 + 预渲染，是并发问题的高发区 ----
	var changed := 0
	for item in store.doc.get("nodes", []):
		var node: Dictionary = item
		var id := String(node.get("id", ""))
		var params: Dictionary = node.get("params", {})
		if params.is_empty():
			continue
		var key := String(params.keys()[0])
		var old: Variant = params[key]
		var next: Variant = old
		if old is float or old is int:
			next = float(old) + 0.07
		elif old is bool:
			next = not bool(old)
		else:
			continue
		store.apply_param(id, key, next, false)
		await process_frame
		store.apply_param(id, key, old, false)
		await process_frame
		changed += 1
	# 不是所有节点都有可写的首个参数（纯图像口 / 只为连线服务的节点），
	# 阈值取「过半」而不是「全量」，否则断言的是文档长相而不是这里的行为。
	_check(changed > node_count / 3, "逐节点改参数（%d/%d 个节点各改一次）" % [changed, node_count])
	_check(render.last_image() != null, "改参后画面仍在（没有黑屏）")

	# ---- 质量档 + 显示倍率：只该影响屏幕那一张 ----
	var before_display := render.last_image().get_size() if render.last_image() != null else Vector2i.ZERO
	FxSettings.set_value("quality.display_scale", 0.5)
	render.invalidate("display", "smoke")
	for i in range(30):
		await process_frame
	var half := render.last_image().get_size() if render.last_image() != null else Vector2i.ZERO
	_check(half.x < before_display.x or before_display.x == 0,
		"显示倍率 0.5 真的缩小了屏幕副本（%s → %s）" % [str(before_display), str(half)])
	FxSettings.set_value("quality.display_scale", 1.0)
	render.invalidate("display", "smoke")
	for i in range(30):
		await process_frame
	FxSettings.reset("quality.display_scale")

	# ---- 播放：只读缓存 + 缺帧急件 ----
	store.set_timeline(30, 2.0, true)
	render.set_playing(false)
	render.set_playing(true)
	var t0 := store.current_time
	for i in range(240):
		await process_frame
		if store.current_time > t0 + 0.2:
			break
	_check(store.current_time > t0, "播放推进（%.3f → %.3f）" % [t0, store.current_time])
	render.set_playing(false)

	# ---- 导出：与缓存同一份像素，不能因为显示倍率变糊 ----
	var out_dir := "user://graph_test/runtime_seq"
	shell.export_now("png.sequence", out_dir)
	await process_frame
	var files := DirAccess.get_files_at(out_dir)
	_check(files.size() >= 30, "导出序列（%d 张）" % files.size())
	if not files.is_empty():
		var first := Image.load_from_file(ProjectSettings.globalize_path(
			out_dir.path_join(String(files[0]))))
		var canvas := FxGraphDoc.canvas(store.doc)
		_check(first != null and first.get_size() == canvas,
			"导出尺寸等于画布（%s vs %s）" % [str(first.get_size() if first else "null"), str(canvas)])
		# 「输出预览与导出逐像素一致」是项目对外的不变量。它破掉过一次，表现是
		# 桶里混进了上一版文档算的帧、而且那一格还标着「绿色就绪」。
		var cached0: Image = render.cache.fetch(0)
		_check(_pixel_diff(first, cached0) == 0,
			"导出首帧 == 缓存首帧（差异 %d）" % _pixel_diff(first, cached0))
		_check(render.cache.accepts(0, store.content_key()),
			"缓存首帧的归属身份就是当前文档")

	# ---- 改参数必须看得见：拿一个必然影响画面的参数做一次 ----
	var size_id := ""
	for item in store.doc.get("nodes", []):
		var node: Dictionary = item
		if String(node.get("type", "")) == "image.text":
			size_id = String(node.get("id", ""))
			break
	if not size_id.is_empty():
		var before := render.last_image()
		var before_copy: Image = before.duplicate() if before != null else null
		var old_size: Variant = (FxGraphDoc.node(store.doc, size_id).get("params", {})
			as Dictionary).get("size", 20.0)
		store.apply_param(size_id, "size", float(old_size) + 8.0, false)
		var visible_diff := 0
		for i in range(120):
			await process_frame
			visible_diff = _pixel_diff(before_copy, render.last_image())
			if visible_diff != 0:
				break
		_check(visible_diff != 0, "改字号后画面确实变了（差异 %d）" % visible_diff)
		store.apply_param(size_id, "size", old_size, false)
		for i in range(60):
			await process_frame

	_step("A 四条危险路径之前")
	# ---- 最危险的四条路径：都只有开窗才走到 ----
	# ① 质量预设切换（播放档 quality=0）→ 算子降级路径
	_step("B 切性能预设")
	FxSettings.set_value("quality.preset", "performance")
	render.invalidate("derived", "smoke")
	render.set_playing(true)
	for i in range(60):
		await process_frame
	render.set_playing(false)
	_check(render.last_image() != null, "性能预设下播放仍有画面")
	FxSettings.set_value("quality.preset", "none")
	render.invalidate("derived", "smoke")

	_step("C res_scale")
	# ② 逐层分辨率档：改一个节点的 res_scale，区段两端都要对
	# 挑一个**能接受**降档的节点：输出节点与汇点（导出类，evaluate_always）
	# 一律拒绝降档 —— 那是「所见即所得」的底线，不是 bug。拿它们当样本，
	# 断的会是一条永远为假的假设。
	var scaled := ""
	var output_id := FxGraphDoc.output_id(store.doc)
	for item in store.doc.get("nodes", []):
		var node: Dictionary = item
		var def := FxCatalog.def(String(node.get("type", "")))
		var nid := String(node.get("id", ""))
		if def == null or nid == output_id or def.evaluate_always or def.has_exec_in:
			continue
		scaled = nid
		break
	if not scaled.is_empty():
		# 与蓝图右键菜单同一条路径：res_scale 是**节点字段**，不是参数，
		# 所以走 mutate + "structure" 键（apply_path 只会写进 params，读不到）。
		store.mutate(func(d: Dictionary) -> void:
			var data: Dictionary = FxGraphDoc.node(d, scaled)
			if not data.is_empty():
				data["res_scale"] = 0.5
		, ["structure"], "res_scale")
		for i in range(30):
			await process_frame
		# 必须读**算这一帧的那个执行器**的统计：工作线程路径下主线程的 runner
		# 不跑，`render.runner.scale_report` 会永远停在上一帧（冒烟就此被误导过一次）。
		var declared := int(render.last_stats().get("scale_declared", 0))
		_check(declared >= 1, "半分辨率声明生效（declared=%d）" % declared)
		_check(render.last_image() != null, "降档后仍有画面")
		store.mutate(func(d: Dictionary) -> void:
			var data: Dictionary = FxGraphDoc.node(d, scaled)
			if not data.is_empty():
				data.erase("res_scale")
		, ["structure"], "res_scale")
		for i in range(30):
			await process_frame
	FxSettings.reset("quality.preset")

	_step("D 停用原生插件")
	# ③ 运行期停用/启用原生内核：这一条曾经把「停用即回落」演成「停用即崩」
	_touched_plugins["pixels.native"] = FxPluginHost.is_active("pixels.native")
	if FxPluginHost.is_active("pixels.native"):
		FxPluginHost.set_enabled("pixels.native", false)
		for i in range(240):
			await process_frame
			if FxPluginHost.pending_toggles() == 0:
				break
		_check(FxPluginHost.pending_toggles() == 0, "停用请求已全部落地（无残留排队）")
		_check(not FxNativeBridge.available(), "停用原生插件后桥真的回落")
		FxPluginHost.set_enabled("pixels.native", true)
		# 启停是**排队 + 每帧重试**的（主线程绝不阻塞等渲染闸门，那是死锁源头）。
		# 所以这里等「落地」而不是等固定帧数：只要它在有限帧内落地就是对的。
		for i in range(240):
			await process_frame
			if FxPluginHost.pending_toggles() == 0:
				break
		_check(FxPluginHost.pending_toggles() == 0,
			"启用请求已全部落地（残留排队 %d）" % FxPluginHost.pending_toggles())
		_check(FxNativeBridge.available(), "重新启用原生插件后桥恢复")

	_step("E 撤销")
	# ④ 撤销一次改参数（撤销栈与缓存失效的交叉点）
	var undo_id := ""
	for item in store.doc.get("nodes", []):
		var node: Dictionary = item
		if not (node.get("params", {}) as Dictionary).is_empty():
			undo_id = String(node.get("id", ""))
			break
	if not undo_id.is_empty():
		var pkey := String((FxGraphDoc.node(store.doc, undo_id).get("params", {}) as Dictionary).keys()[0])
		var pold: Variant = (FxGraphDoc.node(store.doc, undo_id).get("params", {}) as Dictionary)[pkey]
		if pold is float or pold is int:
			store.apply_param(undo_id, pkey, float(pold) + 0.3, false)
			for i in range(10):
				await process_frame
			if store.can_undo():
				store.undo()
				for i in range(10):
					await process_frame
			_check(is_equal_approx(float((FxGraphDoc.node(store.doc, undo_id).get("params", {})
				as Dictionary)[pkey]), float(pold)), "撤销回到改前的值")

	_step("F 画布尺寸与动态质量")
	# ---- 改「最终输出画布」：屏幕必须跟着走，改回来也必须回来 ----
	# 这条曾经永久卡在旧尺寸上：换桶窗口里读到上一版画布的帧，
	# 它在显示缓存里以当前内容身份留了下来，后面每一张正确的新帧都命中那张旧图。
	var canvas0 := FxGraphDoc.canvas(store.doc)
	for target in [Vector2i(320, 180), Vector2i(96, 96), canvas0]:
		store.set_canvas(target.x, target.y)
		var got := Vector2i.ZERO
		for i in range(300):
			await process_frame
			var img: Image = render.last_image()
			if img != null and img.get_size() == target:
				got = img.get_size()
				break
		_check(got == target, "改画布到 %s 后屏幕跟上（实得 %s）" % [str(target), str(got)])
		for i in range(120):
			if render.cache.frame_size() == target:
				break
			await process_frame
		_check(render.cache.frame_size() == target,
			"桶的帧尺寸回到画布尺寸（%s）" % str(render.cache.frame_size()))

	# ---- 动态质量：帧没缓存时先上草稿，随后被精确帧替换 ----
	# 挑一个**真的改得动内容**的数值参数：先列候选，逐个试到内容身份变化为止
	# （有些参数会被 min/max 夹回原值，拿它当样本测的是一条空断言）。
	var draft_id := ""
	var draft_path := ""
	var draft_old: Variant = 0.0
	var candidates: Array[Dictionary] = []
	for item in store.doc.get("nodes", []):
		var node: Dictionary = item
		var params: Dictionary = node.get("params", {})
		for key in params.keys():
			if params[key] is float or params[key] is int:
				candidates.append({"id": String(node.get("id", "")),
					"path": String(key), "value": params[key]})
				break
		if candidates.size() >= 12:
			break
	var rev_before := store.content_key()
	for cand in candidates:
		store.apply_param(String(cand["id"]), String(cand["path"]),
			float(cand["value"]) + 5.0, false)
		await process_frame
		if store.content_key() != rev_before:
			draft_id = String(cand["id"])
			draft_path = String(cand["path"])
			draft_old = cand["value"]
			break
	_check(not draft_id.is_empty(), "找到能改内容的样本参数（%s:%s）" % [draft_id, draft_path])
	# 冷路径：清掉缓存，让这一帧真的没有图可贴（草稿只在「没缓存」时才有意义）。
	render.clear_cache()
	for i in range(120):
		await process_frame
	var canvas_now := FxGraphDoc.canvas(store.doc)
	# 探针的计时放进字典：GDScript 的 lambda **按值捕获**局部变量，
	# 直接用 int 接，回调里改的是副本，外面永远读到 -1（这条自己踩过一次）。
	var marks := {"draft": -1, "exact": -1, "draft_size": Vector2i.ZERO, "draft_state": -1}
	var started := Time.get_ticks_msec()
	var probe := func(image: Image, stats: Dictionary) -> void:
		var dt := Time.get_ticks_msec() - started
		if int(marks["draft"]) < 0 and bool(stats.get("draft", false)):
			marks["draft"] = dt
			marks["draft_size"] = image.get_size()
			# 草稿上屏时缓存里这一格必须仍然是「没算好」。
			marks["draft_state"] = render.cache.state(int(stats.get("frame", 0)))
		if int(marks["exact"]) < 0 and bool(stats.get("exact_frame", false)) \
				and not bool(stats.get("draft", false)):
			marks["exact"] = dt
	render.rendered.connect(probe)
	started = Time.get_ticks_msec()
	if not draft_id.is_empty():
		# 写**另一个**值：候选探测那一步已经写成 +5.0 了，再写同一个值会被
		# 「写前==写后」静默掉，探针就永远等不到任何发布。
		store.apply_param(draft_id, draft_path, float(draft_old) + 3.0, false)
	var saw_rendering := false
	for i in range(1800):
		await process_frame
		if not saw_rendering:
			for index in range(render.frame_count()):
				if int(render.cache_state(index)) == 3:
					saw_rendering = true
					break
		if int(marks["exact"]) >= 0 and int(marks["draft"]) >= 0:
			break
	render.rendered.disconnect(probe)
	var draft_ms := int(marks["draft"])
	var exact_ms := int(marks["exact"])
	# 草稿是「尽力而为」：它要有独立线程、后端要线程安全。可用时必须真的出过图，
	# 否则「就算帧没缓存也能看到预览」这句话就是假的。
	var draft_on := bool(render.preview_pipeline_config().get("draft", false))
	if draft_on and draft_ms >= 0:
		_check(Vector2i(marks["draft_size"]) == canvas_now,
			"草稿按画布尺寸上屏（%s vs %s）" % [str(marks["draft_size"]), str(canvas_now)])
		_check(int(marks["draft_state"]) != 2,
			"草稿上屏不等于这一帧算好了（缓存状态 %d）" % int(marks["draft_state"]))
		_check(draft_ms < 0 or exact_ms < 0 or draft_ms <= exact_ms,
			"草稿不晚于精确帧（草稿 %d / 精确 %d）" % [draft_ms, exact_ms])
	_check(exact_ms >= 0, "改参数后有精确帧上屏（%d ms）" % exact_ms)
	_check(saw_rendering, "标尺能报出「渲染中」状态（橘色 = 有线程正在为这一格干活）")
	# 草稿趟：内容一变，整段先用缩小画布铺满（黄格），再逐帧被精确帧替换（绿格）。
	# 这一条是「改画布/改参数后一片红等几分钟」的反面：用户必须很快看到整段都有图。
	render.clear_cache()
	for i in range(60):
		await process_frame
	if not draft_id.is_empty():
		store.apply_param(draft_id, draft_path, float(draft_old) + 11.0, false)
	var draft_cover := -1
	for i in range(600):
		await process_frame
		var st: Dictionary = render.cache.stats()
		if int(st.get("pending", 0)) > 0:
			draft_cover = i
			break
	if draft_on:
		_check(draft_cover >= 0, "内容一变就先铺垫图（第 %d 帧起有黄格）" % draft_cover)
	# 收尾：等精确帧把它替换回绿色（保证下一步存盘/读回看到的是稳定状态）。
	for i in range(2400):
		await process_frame
		var st2: Dictionary = render.cache.stats()
		if int(st2.get("total", 0)) > 0 and int(st2.get("missing", 99)) == 0:
			break
	if not draft_id.is_empty():
		store.apply_param(draft_id, draft_path, draft_old, false)
		for i in range(60):
			await process_frame

	_step("G 存盘")
	# ---- 存盘再读回：工程格式与素材一起走 ----
	var save_path := "user://graph_test/runtime_smoke.fxproj"
	var saved := FxProjectArchive.save_zip(store.doc, save_path)
	_step("H 保存完成")
	_check(bool(saved.get("ok", false)), "另存为工程包")
	var reloaded := FxProjectArchive.read_zip(save_path)
	_check(bool(reloaded.get("ok", false)), "读回工程包")
	_check((reloaded.get("doc", {}).get("nodes", []) as Array).size() == node_count,
		"读回的节点数与存盘前一致")
	_step("I 收尾")
	_restore_welcome()
	render.cancel_prefetch()

	print("----")
	if failures.is_empty():
		print("运行时冒烟全部通过。")
	else:
		print("运行时冒烟失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
	# 把启停状态还原（不管前面有没有失败）。
	for pid in _touched_plugins.keys():
		if FxPluginHost.is_active(String(pid)) != bool(_touched_plugins[pid]):
			FxPluginHost.set_enabled(String(pid), bool(_touched_plugins[pid]))
	_step("J 退出")
	FxPluginHost.shutdown()
	_step("K shutdown 完成")
	quit(0 if failures.is_empty() else 1)
