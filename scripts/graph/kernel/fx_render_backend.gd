class_name FxRenderBackend
extends RefCounted
## 渲染后端契约（论文 §6.2 服务代理的 provider 接口）。
##
## 渲染服务（编排层）负责「什么时候画、画完发给谁」；后端负责「怎么求一帧」。
## 两者之间只通过这个类通信：默认实现什么都不做，第三方插件贡献一个实现
## 就等于换掉整个渲染器（CPU 逐像素、缓存复用、未来的 GPU / 远程渲染皆可），
## 不需要改 FxRenderService，也不需要重启工作台。
##
## runner 是解释器提供的执行器，以 RefCounted 传入、用 call("run", ...) 调用，
## 因此这个契约本身不依赖 FxGraphRunner 或任何具体图解释器。

var id: String = "null"
var label: String = "无渲染后端"


func describe() -> String:
	return label


## ctx 至少含 {playing: bool, exact: bool}；policy 是 FxQualityPolicy 的结果。
## 返回 {image: Image, stats: Dictionary, previews: Dictionary}。
func frame(_doc: Dictionary, _t: float, _policy: Dictionary,
		_runner: RefCounted, _ctx: Dictionary) -> Dictionary:
	return {}


## 能否在工作线程里求帧。默认 false：插件后端可能碰场景树 / 全局状态，
## 只有明确声明过的后端才会被放到后台线程（界面对它们仍走主线程同步求帧）。
func thread_safe() -> bool:
	return false


## 发布前的主线程后处理钩子。
##
## 求帧可以完全跑在工作线程，但有些硬件资源（RenderingDevice compute / 纹理）
## 只能由渲染线程碰。后端把这类「几毫秒、只改最终像素」的活放到这里，
## 服务会在把 Image 交给界面之前调用一次 —— 播放命中帧缓存时也会调用。
## 默认原样返回；实现方必须保证同步、不抛异常，失败就返回输入图。
func postprocess(image: Image, _ctx: Dictionary) -> Image:
	return image


## 后端切换 / 文档结构变化时调用，清掉内部缓存。
func invalidate() -> void:
	pass
