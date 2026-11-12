class_name FxRenderApi
extends RefCounted
## 渲染服务的静态工厂。外壳拿到的是 services["render"]，不 new 具体类。
##
## 另外两个用途：
##   · 设置面板 / 命令表里的「按钮型」入口需要一个**无参数**的 Callable，
##     这里用当前服务指针把它们转给真正的实例方法；
##   · 渲染相关的能力键回调（切后端）也放这里，保持「插件不认识外壳」的边界。

static var _current: FxRenderService = null


static func create(_ctx: Dictionary) -> FxRenderService:
	var service := FxRenderService.new()
	_current = service
	return service


## 服务实例被换掉/销毁时清指针，避免拿着已释放的节点。
static func unbind(service: FxRenderService) -> void:
	if _current == service:
		_current = null


static func service() -> FxRenderService:
	return _current


static func invalidate_backend(_value: Variant) -> void:
	FxRenderBroker.invalidate()
	# 算子实现可能随后端切换（GPU 算子覆盖）；执行器的跨帧静态缓存必须作废，
	# 否则上一后端算出的图会被当成这一后端的结果复用。
	if _current != null:
		_current.invalidate()


# ================= 帧缓存入口（设置按钮 / 命令） =================

## 清理全部帧缓存。返回释放的字节数（没有服务时返回 0）。
static func clear_cache() -> int:
	if _current == null:
		return 0
	return _current.clear_cache()


static func cmd_clear_cache(ctx: Dictionary) -> void:
	var freed := clear_cache()
	var text := "已清理帧缓存"
	if freed > 0:
		text += " · 释放 %s" % _format_bytes(freed)
	_push_status(ctx, text)


static func cmd_prefetch(ctx: Dictionary) -> void:
	if _current == null:
		_push_status(ctx, "渲染服务还没就绪")
		return
	if _current.start_prefetch():
		_push_status(ctx, "开始预渲染整段动画（后台线程）")
	else:
		_push_status(ctx, "当前无法预渲染：播放中、后端不支持线程，或图里有 GPU 节点")


static func _push_status(ctx: Dictionary, text: String) -> void:
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("status"):
		shell.call("status", text)


static func _format_bytes(value: int) -> String:
	if value >= 1024 * 1024:
		return "%.1f MB" % (float(value) / (1024.0 * 1024.0))
	if value >= 1024:
		return "%.1f KB" % (float(value) / 1024.0)
	return "%d B" % value
