class_name FxGpuBackend
extends FxRenderBackend
## GPU 渲染服务器。
##
## 线程模型（这一步是「预览不卡」的关键）：
##   · `frame()` 只做 CPU 图求值，**声明 thread_safe() = true**，因此界面求帧与
##     后台预渲染都跑在工作线程，不会把几百毫秒的逐像素运算压到 UI 线程上；
##   · 真正需要渲染线程的 GPU compute（整帧锐化 / 增强）放到 `postprocess()`，
##     由服务在**发布前的主线程**调用一次，只花几毫秒；
##   · GPU 算子（`FxGpuOps` 的 blur / mix）在工作线程里会自动回落 CPU 实现，
##     结果一致；暂停时的主线程单帧路径仍会命中 GPU 加速。
##
## 于是 GPU 后端既能参与预览（缓存帧与实时帧都过一遍 GPU 通道），
## 又不会像早期版本那样「一切到 GPU 就把整条求值链拉回主线程」。

var _cpu := FxCpuStandardBackend.new()


static func create() -> FxRenderBackend:
	return FxGpuBackend.new()


func _init() -> void:
	id = "gpu.standard"
	label = "GPU 渲染服务器"


func describe() -> String:
	return "%s · %s" % [label, FxGpuDevice.state_text()]


## 求帧本体是纯 CPU 数据流，可在任意线程跑。GPU 资源只在 postprocess 里碰。
func thread_safe() -> bool:
	return true


func frame(doc: Dictionary, t: float, policy: Dictionary,
		runner: RefCounted, ctx: Dictionary) -> Dictionary:
	var result: Dictionary = _cpu.frame(doc, t, policy, runner, ctx)
	if result.is_empty():
		return result
	var stats: Dictionary = result.get("stats", {})
	stats["gpu"] = FxGpuDevice.state_text()
	stats["gpu_used"] = false
	stats["backend"] = id
	result["stats"] = stats
	return result


## 主线程发布通道：对最终图做一次 GPU compute 锐化。
## 设备不可用 / 未开锐化 / 读回失败时原样返回，绝不黑屏。
func postprocess(image: Image, _ctx: Dictionary) -> Image:
	if image == null or image.is_empty():
		return image
	var sharpen := float(FxSettings.typed_value("render.gpu_sharpen", 0.0))
	if sharpen <= 0.001 or not FxGpuComposer.available():
		return image
	var composed := FxGpuComposer.compose(image, sharpen)
	if composed == null or composed.is_empty():
		return image
	return composed


func invalidate() -> void:
	_cpu.invalidate()
	FxGpuComposer.reset()


## 设置面板 / 菜单的「检测 GPU」按钮：把探测结果打到状态栏。
static func log_info(ctx: Dictionary) -> void:
	print(FxGpuDevice.describe())
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("status"):
		shell.call("status", FxGpuDevice.state_text())


static func cmd_info(ctx: Dictionary) -> void:
	log_info(ctx)
