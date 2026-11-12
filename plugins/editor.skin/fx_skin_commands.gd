class_name FxSkinCommands
extends RefCounted
## 皮肤/窗口命令的静态入口。命令处理器必须是静态 Callable（插件契约）。


static func cycle(ctx: Dictionary) -> void:
	var shell: FxShell = ctx.get("shell") as FxShell
	if shell != null:
		shell.cycle_skin()


static func toggle_bottom(ctx: Dictionary) -> void:
	var shell: FxShell = ctx.get("shell") as FxShell
	if shell != null:
		shell.toggle_area("bottom")
