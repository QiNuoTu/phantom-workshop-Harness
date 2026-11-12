class_name FxBoot
extends RefCounted
## 启动时序：进度事件 + 错误收集 + 启动日志。
##
## 为什么单独一层：
##   · 启动期跨了好几个模块（宿主扫插件 → 目录读节点定义 → 配置 → 面板 → 文档），
##     谁都不该互相认识，但用户需要一条连贯的「正在加载什么」；
##   · 出错时不能只有 push_error 一行栈，专业软件要的是「哪一步、哪个文件、最后汇总」；
##   · 启动期还没有界面，所以事件必须是纯数据的：界面/控制台/诊断命令各自订阅。
##
## 用法：begin() → step() … → finish()；非启动期调用 step() 是空操作，
## 因此插件热重扫时同一批代码可以原样复用，不会污染启动报告。

const LOG_DIR := "user://logs"
const LOG_PATH := "user://logs/startup.log"
## 启动日志最多缓冲这么多行，避免病态环境下无限增长。
const MAX_LINES := 4000

static var _active: bool = false
static var _label: String = "启动"
static var _done: int = 0
static var _total: int = 0
static var _current: String = ""
static var _steps: Array[Dictionary] = []
static var _errors: Array[Dictionary] = []
static var _warnings: Array[Dictionary] = []
static var _lines: PackedStringArray = PackedStringArray()
static var _listeners: Array[Callable] = []
## 实际写成功的路径：便携版可能落到 exe 旁边，诊断要报真实位置。
static var _written_path: String = LOG_PATH
static var _started_ms: int = 0
static var _finished_ms: int = 0
static var _quiet: bool = false


## 开始一轮启动。total 可以先给 0，之后用 set_total() 修正（扫描前不知道有多少个插件）。
static func begin(label: String = "启动", total: int = 0) -> void:
	_active = true
	_label = label
	_done = 0
	_total = maxi(0, total)
	_current = ""
	_steps.clear()
	_errors.clear()
	_warnings.clear()
	_lines = PackedStringArray()
	_started_ms = Time.get_ticks_msec()
	_finished_ms = 0
	_written_path = LOG_PATH
	_quiet = OS.get_cmdline_user_args().has("--fx-quiet-boot")
	_emit("begin")


static func set_total(total: int) -> void:
	_total = maxi(0, total)
	_emit("total")


## 追加预算：扫描前不知道下面还有多少件事，先声明再逐条 step，进度条才不会倒退。
static func expect(extra: int) -> void:
	if not _active or extra <= 0:
		return
	_total += extra
	_emit("total")


## 推进一步。label 是正在做的事（「插件 editor.graph」「节点定义 nodes.json」）。
## 传 advance = false 只更新当前项，不增加计数。
static func step(label: String, advance: bool = true) -> void:
	if not _active:
		return
	_current = label
	if advance:
		_done += 1
	_steps.append({"label": label, "done": _done, "total": _total})
	_trace("%d/%d %s" % [_done, _total, label] if _total > 0 else label)
	_emit("step")


## 启动结束：写日志、发事件、打印汇总。
static func finish() -> void:
	if not _active:
		return
	_active = false
	_finished_ms = Time.get_ticks_msec()
	_done = _total if _total > 0 else _done
	var text := summary()
	_trace(text)
	_write_log()
	if not _quiet:
		print(text)
		for item in _errors:
			print("  ✗ [%s] %s" % [String(item.get("where", "")), String(item.get("message", ""))])
	_emit("finish")


## 报告一次错误：控制台、错误列表、启动日志三处都留痕。
static func error(where: String, message: String) -> void:
	_errors.append({"where": where, "message": message, "ms": Time.get_ticks_msec()})
	_trace("[错误] %s：%s" % [where, message])
	push_error("[%s] %s" % [where, message])
	_emit("error")


## 警告（不影响启动成功，但会进日志与诊断输出）。
static func warn(where: String, message: String) -> void:
	_warnings.append({"where": where, "message": message, "ms": Time.get_ticks_msec()})
	_trace("[警告] %s：%s" % [where, message])
	push_warning("[%s] %s" % [where, message])
	_emit("warn")


## 只记日志不报警（用于「正常但值得记录」的节点，例如插件跳过的目录）。
static func note(message: String) -> void:
	_trace(message)


