class_name FxRecipePresets
extends RefCounted
## VfxEngine 配方预设：给配方节点一个可用的起点，也给测试提供稳定输入。
##
## 这些字典只使用 VfxEngine.configure 认得的字段；时间/颜色/数量都走它的轨道约定。

static func fire() -> Dictionary:
	return {
		"name": "火焰喷发",
		"width": 128, "height": 128, "duration": 1.2, "loop": true, "seed": 7,
		"palette": ["#0b1020", "#3a1d6e", "#b23a48", "#ff7a2a", "#ffd166", "#fff6d5"],
		"ramp_size": 10,
		"origin": [0.5, 0.72],
		"layers": [
			{"type": "flash", "t0": 0.0, "life": 0.2, "radius": [4, 18], "glow": 2.0,
				"color_to": 5},
			{"type": "cycle", "count": 42, "speed": [6, 36], "angle": [250, 290],
				"life": [0.55, 1.05], "size": [4.5, 8.0], "gravity": -26, "drag": 0.6,
				"glow": 0.45, "color_from": 8, "color_to": 4, "shape": "smoke",
				"spawn_radius": [1, 9], "y": [5, -3]},
			{"type": "cycle", "count": 70, "speed": [12, 58], "angle": [248, 292],
				"life": [0.5, 1.0], "size": [2.0, 4.0], "gravity": -30, "drag": 0.5,
				"glow": 1.1, "color_from": 8, "color_to": 3, "shape": "shard",
				"spawn_radius": [1, 10], "y": [5, -3]},
			{"type": "burst", "count": 26, "speed": [42, 104], "angle": [236, 304],
				"life": [0.22, 0.5], "size": [1.6, 3.0], "gravity": -6, "drag": 1.0,
				"glow": 1.4, "color_from": 8, "color_to": 6, "shape": "spark",
				"spawn_radius": [0, 4]},
			{"type": "aura", "period": 0.7, "radius": 14, "width": 1.0, "pulses": 2,
				"glow": 0.9, "color_from": 4, "color_to": 6},
		],
		"post": {"mode": "bloom", "amount": 0.35, "radius": 3, "threshold": 0.6},
	}


static func energy() -> Dictionary:
	return {
		"name": "能量环",
		"width": 128, "height": 128, "duration": 1.2, "loop": true, "seed": 21,
		"palette": ["#05070f", "#1b2a6b", "#2f6dff", "#66e0ff", "#eaffff"],
		"ramp_size": 9,
		"origin": [0.5, 0.5],
		"layers": [
			{"type": "aura", "period": 0.7, "radius": 30, "width": 1.2, "pulses": 2,
				"glow": 1.0, "color_from": 1, "color_to": 3},
			{"type": "orbit", "count": 36, "radius": [16, 34], "omega": [40, 160],
				"flatten": 0.6, "glow": 1.0, "color_from": 2, "color_to": 4},
			{"type": "ring", "t0": 0.0, "life": 0.8, "radius": [6, 54], "width": 1.4,
				"glow": 1.2, "color_from": 2, "color_to": 4},
			{"type": "flash", "t0": 0.0, "life": 0.22, "radius": [2, 22], "glow": 1.6,
				"color_to": 4},
		],
		"post": {"mode": "chromatic", "amount": 0.35, "offset": 2},
	}


static func impact() -> Dictionary:
	return {
		"name": "冲击波",
		"width": 128, "height": 128, "duration": 0.8, "loop": false, "seed": 33,
		"palette": ["#120a08", "#4a1b12", "#ff5a2a", "#ffd166", "#ffffff"],
		"ramp_size": 8,
		"origin": [0.5, 0.5],
		"layers": [
			{"type": "flash", "t0": 0.0, "life": 0.18, "radius": [4, 38], "glow": 2.0,
				"color_to": 4},
			{"type": "ring", "t0": 0.0, "life": 0.45, "radius": [6, 62], "width": 3.0,
				"glow": 1.6, "color_from": 2, "color_to": 4},
			{"type": "burst", "count": 36, "speed": [60, 160], "angle": [0, 360],
				"life": [0.3, 0.7], "size": [1.0, 2.8], "gravity": 0, "drag": 3.0,
				"glow": 1.0, "color_from": 3, "color_to": 0, "shape": "spark"},
		],
		"post": {"mode": "bloom", "amount": 0.7, "radius": 4, "threshold": 0.45},
	}


static func presets() -> Array[Dictionary]:
	return [
		{"id": "fire", "label": "火焰喷发", "json": JSON.stringify(fire(), "\t")},
		{"id": "energy", "label": "能量环", "json": JSON.stringify(energy(), "\t")},
		{"id": "impact", "label": "冲击波", "json": JSON.stringify(impact(), "\t")},
	]


static func json_of(id: String) -> String:
	for item in presets():
		if String(item.get("id", "")) == id:
			return String(item.get("json", ""))
	return ""


static func default_recipe() -> String:
	return JSON.stringify(fire(), "\t")
