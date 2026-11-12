class_name FxOpsCanvas
extends RefCounted
## 画布属性节点：把「画布宽 / 高 / 宽高比」变成图里可连线的数值。
##
## 画布是图文档的公开属性（meta.canvas），节点执行时由执行器写进 ctx.canvas；
## 这里只是把它读出来，不做任何缓存，改画布尺寸后下一帧就生效。


## 时间轴属性：帧率、时长、总帧数、当前时间、当前帧序号、播放进度。
## 时间轴是图文档的公开属性（meta.timeline），执行器每帧把它写进 ctx，
## 这里只是读出来 —— 所以「编辑器设置」和「节点读到的值」永远是同一份。
static func timeline_info(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var fps := maxf(1.0, ctx.fps)
	var duration := maxf(0.001, ctx.duration)
	var frames := maxf(1.0, round(duration * fps))
	var frame_index := clampf(floor(ctx.t * fps), 0.0, frames - 1.0)
	return {
		"fps": fps,
		"duration": duration,
		"frames": frames,
		"time": ctx.t,
		"frame": frame_index,
		"progress": clampf(ctx.t / duration, 0.0, 1.0),
		"seed": float(ctx.seed),
	}


static func canvas_info(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, _params: Dictionary) -> Dictionary:
	var width := maxi(1, ctx.canvas.x)
	var height := maxi(1, ctx.canvas.y)
	return {
		"width": float(width),
		"height": float(height),
		"aspect": float(width) / float(height),
	}
