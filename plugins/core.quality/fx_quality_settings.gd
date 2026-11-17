class_name FxQualitySettings
extends RefCounted
## 质量策略的**插件侧实现**。基座只保留默认值与不变量，具体档位、算子系数、
## 预览范围、节流系数全在这里声明。停用本插件后系统自动回落到基座默认策略。

const QUALITY_OPTIONS := [
	{"value": 0, "label": "交互预览（快）"},
	{"value": 1, "label": "精确（与导出一致）"},
]
const SCOPE_OPTIONS := [
	{"value": "all", "label": "全部节点"},
	{"value": "selection_output", "label": "选中节点 + 输出"},
	{"value": "none", "label": "不刷新节点预览"},
]
const PRESET_OPTIONS := [
	{"value": "none", "label": "无（逐项设置）"},
	{"value": "performance", "label": "性能优先"},
	{"value": "balanced", "label": "均衡"},
	{"value": "fidelity", "label": "画质优先"},
]
## 显示通道的采样倍率。只影响屏幕上的那张图，缓存与导出不受影响。
const DISPLAY_SCALE_OPTIONS := [
	{"value": 1.0, "label": "全分辨率（1:1）"},
	{"value": 0.5, "label": "一半（大画布更跟手）"},
	{"value": 0.25, "label": "四分之一（只求跟手）"},
]
const PRESETS := {
	"none": {},
	"performance": {
		"quality": 0, "operator_quality": 0.5, "preview_limit": 64,
		"preview_scope": "selection_output", "blur_fast_path": true,
		"throttle_factor": 0.0012, "max_blur_radius": 16,
	},
	"balanced": {
		"operator_quality": 0.85, "preview_limit": 96, "blur_fast_path": true,
	},
	"fidelity": {
		"quality": 1, "operator_quality": 1.0, "blur_fast_path": false,
		"preview_limit": 192, "preview_scope": "all", "throttle_factor": 0.0002,
	},
}

static var _override: Dictionary = {}


