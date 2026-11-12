class_name FxPluginHubApi
extends RefCounted
## 插件中心的静态入口与「面板功能注入」示例。
## 所有 Callable 都是静态的，宿主停用插件时能被 FxEffectScope 干净撤回。

const PRESETS: Array[String] = ["none", "balanced", "performance", "fidelity"]


static func make_panel(ctx: Dictionary) -> Control:
	var panel := FxPluginHub.new()
	panel.setup(ctx.get("shell"))
	return panel


static func open(ctx: Dictionary) -> void:
	var shell: Variant = ctx.get("shell")
	if shell != null and shell is Object and (shell as Object).has_method("open_window"):
		(shell as Object).call("open_window", "plugin.hub.window")


## 面板标题菜单里点「分离此面板」：command 的 args[0] 是面板 id。
static func detach_panel(ctx: Dictionary) -> void:
	var args: Array = ctx.get("args", [])
	if args.is_empty():
		return
	var shell: Variant = ctx.get("shell")
	if shell != null and shell is Object and (shell as Object).has_method("detach_panel"):
		(shell as Object).call("detach_panel", str(args[0]))


## 面板标题菜单里点「分离为独立窗口」：用真正的 OS 窗口承载同一个面板实例。
static func detach_panel_native(ctx: Dictionary) -> void:
	var args: Array = ctx.get("args", [])
	if args.is_empty():
		return
	var shell: Variant = ctx.get("shell")
	if shell != null and shell is Object and (shell as Object).has_method("detach_panel"):
		(shell as Object).call("detach_panel", str(args[0]), true)


static func cycle_preset(_ctx: Dictionary) -> void:
	var current := String(FxSettings.value("quality.preset"))
	var index := PRESETS.find(current)
	FxSettings.set_value("quality.preset", PRESETS[(index + 1) % PRESETS.size()])
