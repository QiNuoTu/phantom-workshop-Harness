class_name FxOpsControl
extends RefCounted
## 控制流算子：分支、循环、序列、循环索引、图像累积。
##
## 这一层是整个蓝图“像编程”的地方，但执行器本身没有 if/for：
## 算子通过 ctx.follow(node_id, 出口端口) 推进执行流，执行器只负责把边接上。
## 因此新增控制结构不需要改执行器，只需要提供新的端口与算子。
##
## 约束：所有循环都有上限（params.max_iterations + ctx.max_loop_ticks），
## 坏图最多卡一帧，不会把编辑器冻死。

static func ops() -> Dictionary:
	return {
		&"flow.branch": func(ctx, node, d, inputs, params): return branch(ctx, node, d, inputs, params),
		&"flow.for": func(ctx, node, d, inputs, params): return for_loop(ctx, node, d, inputs, params),
		&"flow.sequence": func(ctx, node, d, inputs, params): return sequence(ctx, node, d, inputs, params),
		&"flow.index": func(ctx, node, d, inputs, params): return loop_index(ctx, node, d, inputs, params),
		&"image.accumulate": func(ctx, node, d, inputs, params): return accumulate(ctx, node, d, inputs, params),
	}


static func branch(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var condition := FxPortType.as_bool(
		inputs.get("condition", params.get("condition", true)),
		FxPortType.as_bool(params.get("condition", true), true)
	)
	ctx.follow(String(node.get("id", "")), "true" if condition else "false")
	return {}


static func for_loop(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var node_id := String(node.get("id", ""))
	var first := FxPortType.as_int(inputs.get("first", params.get("first", 0)), 0)
	var last := FxPortType.as_int(inputs.get("last", params.get("last", 7)), 7)
	var step := FxPortType.as_int(inputs.get("step", params.get("step", 1)), 1)
	if step == 0:
		step = 1
	var max_iterations := clampi(FxPortType.as_int(params.get("max_iterations", 4096), 4096), 1, 65536)
	var count := 0
	if step > 0 and last >= first:
		count = int(floor(float(last - first) / float(step))) + 1
	elif step < 0 and last <= first:
		count = int(floor(float(first - last) / float(-step))) + 1
	count = mini(count, max_iterations)

	var index := first
	var done := 0
	for n in range(count):
		if not ctx.loop_tick():
			break
		ctx.push_var("index", index)
		ctx.push_var("count", count)
		ctx.push_var("iteration", n)
		ctx.follow(node_id, "body")
		ctx.pop_var()
		ctx.pop_var()
		ctx.pop_var()
		index += step
		done += 1
	ctx.follow(node_id, "done")
	var last_index := first + step * maxi(0, done - 1)
	return {"last_index": last_index, "iterations": done}


static func sequence(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var node_id := String(node.get("id", ""))
	var steps := clampi(FxPortType.as_int(params.get("steps", 2), 2), 1, 8)
	for i in range(steps):
		ctx.follow(node_id, "then_%d" % i)
	return {}


static func loop_index(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, _params: Dictionary) -> Dictionary:
	return {
		"index": FxPortType.as_number(ctx.var_of("index", 0), 0.0),
		"count": FxPortType.as_number(ctx.var_of("count", 0), 0.0),
		"iteration": FxPortType.as_number(ctx.var_of("iteration", 0), 0.0),
	}


## 把每次循环产生的图叠进一张缓冲。状态存在 ctx.state（每次执行一份），
## 不是全局单例：同一张图可以被两个预览同时跑，互不污染。
static func accumulate(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var node_id := String(node.get("id", ""))
	var reset := FxPortType.as_bool(params.get("reset", false), false)
	var existing: Variant = ctx.state.get(node_id)
	var canvas: Image = existing if existing is Image else null
	if canvas == null or reset:
		canvas = FxImageUtil.new_canvas(ctx.canvas)
		ctx.state[node_id] = canvas
	var image: Variant = inputs.get("image")
	if image is Image:
		var mode := FxPortType.as_string(params.get("mode", "normal"), "normal")
		var opacity := clampf(FxPortType.as_number(params.get("opacity", 1.0), 1.0), 0.0, 1.0)
		FxImageUtil.blend_image(canvas, image as Image, Vector2.ZERO, mode, opacity)
	return {"image": canvas}
