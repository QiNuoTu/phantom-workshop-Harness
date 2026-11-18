extends SceneTree
## 实机验收（**开窗跑**）：把「调色抠像」验收工程当成用户那样打开、播放、导出。
##
## 为什么不能只靠 headless：`--headless` 下不执行 `_draw()`、不建纹理、预渲染线程常被跳过。
## 28 个原生算子第一次真正跑起来是在开窗时 —— 原生库加载、线程安全声明、
## 显示通道、导出通道，全都只在开窗后才成立。
##
## 它验四件事：
##   1. **工程能打开**，55 个节点 / 34 种类型全部有定义、有算子实现；
##   2. **每个算子都被真实求值**：预览分支把 28 个算子全挂在输出之外，
##      少一个就会在 `frame.warnings` 或引擎日志里露出来；
##   3. **播放能推进**（帧号前进、画面在变），不是"卡在第一帧"；
##   4. **导出能落盘**（PNG 序列），说明整条链在显示之外也成立。
##
## 运行（必须开窗）：
##   godot --path . --script res://tests/runtime_accept_lookdev.gd

const PROJECT := "res://examples/demo/调色抠像.fxproj"
const OUT_DIR := "user://graph_test/accept"

var failures: Array[String] = []
var checks := 0
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


func _run() -> void:
	print("== 调色抠像 · 实机验收 ==")
	# 外壳的 _ready 是异步的（面板、皮肤、渲染后端都要等一帧），
	# 立刻读 store 会拿到 null —— 冒烟里也是先等 10 帧。
	for _i in range(10):
		await process_frame
	store = shell.store
	render = shell.service("render")
	_check(store != null and render != null, "外壳 / 文档 / 渲染服务都在")
	_close_welcome()

	var actions: Object = shell.service("document")
	actions.call("open_path", PROJECT)
	for _i in range(600):
		await process_frame
		if (store.doc.get("nodes", []) as Array).size() > 50:
			break
	var nodes: Array = store.doc.get("nodes", [])
	# 不断言精确节点数：验收工程会随"新功能进示例工程"长大。
	# 真正要盯的是下面两条 —— 每个类型都有定义、每个算子都已绑定。
	_check(nodes.size() >= 55, "验收工程打开（%d 节点）" % nodes.size())

	# ---- 1. 目录契约：每个节点类型都有定义、都有算子实现 ----
	var types := {}
	for raw in nodes:
		types[String((raw as Dictionary).get("type", ""))] = true
	var missing_def := 0
	var missing_op := 0
	for type_id in types.keys():
		var def: FxNodeDef = FxCatalog.def(type_id)
		if def == null:
			missing_def += 1
			continue
		if not FxOpRegistry.has_op(def.op):
			missing_op += 1
	_check(missing_def == 0, "%d 种节点类型全部有定义" % types.size())
	_check(missing_op == 0, "全部算子已绑定（含原生包里的全部算子）")

	# ---- 2. 首帧 ----
	for _i in range(900):
		await process_frame
		if render.last_image() != null:
			break
	var first: Image = render.last_image()
	_check(first != null, "出第一帧（%s）" % ("null" if first == null else
		"%d×%d" % [first.get_width(), first.get_height()]))
	# 呈现器的统计里 warnings 可能是数组，也可能是条数（两种都见过）；
	# 这里只问"有没有"，不规定它的类型 —— 否则断言会因为别人的字段改型而红。
	var stats: Dictionary = render.last_stats()
	var warnings: Variant = stats.get("warnings", [])
	var warning_count := (warnings as Array).size() if warnings is Array else int(warnings)
	_check(warning_count == 0, "首帧没有求值告警（%d 条）" % warning_count)

	# ---- 3. 播放推进：帧号前进 + 画面确实在变 ----
	var start_frame := render.frame_index()
	var start_image: Image = render.last_image()
	render.set_playing(true)
	var changed := false
	for _i in range(240):
		await process_frame
		var now: Image = render.last_image()
		if now != null and start_image != null and _pixel_diff(start_image, now) > 0:
			changed = true
		if render.frame_index() > start_frame + 2 and changed:
			break
	render.set_playing(false)
	_check(render.frame_index() > start_frame, "播放推进帧号（%d → %d）" % [
		start_frame, render.frame_index()])
	_check(changed, "播放期间画面在变（不是卡住的一帧）")

	# ---- 4. 导出落盘 ----
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	for old in DirAccess.get_files_at(OUT_DIR):
		DirAccess.remove_absolute(OUT_DIR.path_join(String(old)))
	shell.export_now("png.sequence", OUT_DIR)
	var written := 0
	for _i in range(600):
		await process_frame
		written = DirAccess.get_files_at(OUT_DIR).size()
		if written > 0:
			break
	_check(written > 0, "导出 PNG 序列落盘（%d 个文件）" % written)

	print("----")
	print("断言 %d 条" % checks)
	if failures.is_empty():
		print("实机验收全部通过")
		quit(0)
	else:
		print("失败 %d 项：" % failures.size())
		for item in failures:
			print("  - ", item)
		quit(1)


func _close_welcome() -> void:
	var actions: Object = shell.service("document")
	if actions != null and actions.has_method("set_show_welcome"):
		actions.call("set_show_welcome", false)
	for child in shell.get_children():
		if child is FxWelcomeWindow:
			(child as FxWelcomeWindow).queue_free()


func _pixel_diff(a: Image, b: Image) -> int:
	if a == null or b == null:
		return -1
	var da := a.get_data()
	var db := b.get_data()
	if da.size() != db.size():
		return -2
	var count := 0
	var step: int = maxi(1, da.size() / 4096)
	var i := 0
	while i < da.size():
		if da[i] != db[i]:
			count += 1
		i += step
	return count


func _check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("  ok %s" % message)
	else:
		failures.append(message)
		print("  FAIL: %s" % message)
