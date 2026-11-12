class_name FxOpsMath
extends RefCounted
## 数值 / 逻辑算子：让循环索引、条件判断真正能驱动图像参数。
##
## 这些节点本身不产生图像，但它们决定了“蓝图能不能编程”：
## 索引 × 8 驱动位移、比较结果驱动分支、布尔组合驱动开关。

static func ops() -> Dictionary:
	return {
		&"math.number": func(ctx, node, d, inputs, params): return number_op(ctx, node, d, inputs, params),
		&"math.vec2": func(ctx, node, d, inputs, params): return vec2_op(ctx, node, d, inputs, params),
		&"logic.compare": func(ctx, node, d, inputs, params): return compare(ctx, node, d, inputs, params),
		&"logic.bool": func(ctx, node, d, inputs, params): return bool_op(ctx, node, d, inputs, params),
	}


static func number_op(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var a := FxPortType.as_number(inputs.get("a", params.get("a", 0.0)), 0.0)
	var b := FxPortType.as_number(inputs.get("b", params.get("b", 0.0)), 0.0)
	var op := String(params.get("op", "add"))
	match op:
		"subtract":
			return {"number": a - b}
		"multiply":
			return {"number": a * b}
		"divide":
			return {"number": a / b if absf(b) > 0.000001 else 0.0}
		"modulo":
			return {"number": fmod(a, b) if absf(b) > 0.000001 else 0.0}
		"min":
			return {"number": minf(a, b)}
		"max":
			return {"number": maxf(a, b)}
		"power":
			return {"number": pow(a, b)}
		"atan2":
			return {"number": atan2(a, b)}
		_:
			return {"number": a + b}


static func vec2_op(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var x := FxPortType.as_number(inputs.get("x", params.get("x", 0.0)), 0.0)
	var y := FxPortType.as_number(inputs.get("y", params.get("y", 0.0)), 0.0)
	return {"vec": Vector2(x, y)}


static func compare(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var a := FxPortType.as_number(inputs.get("a", params.get("a", 0.0)), 0.0)
	var b := FxPortType.as_number(inputs.get("b", params.get("b", 0.0)), 0.0)
	var tolerance := maxf(0.0, FxPortType.as_number(params.get("tolerance", 0.0001), 0.0001))
	var op := String(params.get("op", "greater"))
	var result := false
	match op:
		"greater_equal":
			result = a >= b - tolerance
		"less":
			result = a < b - tolerance
		"less_equal":
			result = a <= b + tolerance
		"equal":
			result = absf(a - b) <= tolerance
		"not_equal":
			result = absf(a - b) > tolerance
		_:
			result = a > b + tolerance
	return {"result": result}


static func bool_op(_ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var a := FxPortType.as_bool(inputs.get("a", params.get("a", false)), false)
	var b := FxPortType.as_bool(inputs.get("b", params.get("b", false)), false)
	var op := String(params.get("op", "and"))
	var result := false
	match op:
		"or":
			result = a or b
		"not":
			result = not a
		"xor":
			result = a != b
		"nand":
			result = not (a and b)
		_:
			result = a and b
	return {"result": result}
