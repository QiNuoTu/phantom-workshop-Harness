class_name FxUiKit
extends RefCounted
## 视觉门面（稳定 API，不含具体实现）。
##
## 所有插件继续用 `FxUiKit.label(...)` / `FxUiKit.MUTED`，
## 真正的颜色、主题、控件工厂来自 `current: FxSkin`。
## 基座自带一个最小默认皮肤，保证删光插件也能启动；
## 插件通过 skins() 贡献皮肤，FxShell 选中后调用 use() 切换。
##
## 这样「统一视觉」不再是基座的硬编码，而是一等可替换贡献。

const AUTO_COLOR := Color(-1.0, -1.0, -1.0, -1.0)

static var current: FxSkin = FxSkin.new()

static var BG: Color = Color("#1f2124")
static var PANEL: Color = Color("#25272b")
static var PANEL_ALT: Color = Color("#2a2d32")
static var BAR: Color = Color("#232528")
static var BORDER: Color = Color("#3a3d42")
static var BORDER_SOFT: Color = Color("#2f3237")
static var TEXT: Color = Color("#d4d7dc")
static var TEXT_STRONG: Color = Color("#f2f4f7")
static var MUTED: Color = Color("#8d939c")
static var ACCENT: Color = Color("#3d8bfd")
static var ACCENT_COOL: Color = Color("#56b6ff")
static var DANGER: Color = Color("#e5534b")
static var OK: Color = Color("#3fb950")


## 切换皮肤并同步静态颜色 token。调用方（FxShell）随后重建 UI，
## 让已存在的控件也用上新颜色。
static func use(skin: FxSkin) -> void:
	if skin == null:
		return
	current = skin
	var c := skin.colors()
	BG = c.get("BG", BG)
	PANEL = c.get("PANEL", PANEL)
	PANEL_ALT = c.get("PANEL_ALT", PANEL_ALT)
	BAR = c.get("BAR", BAR)
	BORDER = c.get("BORDER", BORDER)
	BORDER_SOFT = c.get("BORDER_SOFT", BORDER_SOFT)
	TEXT = c.get("TEXT", TEXT)
	TEXT_STRONG = c.get("TEXT_STRONG", TEXT_STRONG)
	MUTED = c.get("MUTED", MUTED)
	ACCENT = c.get("ACCENT", ACCENT)
	ACCENT_COOL = c.get("ACCENT_COOL", ACCENT_COOL)
	DANGER = c.get("DANGER", DANGER)
	OK = c.get("OK", OK)


static func skin() -> FxSkin:
	return current


## 皮肤 apply_options() 改过 token 后重新同步颜色，不必重建实例。
static func refresh() -> void:
	use(current)


static func label(text: String, font_size: int = 12, color: Color = AUTO_COLOR) -> Label:
	return current.label(text, font_size, current.muted if color.a < 0.0 else color)


static func strong(text: String, font_size: int = 13) -> Label:
	return current.strong(text, font_size)


static func wrapped(text: String, font_size: int = 11, color: Color = AUTO_COLOR) -> Label:
	return current.wrapped(text, font_size, current.muted if color.a < 0.0 else color)


static func button(text: String, font_size: int = 12, height: float = 26.0) -> Button:
	return current.button(text, font_size, height)


static func flat_button(text: String, tooltip: String = "", font_size: int = 11) -> Button:
	return current.flat_button(text, tooltip, font_size)


static func hsep(expand: bool = false) -> Control:
	return current.hsep(expand)


static func spacer(width: float = 0.0, expand: bool = false) -> Control:
	return current.spacer(width, expand)


static func panel_style(bg: Color, border: Color, radius: int = -1) -> StyleBoxFlat:
	return current.panel_style(bg, border, radius)


static func solid_panel_style(bg: Color, border: Color, radius: int = -1) -> StyleBoxFlat:
	return current.solid_panel_style(bg, border, radius)


static func window_style(bg: Color, border: Color, radius: int = -1) -> StyleBoxFlat:
	return current.window_style(bg, border, radius)


static func tab_style(active: bool, hover: bool = false) -> StyleBoxFlat:
	return current.tab_style(active, hover)


static func chrome_style(kind: String) -> StyleBox:
	return current.chrome_style(kind)


static func build_theme() -> Theme:
	return current.build_theme()


## 独立 Window / Dialog 不继承 Control 的 theme，创建后必须显式套一层，
## 否则插件的弹出面板永远是 Godot 默认灰。
##
## 顺带把对话框配置成「一次性」形态（见 one_shot）：这一步不能被绕过，
## 否则关窗口时会踩到引擎的 subwindow 焦点索引缺陷。
static func style_window(window: Window) -> void:
	if window == null:
		return
	window.theme = build_theme()
	detachable(window)
	if window is AcceptDialog:
		one_shot(window as AcceptDialog)


## 让一个 Window 以「独立系统窗口」形态出现。
##
## 内嵌子窗口（Godot 默认）有两个硬伤：标题栏只是面板底色上的一行字（看上去像
## 「标题透明」），而且不能拖出主窗口。改成原生窗口后标题栏由系统绘制，窗口可以
## 拖到任意屏幕、进任务栏、单独缩放 —— 也就是「窗口能分离出去」。
##
## 必须在窗口**显示之前**调用（`force_native` 在显示期间不可改）。无头环境没有
## 原生窗口，自动保持内嵌。用户可在设置里关掉（`ui.native_windows`）。
static func detachable(window: Window) -> void:
	if window == null or not is_instance_valid(window):
		return
	var want := native_windows() and DisplayServer.get_name() != "headless"
	if window.force_native == want:
		return
	if window.visible:
		# 已经显示：等它关掉之后再切，不要在半路改（引擎会直接报错）。
		return
	window.force_native = want


