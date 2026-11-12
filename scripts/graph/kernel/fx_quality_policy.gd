class_name FxQualityPolicy
extends RefCounted
## 渲染/算子质量策略的多路代理。
##
## 基座只给出「保守默认值」，真正的策略来自插件贡献的 provider：
##   (ctx: Dictionary, current: Dictionary) -> Dictionary（局部覆盖）
## ctx = {playing, width, height, node_count, t}。多个 provider 按 order 合并，
## 因此插件可以只覆盖自己关心的那一项（比如只把播放档的模糊半径调小），
## 不用复制整份策略，也不需要外壳认识任何新字段（§6.2）。
##
## 硬约束：output_downscale 恒为 false —— 输出链永不降采样，插件不能覆盖它。
## 这是「时间可组合性」里的不变量：预览与导出必须逐像素一致。

const DEFAULTS := {
	"quality": 1,
	"operator_quality": 1.0,
	"preview_limit": 128,
	"capture_previews": true,
	"preview_scope": "all",
	"static_cache": true,
	"adaptive_throttle": true,
	"throttle_factor": 0.0006,
	"max_blur_radius": 32,
	"output_downscale": false,
}


static func defaults() -> Dictionary:
	return DEFAULTS.duplicate(true)


static func resolve(ctx: Dictionary) -> Dictionary:
	var out := DEFAULTS.duplicate(true)
	var entries: Array[Dictionary] = []
	for entry in FxRegistry.quality_policies:
		entries.append(entry)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	for entry in entries:
		var handler: Callable = entry.get("apply", Callable())
		if not handler.is_valid():
			continue
		var patch: Variant = handler.call(ctx, out.duplicate(true))
		if patch is Dictionary:
			for key in (patch as Dictionary).keys():
				out[key] = (patch as Dictionary)[key]
	out["output_downscale"] = false
	out["quality"] = clampi(int(out.get("quality", 1)), 0, 1)
	out["operator_quality"] = clampf(float(out.get("operator_quality", 1.0)), 0.0, 1.0)
	out["preview_limit"] = clampi(int(out.get("preview_limit", 128)), 16, 512)
	return out


static func provider_count() -> int:
	return FxRegistry.quality_policies.size()