static func active() -> bool:
	return _active


## 订阅启动事件：回调收到 progress() 快照，返回取消订阅的 Callable。
static func listen(callback: Callable) -> Callable:
	if not callback.is_valid():
		return func() -> void: pass
	_listeners.append(callback)
	return func() -> void:
		_listeners.erase(callback)


static func progress() -> Dictionary:
	return {
		"active": _active,
		"label": _label,
		"current": _current,
		"done": _done,
		"total": _total,
		"ratio": float(_done) / float(_total) if _total > 0 else -1.0,
		"errors": _errors.size(),
		"warnings": _warnings.size(),
		"elapsed_ms": (_finished_ms if _finished_ms > 0 else Time.get_ticks_msec()) - _started_ms,
	}


static func errors() -> Array[Dictionary]:
	return _errors.duplicate(true)


static func warnings() -> Array[Dictionary]:
	return _warnings.duplicate(true)


static func error_count() -> int:
	return _errors.size()


static func elapsed_ms() -> int:
	return (_finished_ms if _finished_ms > 0 else Time.get_ticks_msec()) - _started_ms


## 一行汇总，界面状态栏和诊断都用它。
static func summary() -> String:
	var seconds := float(elapsed_ms()) / 1000.0
	var head := "%s完成：%d 步 · %.2fs" % [_label, _done, seconds]
	if not _errors.is_empty():
		head += " · %d 个错误" % _errors.size()
	if not _warnings.is_empty():
		head += " · %d 个警告" % _warnings.size()
	return head


## 启动日志内容（也用于诊断命令与错误上报）。
static func log_text() -> String:
	return "\n".join(_lines)


static func log_path() -> String:
	return _written_path


## 测试/重启用：把状态清干净，不写日志。
static func reset() -> void:
	_active = false
	_label = "启动"
	_done = 0
	_total = 0
	_current = ""
	_steps.clear()
	_errors.clear()
	_warnings.clear()
	_lines = PackedStringArray()
	_listeners.clear()
	_started_ms = 0
	_finished_ms = 0


# ================= 内部 =================

static func _trace(line: String) -> void:
	if _lines.size() < MAX_LINES:
		_lines.append(line)


static func _emit(kind: String) -> void:
	if _listeners.is_empty():
		return
	var payload := progress()
	payload["kind"] = kind
	if (kind == "error" or kind == "warn") and not _errors.is_empty():
		var last: Dictionary = _errors[_errors.size() - 1] if kind == "error" else _warnings[_warnings.size() - 1]
		payload["where"] = String(last.get("where", ""))
		payload["message"] = String(last.get("message", ""))
	# 回调里可能会取消订阅，遍历副本。
	for callback in _listeners.duplicate():
		if callback.is_valid():
			callback.call(payload)


## 落盘。失败只警告一次，绝不让「写不了日志」影响启动。
## 便携版优先写 user://；某些运行环境限制用户目录写入时，退回 exe 旁边的
## logs/ —— 便携软件本来也该把日志放在自己能带走的地方。
static func _write_log() -> void:
	var targets: Array[String] = [LOG_PATH]
	var exe_dir := OS.get_executable_path().get_base_dir()
	if not exe_dir.is_empty():
		targets.append(exe_dir.path_join("logs").path_join("startup.log"))
	var file: FileAccess = null
	for target in targets:
		# DirAccess 的 *_absolute 系列不认 user:// 前缀，必须先换成真实路径，
		# 否则「建目录」静默失败，紧接着写文件也失败，日志就永远落不到 user://。
		var dir := ProjectSettings.globalize_path(String(target).get_base_dir())
		if not DirAccess.dir_exists_absolute(dir):
			DirAccess.make_dir_recursive_absolute(dir)
		file = FileAccess.open(String(target), FileAccess.WRITE)
		if file != null:
			_written_path = String(target)
			break
	if file == null:
		push_warning("FxBoot：启动日志写不了（%s）" % error_string(FileAccess.get_open_error()))
		return
	var stamp := Time.get_datetime_string_from_system(false, true)
	file.store_line("# 幻像工坊启动日志 %s" % stamp)
	file.store_line("# Godot %s · %s" % [Engine.get_version_info().get("string", "?"), OS.get_name()])
	file.store_line("")
	for line in _lines:
		file.store_line(line)
	file.close()
