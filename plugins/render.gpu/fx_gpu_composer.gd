class_name FxGpuComposer
extends RefCounted
## GPU 后处理门面：把整帧锐化交给 FxGpuCompute。
##
## 历史：这里曾经用 SubViewport + canvas 着色器，但 `get_texture().get_image()`
## 要等下一帧才拿到本次结果（`force_draw()` 只提交不等待），读回的是上一帧，
## 还可能被 sRGB 转换改过颜色。现在统一走 RenderingDevice 的 compute 通道：
## `buffer_get_data()` 自带同步栅栏，像素以 uint 原样进出，与 CPU 字节语义一致。
##
## 保留这个类名是为了让后端/设置的调用点稳定；它不再持有任何场景树节点。

static func available() -> bool:
	return FxGpuDevice.available()


## 整帧锐化。不可用 / 读回失败 / 强度为 0 时原样返回，调用方零分支。
static func compose(image: Image, sharpen: float) -> Image:
	if image == null or sharpen <= 0.001 or not available():
		return image
	var out := FxGpuCompute.sharpen(image, clampf(sharpen, 0.0, 2.0))
	return out if out != null else image


static func reset() -> void:
	FxGpuCompute.reset()