static func settings() -> Array[Dictionary]:
	return [
		{
			"id": "quality.preset", "label": "质量预设", "group": "渲染质量",
			"kind": "enum", "default": "none", "options": PRESET_OPTIONS,
			"capability": "quality.preset", "impact": "derived", "applies": "runtime", "order": 10,
			"description": "预设会覆盖下方同名项；由能力代理广播给所有质量 provider。",
		},
		{
			"id": "quality.paused", "label": "暂停时质量档", "group": "渲染质量",
			"kind": "enum", "default": 1, "options": QUALITY_OPTIONS,
			"impact": "derived", "applies": "runtime", "order": 20,
		},
		{
			"id": "quality.playing", "label": "播放时质量档", "group": "渲染质量",
			"kind": "enum", "default": 0, "options": QUALITY_OPTIONS,
			"impact": "derived", "applies": "runtime", "order": 21,
		},
		{
			"id": "quality.operator", "label": "算子质量系数", "group": "渲染质量",
			"kind": "float", "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05,
			"impact": "derived", "applies": "runtime", "order": 30,
			"description": "注入 ctx.operator_quality；算子自己决定如何降级，输出链始终精确。",
		},
		{
			"id": "quality.max_blur_radius", "label": "模糊半径上限", "group": "渲染质量",
			"kind": "int", "default": 32, "min": 1, "max": 128, "step": 1,
			"impact": "derived", "applies": "runtime", "order": 31,
		},
		{
			"id": "quality.blur_fast_path", "label": "模糊快速路径", "group": "渲染质量",
			"kind": "bool", "default": true, "impact": "derived", "applies": "runtime", "order": 32,
		},
		{
			"id": "quality.preview_limit", "label": "节点预览边长", "group": "渲染质量",
			"kind": "int", "default": 128, "min": 16, "max": 512, "step": 16,
			"impact": "derived", "applies": "runtime", "order": 40,
		},
		{
			# 节点小图与输出预览是**两条不同的管线**：小图可以糊、可以慢半拍，
			# 输出预览必须是精确帧（内核把 output_downscale 钉死为 false）。
			# 这两项只作用于「缩略图趟」，不会污染精确帧缓存。
			"id": "quality.preview_operator", "label": "节点小图算子质量", "group": "渲染质量",
			"kind": "float", "default": 0.5, "min": 0.1, "max": 1.0, "step": 0.05,
			"impact": "derived", "applies": "runtime", "order": 43,
			"description": "只影响节点卡片上的缩略图（模糊半径、采样步长这类降级）；最终输出与缓存帧始终精确。",
		},
		{
			"id": "quality.preview_refresh_ms", "label": "节点小图刷新间隔", "group": "渲染质量",
			"kind": "int", "default": 1500, "min": 120, "max": 5000, "step": 60,
			"impact": "derived", "applies": "runtime", "order": 44,
			"description": "缩略图趟两次之间的最小间隔。调小更跟手，代价是后台算得更勤。",
		},
		{
			"id": "quality.preview_scope", "label": "播放时预览范围", "group": "渲染质量",
			"kind": "enum", "default": "selection_output", "options": SCOPE_OPTIONS,
			"impact": "derived", "applies": "runtime", "order": 41,
		},
		{
			"id": "quality.capture_previews", "label": "生成节点预览", "group": "渲染质量",
			"kind": "bool", "default": true, "impact": "derived", "applies": "runtime", "order": 42,
		},
		{
			"id": "quality.static_cache", "label": "静态子图跨帧缓存", "group": "渲染质量",
			"kind": "bool", "default": true, "impact": "derived", "applies": "runtime", "order": 50,
		},
		{
			# 只影响「贴到屏幕那一步」的分辨率：归档帧、导出序列、缓存里的帧都不动。
			# 所以它的 impact 是 `display`（只丢显示层），不是 `derived` —— 换个倍率
			# 不该让整段精确帧重算，那正是 0.0.11 之前最贵的一次误伤。
			"id": "quality.display_scale", "label": "显示采样倍率", "group": "渲染质量",
			"kind": "enum", "default": 1.0, "options": DISPLAY_SCALE_OPTIONS,
			"impact": "display", "applies": "runtime", "order": 45,
			"description": "只缩放显示通道。缓存帧与导出仍是全分辨率，逐像素不变。",
		},
		{
			"id": "quality.adaptive_throttle", "label": "自适应渲染节流", "group": "渲染质量",
			"kind": "bool", "default": true, "impact": "none", "applies": "runtime", "order": 51,
		},
		{
			"id": "quality.throttle_factor", "label": "节流系数", "group": "渲染质量",
			"kind": "float", "default": 0.0006, "min": 0.0, "max": 0.01, "step": 0.0002,
			"impact": "none", "applies": "runtime", "order": 52,
		},
	]


static func capabilities() -> Array[Dictionary]:
	return [{
		"key": "quality.preset", "apply": apply_preset, "order": 10,
		"description": "把预设覆盖表推给质量策略；其它插件也能监听同一个键。",
	}]


static func apply_preset(value: Variant) -> void:
	var name := str(value)
	_override = (PRESETS.get(name, {}) as Dictionary).duplicate(true)


static func override() -> Dictionary:
	return _override.duplicate(true)


static func quality_policies() -> Array[Dictionary]:
	return [{"apply": policy, "order": 100, "label": "设置驱动的质量档位"}]


## 只返回需要覆盖的字段；基座默认值 + 其它 provider 的结果保留。
static func policy(ctx: Dictionary, _current: Dictionary) -> Dictionary:
	var playing := bool(ctx.get("playing", false))
	var patch := {
		"quality": int(FxSettings.value("quality.playing" if playing else "quality.paused")),
		"operator_quality": float(FxSettings.value("quality.operator")),
		"max_blur_radius": int(FxSettings.value("quality.max_blur_radius")),
		"blur_fast_path": bool(FxSettings.value("quality.blur_fast_path")),
		"preview_limit": int(FxSettings.value("quality.preview_limit")),
		"preview_operator": float(FxSettings.value("quality.preview_operator")),
		"preview_refresh_ms": int(FxSettings.value("quality.preview_refresh_ms")),
		"preview_scope": String(FxSettings.value("quality.preview_scope")),
		"capture_previews": bool(FxSettings.value("quality.capture_previews")),
		"static_cache": bool(FxSettings.value("quality.static_cache")),
		"adaptive_throttle": bool(FxSettings.value("quality.adaptive_throttle")),
		"throttle_factor": float(FxSettings.value("quality.throttle_factor")),
		"display_scale": float(FxSettings.value("quality.display_scale")),
		"operator_quality_threshold": 0.999,
	}
	return patch.merged(_override, true)
