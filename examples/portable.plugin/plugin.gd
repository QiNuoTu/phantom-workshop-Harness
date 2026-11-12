extends FxPlugin
## 外部插件模板：不进 PCK，直接在 <exe>/plugins/ 或 user://plugins/ 下现场编译。
##
## 外部插件允许绑定实例的 Callable（宿主把实例留在 FxRegistry.runtime_plugins
## 保活到 shutdown），所以命令/服务可以直接用实例方法。

func menus() -> Array[Dictionary]:
	return [{"id": "my", "title": "我的插件", "order": 90}]


func menu_items() -> Array[Dictionary]:
	return [{"menu": "my", "label": "打招呼", "command": "my.hello", "order": 10}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "my.hello", "label": "打招呼", "shortcut": "Ctrl+H",
		"handler": Callable(self, "hello"),
	}]


func toolbar() -> Array[Dictionary]:
	return [{"label": "打招呼", "command": "my.hello", "order": 900}]


func hello(ctx: Dictionary) -> void:
	var shell: FxShell = ctx.get("shell")
	if shell != null:
		shell.status("你好，来自外部插件")
	print("[my.portable] hello")
