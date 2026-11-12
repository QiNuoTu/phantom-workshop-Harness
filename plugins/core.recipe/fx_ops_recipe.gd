class_name FxOpsRecipe
extends RefCounted
## 把旧 VfxEngine 的配方（JSON）接成图像流里的一个节点：image.recipe。
##
## 复用点：
##   · 配方自带 width/height/duration/fps/loop/seed/palette/layers/post，
##     VfxEngine.configure 已经做了全部钳制与图层缩放；
##   · 输出是普通 Image，下游完全不感知它是“配方”；
##   · 配方渲染与输出链一样不降采样：播放时半分辨率再双线性放大会明显发糊，
##     且 VfxEngine 实例按节点缓存，跨帧复用已经足够快；
##   · 引擎实例按节点缓存，配方文本/种子变化才重建。

const CACHE_LIMIT := 24

static var _cache: Dictionary = {}


static func apply(ctx: FxEvalContext, node: Dictionary, _def: FxNodeDef,
		_inputs: Dictionary, params: Dictionary) -> Dictionary:
	var text := FxPortType.as_string(params.get("recipe", ""), "").strip_edges()
	if text.is_empty():
		# 新拖出来的节点先给一个能看的默认效果；点“编辑”可换成任意配方。
		text = FxRecipePresets.default_recipe()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		ctx.warn("配方 JSON 解析失败：%s" % String(node.get("id", "")))
		return {"image": FxImageUtil.new_canvas(ctx.canvas)}
	var recipe: Dictionary = (parsed as Dictionary).duplicate(true)
	var seed_override := FxPortType.as_int(params.get("seed", 0), 0)
	if seed_override > 0:
		recipe["seed"] = seed_override
	var base_size := Vector2i(
		maxi(16, FxPortType.as_int(recipe.get("width", ctx.canvas.x), ctx.canvas.x)),
		maxi(16, FxPortType.as_int(recipe.get("height", ctx.canvas.y), ctx.canvas.y))
	)
	var render_scale := 1.0
	var node_id := String(node.get("id", ""))
	var sig := hash(text) ^ (seed_override * 7919) ^ int(render_scale * 1000.0)
	var entry: Dictionary = _cache.get(node_id, {})
	if entry.is_empty() or int(entry.get("sig", 0)) != sig:
		var engine := VfxEngine.new()
		engine.configure(recipe, _collect_assets(ctx, recipe))
		entry = {
			"sig": sig,
			"engine": engine,
			"scale": render_scale,
			"base_size": base_size,
		}
		_cache[node_id] = entry
		_trim_cache()
	var engine: VfxEngine = entry["engine"]
	var time_offset := FxPortType.as_number(params.get("time_offset", 0.0), 0.0)
	var image := engine.render(ctx.t + time_offset)
	if render_scale != 1.0 and image.get_size() != base_size:
		image.resize(base_size.x, base_size.y, Image.INTERPOLATE_BILINEAR)
	var fit := FxPortType.as_string(params.get("fit", "contain"), "contain")
	return {"image": FxImageUtil.fit_image(image, ctx.canvas, fit)}


## 配方里的 asset 键：先当 pixelfx 素材 id，再当普通图片路径。
static func _collect_assets(ctx: FxEvalContext, recipe: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	_collect_from_layers(ctx, recipe.get("layers", []), out)
	return out


static func _collect_from_layers(ctx: FxEvalContext, layers: Variant, out: Dictionary) -> void:
	if not layers is Array:
		return
	for item in layers:
		if not item is Dictionary:
			continue
		var layer: Dictionary = item
		var key := String(layer.get("asset", ""))
		if not key.is_empty() and not out.has(key):
			out[key] = _load_asset(ctx, key)
		if layer.get("child") is Dictionary:
			_collect_from_layers(ctx, [layer["child"]], out)


static func _load_asset(ctx: FxEvalContext, key: String) -> Image:
	if FxAssetLibrary.has(key):
		return FxAssetLibrary.frame_image(key, 0, true)
	return ctx.load_image(key)


static func _trim_cache() -> void:
	if _cache.size() <= CACHE_LIMIT:
		return
	# 简单策略：清空即可，配方节点通常只有个位数。
	_cache.clear()
