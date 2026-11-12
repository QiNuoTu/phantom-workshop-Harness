class_name FxGpuDevice
extends RefCounted
## GPU 设备探测：这台机器有没有可用的图形设备、叫什么、什么接口。
##
## 只是「问一句」，不建任何 GPU 资源 —— 后端、设置面板、诊断命令都靠它决策。
## 无头模式（CI / --headless）下一律视为不可用：那里用的是 dummy 驱动，
## 建纹理只会拿到空图，宁可提前说清楚，也不要让画面莫名变黑。

static var _cached: Dictionary = {}
static var _probed: bool = false


static func refresh() -> void:
	_probed = false
	_cached = {}


static func info() -> Dictionary:
	if _probed:
		return _cached
	_probed = true
	var headless := DisplayServer.get_name() == "headless"
	var adapter := ""
	var vendor := ""
	var api := ""
	var device_ready := false
	if not headless:
		# 这三条在无头/dummy 驱动下会返回空串，不需要额外判断。
		adapter = String(RenderingServer.get_video_adapter_name())
		vendor = String(RenderingServer.get_video_adapter_vendor())
		api = String(RenderingServer.get_video_adapter_api_version())
		device_ready = RenderingServer.get_rendering_device() != null
	var available := not headless and device_ready and not adapter.is_empty()
	_cached = {
		"available": available,
		"headless": headless,
		"name": adapter,
		"vendor": vendor,
		"api_version": api,
		"rendering_device": device_ready,
		"driver": RenderingServer.get_video_adapter_name() if not headless else "",
	}
	return _cached


static func available() -> bool:
	return bool(info().get("available", false))


## 给状态栏/统计用的一句话。
static func state_text() -> String:
	var data := info()
	if bool(data.get("available", false)):
		return "GPU：%s" % String(data.get("name", ""))
	if bool(data.get("headless", false)):
		return "GPU：无头模式，未启用"
	return "GPU：不可用（回落到 CPU 求值）"


## 诊断命令用：把探测结果逐行打印出来。
static func describe() -> String:
	var data := info()
	var lines: Array[String] = []
	lines.append("== GPU 渲染服务器 · 设备 ==")
	lines.append("可用：%s" % ("是" if bool(data.get("available", false)) else "否"))
	lines.append("适配器：%s" % String(data.get("name", "（空）")))
	lines.append("厂商：%s" % String(data.get("vendor", "（空）")))
	lines.append("接口版本：%s" % String(data.get("api_version", "（空）")))
	lines.append("RenderingDevice：%s" % ("就绪" if bool(data.get("rendering_device", false)) else "不可用"))
	lines.append("无头模式：%s" % ("是" if bool(data.get("headless", false)) else "否"))
	return "\n".join(lines)
