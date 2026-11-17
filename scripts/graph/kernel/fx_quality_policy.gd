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
## 硬约束：output_downscale 恒为 false —— **归档帧与导出**永不降采样，插件不能覆盖。
## 这是「时间可组合性」里的不变量：缓存里的帧、导出的序列、UI 上看到的那一张，
## 逐像素必须是同一份数据。
##
## 但这条不变量**只约束归档/导出**，不约束「贴到屏幕那一步」：
##   · `output_downscale` —— 归档/导出是否允许降采样，恒 false（内核钉死）；
##   · `display_scale`     —— 显示通道的采样倍率，可调（1.0 / 0.5 / 0.25）。
## 两者分开之前，想要一块小的预览就把整条输出链的精度一起赔进去；
## 分开之后，显示可以糊、缓存与导出仍然精确 —— 这正是 #2 要的那条独立管线。

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
	"display_scale": 1.0,
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
	out["display_scale"] = clampf(float(out.get("display_scale", 1.0)), 0.125, 1.0)
	out["quality"] = clampi(int(out.get("quality", 1)), 0, 1)
	out["operator_quality"] = clampf(float(out.get("operator_quality", 1.0)), 0.0, 1.0)
	out["preview_limit"] = clampi(int(out.get("preview_limit", 128)), 16, 512)
	return out


static func provider_count() -> int:
	return FxRegistry.quality_policies.size()
