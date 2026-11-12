class_name FxSettingsApi
extends RefCounted
## 设置中心的静态入口：插件只贡献 Callable，实例不会被注册表长期持有。

static func make_panel(ctx: Dictionary) -> Control:
	var panel := FxSettingsPanel.new()
	panel.setup(ctx.get("shell"))
	return panel


static func open(ctx: Dictionary) -> void:
	var shell: Variant = ctx.get("shell")
	if shell != null and shell is Object and (shell as Object).has_method("open_window"):
		(shell as Object).call("open_window", "settings.window")


static func write(id: String, value: Variant) -> void:
	FxSettings.set_value(id, value)


static func set_preset(ctx: Dictionary) -> void:
	var args: Array = ctx.get("args", [])
	var name := str(args[0]) if not args.is_empty() else "balanced"
	FxSettings.set_value("quality.preset", name)
