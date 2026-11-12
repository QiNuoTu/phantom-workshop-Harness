class_name FxPluginManager
extends RefCounted
## 插件维护动作：重新扫描插件 / 打开用户插件目录。
##
## 浏览、启停、依赖诊断与每个插件自己的设置都统一在插件中心（editor.plugin-hub），
## 这里不再重复一套列表界面 —— 只保留无法在账本里表达的「系统动作」：
## 重新读盘、打开目录（论文 §6.1：这是不可回收的 emission）。

static func cmd_rescan(ctx: Dictionary) -> void:
	var shell: Variant = ctx.get("shell")
	if shell != null and shell is Object and (shell as Object).has_method("reload_plugins"):
		(shell as Object).call("reload_plugins")


static func cmd_open_user_dir(_ctx: Dictionary) -> void:
	FxPluginHost.ensure_user_root()
	OS.shell_open(ProjectSettings.globalize_path("user://plugins"))
