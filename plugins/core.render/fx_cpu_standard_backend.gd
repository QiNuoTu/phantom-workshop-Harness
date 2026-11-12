class_name FxCpuStandardBackend
extends FxRenderBackend
## 标准 CPU 后端：每一帧都完整走 FxGraphRunner 的拉取式求值。
## 这是默认实现，也是其它后端失效时的回落目标。

static func create() -> FxRenderBackend:
	return FxCpuStandardBackend.new()


## 纯 GDScript + Image 运算，不碰场景树：可以安全地在工作线程里求帧。
func thread_safe() -> bool:
	return true


func _init() -> void:
	id = "cpu.standard"
	label = "标准 CPU 逐像素"


func frame(doc: Dictionary, t: float, _policy: Dictionary,
		runner: RefCounted, _ctx: Dictionary) -> Dictionary:
	if runner == null:
		return {}
	# 签名由编排层给出（文档修订号），执行器据此跳过每帧的整文档 hash。
	var result: Variant = runner.call("run", doc, t, int(_ctx.get("signature", -1)))
	return result if result is Dictionary else {}