## 弹窗是否默认作为独立系统窗口打开。
static func native_windows() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return bool(FxSettings.typed_value("ui.native_windows", true))


## 关掉一个正在显示的窗口：**只销毁，不要 hide()**。
##
## hide() / visible = false 会让引擎在把焦点还给父窗口时用错索引，
## 报 `_sub_window_grab_focus: index == -1`（viewport.cpp:440）——
## 窗口的可见状态已经退回，但它还没从父 viewport 的 subwindow 列表里摘掉。
## queue_free() 走销毁路径，不经过那段焦点恢复，实测干净。
static func dismiss(window: Window) -> void:
	if window == null or not is_instance_valid(window):
		return
	window.queue_free()


## 把 AcceptDialog 配置成「一次性」：确定、取消、Esc、右上角关闭
## 都直接销毁对话框，绝不经过 AcceptDialog 内部的 hide()。
##
## 语义不变（我们的弹窗本来就只弹一次），但绕开了引擎的坏路径。
## 重复调用是安全的。
static func one_shot(dialog: AcceptDialog) -> void:
	if dialog == null or not is_instance_valid(dialog):
		return
	if dialog.has_meta("fx_one_shot"):
		return
	dialog.set_meta("fx_one_shot", true)
	# 确定键默认会自己 hide()，先关掉，改成「信号 → 销毁」。
	dialog.dialog_hide_on_ok = false
	# Esc 默认也走 hide()，同样关掉，下面用 window_input 自己接。
	dialog.dialog_close_on_escape = false
	# 文件对话框能走系统原生面板就走原生：它不是内嵌子窗口，
	# 取消/选择都不会经过 subwindow 焦点恢复，顺带是用户熟悉的系统界面。
	if dialog is FileDialog and native_file_dialogs():
		(dialog as FileDialog).use_native_dialog = true
	dialog.confirmed.connect(func() -> void:
		if is_instance_valid(dialog) and not bool(dialog.get_meta("fx_keep_open", false)):
			dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void:
		if is_instance_valid(dialog):
			dialog.queue_free()
	)
	# 右上角关闭：语义等同取消（调用方可能在 canceled 上挂了清理逻辑）。
	dialog.close_requested.connect(func() -> void:
		if is_instance_valid(dialog):
			dialog.canceled.emit()
	)
	dialog.window_input.connect(func(event: InputEvent) -> void:
		if not is_instance_valid(dialog) or not dialog.visible:
			return
		if event.is_action_pressed("ui_cancel"):
			dialog.get_viewport().set_input_as_handled()
			dialog.canceled.emit()
	)


## 文件对话框是否用系统原生面板。
##
## 平台不支持原生时自动回落内嵌面板（无头环境、部分 Linux 桌面）。
## 用户可以在设置里关掉（`ui.native_file_dialog`）。
static func native_file_dialogs() -> bool:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		return false
	return bool(FxSettings.typed_value("ui.native_file_dialog", true))



## 安全地弹出内嵌 Window。
##
## 内嵌 Window 的统一弹出入口。
##
## `_sub_window_grab_focus: index == -1` 的根因是：Window 刚 add_child 时父 viewport
## 还没把它登记进 subwindows 列表，而 popup*() 内部会立刻抢焦点。这里等两帧再弹：
## 第一帧让父 viewport 完成登记，第二帧确保登记已生效 —— 只等一帧在某些窗口层级
## （例如窗口挂在刚重建的面板里、或平台把原生窗口降级为内嵌）下仍会抢跑。
##
## 调用方永远不要直接 popup*()，否则这个时序保证就断了。
static func popup_later(window: Window, method: String = "popup_centered",
		args: Array = []) -> void:
	if window == null or not is_instance_valid(window):
		return
	if not window.is_inside_tree():
		await window.tree_entered
	if not is_instance_valid(window) or window.get_tree() == null:
		return
	await window.get_tree().process_frame
	if not is_instance_valid(window) or window.get_tree() == null:
		return
	await window.get_tree().process_frame
	if not is_instance_valid(window):
		return
	window.callv(method, args)


## 等几帧再执行一个动作，不依赖任何节点。
##
## 用于「先关掉一个内嵌窗口，再打开下一个」：hide()/queue_free() 只是排队，
## viewport 要到本帧末尾才把那个 subwindow 从列表里摘掉；同一帧里接着 popup
## 下一个窗口，索引就会在摘除/登记之间错位（`_sub_window_grab_focus: index == -1`）。
static func defer(action: Callable, frames: int = 2) -> void:
	if not action.is_valid():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		action.call()
		return
	for _i in maxi(frames, 1):
		await tree.process_frame
	action.call()


## 安全抢焦点：Control 可能位于一个刚显示的内嵌 Window 里，那个 Window 在
## viewport 登记完成前 grab_focus 会报 index == -1。等窗口可见 + 一帧再抢。
static func focus_later(control: Control) -> void:
	if control == null or not is_instance_valid(control):
		return
	if not control.is_inside_tree():
		await control.tree_entered
	if not is_instance_valid(control) or control.get_tree() == null:
		return
	var tree := control.get_tree()
	var host := control.get_window()
	# 宿主是内嵌子窗口且还没显示：等它显示完（显示那一刻才会登记 subwindow）。
	if host != null and host != tree.root and not host.visible:
		await host.visibility_changed
		if not is_instance_valid(control):
			return
		await tree.process_frame
	if not is_instance_valid(control) or not control.is_inside_tree():
		return
	if control.is_visible_in_tree():
		control.grab_focus()
