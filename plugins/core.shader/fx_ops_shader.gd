class_name FxOpsShader
extends RefCounted
## 着色器算子：`shader.image`。
##
## 代码来源优先级：节点参数 `code`（内联） > `path` 指向的 `.gdshader` > 内置直通。
## 输入图绑到着色器的第一个 sampler2D；没有连线时给一张空画布，所以
## 「纯生成式着色器」也能单独成图。

static func ops() -> Dictionary:
	return {
		&"shader.image": func(ctx, node, d, inputs, params): return run(ctx, node, d, inputs, params),
	}


static func run(ctx: FxEvalContext, _node: Dictionary, _def: FxNodeDef,
		inputs: Dictionary, params: Dictionary) -> Dictionary:
	var source: Image = null
	var incoming: Variant = inputs.get("image")
	if incoming is Image:
		source = incoming
	var code := resolve_code(params)
	var on := bool(params.get("enabled", true)) \
		and bool(FxSettings.typed_value("shader.enabled", true))
	if not on or code.strip_edges().is_empty():
		return {"image": source.duplicate() if source != null else FxImageUtil.new_canvas(ctx.canvas)}
	# 画布尺寸以图设置为准；源图更大时不裁切，交给着色器自己按 UV 采样。
	var canvas := ctx.canvas
	if source != null and (source.get_width() > canvas.x or source.get_height() > canvas.y):
		canvas = source.get_size()
	var overrides := parse_uniforms(String(params.get("uniforms", "")))
	var frame := int(round(ctx.t * maxf(ctx.fps, 0.0001)))
	var image := FxShaderRuntime.render_bridged(code, source, canvas, overrides, ctx.t, frame)
	return {"image": image}


## 代码从哪来：内联 > 文件 > 直通模板。
static func resolve_code(params: Dictionary) -> String:
	var inline := String(params.get("code", "")).strip_edges()
	if not inline.is_empty():
		return inline
	var path := String(params.get("path", "")).strip_edges()
	if path.is_empty():
		return FxShaderRuntime.DEFAULT_CODE
	if not FileAccess.file_exists(path):
		return ""
	var text := FileAccess.get_file_as_string(path)
	return text if not text.is_empty() else ""


## uniform 覆盖值的解析：支持整段 JSON，也支持「名称 = 值」逐行写。
##
##   {"strength": 0.6, "tint": "#ff8800"}
##   strength = 0.6
##   tint: #ff8800
##
## 值先按 JSON 解析（数字 / 布尔 / 数组 / 颜色字符串），解析不了就当字符串。
static func parse_uniforms(text: String) -> Dictionary:
	var out: Dictionary = {}
	var body := text.strip_edges()
	if body.is_empty():
		return out
	if body.begins_with("{"):
		var parsed: Variant = JSON.parse_string(body)
		if parsed is Dictionary:
			return (parsed as Dictionary).duplicate(true)
	for raw in body.split("\n", false):
		var line := String(raw).strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("//"):
			continue
		var cut := line.find("=")
		if cut < 0:
			cut = line.find(":")
		if cut <= 0:
			continue
		var key := line.substr(0, cut).strip_edges()
		var value := line.substr(cut + 1).strip_edges()
		if key.is_empty():
			continue
		out[key] = _literal(value)
	return out


static func _literal(text: String) -> Variant:
	var value := text.strip_edges()
	if value.is_empty():
		return ""
	var parsed: Variant = JSON.parse_string(value)
	if parsed != null:
		return parsed
	# JSON 不认十六进制颜色，这里单独放行；其余按原字符串交给运行时按类型转。
	return value
