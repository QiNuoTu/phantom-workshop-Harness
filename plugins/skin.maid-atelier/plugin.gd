extends FxPlugin
## 皮肤本体插件：只贡献一个 FxSkin 与它的「自定义选项协议 v2」声明。
##
## 对应原 Web 插件的 skin.json + exposeSkinCustomization()。
## 管理器不认识这些选项的含义；全部由 FxMaidAtelierSkin.apply_options() 解释，
## 这正是原协议「皮肤持有并清理自己的状态」的 Godot 版。

const PROTOCOL := 2


func skins() -> Array[Dictionary]:
	return [{
		"id": "maid-atelier",
		"name": "深海女仆工坊",
		"order": 50,
		"protocol": PROTOCOL,
		"author": "Small-tailqwq",
		"factory": FxMaidAtelierSkin.create,
		# 贴图走外部资源根：PCK 里不含任何图片，删掉目录即自动降级。
		"texture_root": "plugins/skin.maid-atelier/assets",
		"preview_texture": "preview.webp",
		"textures": {
			"palace_light": "palace_light.webp",
			"palace_dark": "palace_dark.webp",
			"maid_left": "maid_left.webp",
			"maid_right": "maid_right.webp",
			"chibi": "chibi.webp",
			"top_lace": "top_lace.webp",
			"bottom_trim": "bottom_trim.webp",
			"crest": "crest.webp",
			"swag": "swag.webp",
			"lace_tile": "lace_tile.png",
			"settings_frame": "settings_frame.webp",
			"preview": "preview.webp",
		},
		"options": [
			{"key": "show_artwork", "type": "boolean", "label": "启用皮肤贴图",
				"default": true},
			{"key": "show_characters", "type": "boolean", "label": "显示双女仆立绘",
				"default": true, "visibleWhen": {"key": "show_artwork", "values": [true]}},
			{"key": "show_trim", "type": "boolean", "label": "显示蕾丝与纹章",
				"default": true, "visibleWhen": {"key": "show_artwork", "values": [true]}},
			{"key": "show_chibi", "type": "boolean", "label": "显示 Q 版侧栏",
				"default": true, "visibleWhen": {"key": "show_artwork", "values": [true]}},
			{"key": "show_swag", "type": "boolean", "label": "显示侧栏垂幔",
				"default": false, "visibleWhen": {"key": "show_artwork", "values": [true]}},
			{"key": "artwork_opacity", "type": "slider", "label": "背景贴图不透明度",
				"default": 0.72, "min": 0.1, "max": 1.0, "step": 0.02,
				"visibleWhen": {"key": "show_artwork", "values": [true]}},
			{"key": "character_opacity", "type": "slider", "label": "立绘不透明度",
				"default": 0.80, "min": 0.1, "max": 1.0, "step": 0.02,
				"visibleWhen": {"key": "show_artwork", "values": [true]}},
			{"key": "character_scale", "type": "slider", "label": "立绘缩放",
				"default": 1.0, "min": 0.5, "max": 1.4, "step": 0.05,
				"visibleWhen": {"key": "show_artwork", "values": [true]}},
			{"key": "variant", "type": "select", "label": "主题", "default": "dark",
				"options": [
					{"value": "dark", "label": "深海蓝"},
					{"value": "light", "label": "陶瓷白"},
				]},
			{"key": "background_brightness", "type": "slider", "label": "背景亮度 (%)",
				"default": 80, "min": 60, "max": 100, "step": 1},
			{"key": "show_lace", "type": "boolean", "label": "显示侧栏 U 形花边",
				"default": true},
			{"key": "simple_process", "type": "boolean", "label": "简洁界面",
				"default": false},
			{"key": "banner_height", "type": "slider", "label": "装饰带高度",
				"default": 48, "min": 0, "max": 120, "step": 4,
				"visibleWhen": {"key": "show_lace", "values": [true]}},
			{"key": "accent", "type": "color", "label": "柔金强调色",
				"default": "#c5a468"},
			{"key": "accent_targets", "type": "checkbox-group", "label": "强调目标",
				"default": ["title", "frame"],
				"visibleWhen": {"key": "show_lace", "values": [true]},
				"options": [
					{"value": "title", "label": "标题"},
					{"value": "frame", "label": "边框"},
					{"value": "button", "label": "按钮"},
				]},
			{"key": "sfw_schedule", "type": "visibility-schedule",
				"label": "不那么二次元模式（按时段收起装饰）",
				"default": {"enabled": false, "outside": "visible", "ranges": []}},
		],
	}]


## 「插件功能」：插件中心会把这里注册的命令渲染成按钮。
func commands() -> Array[Dictionary]:
	return [{
		"id": "skin.maid.apply", "label": "应用此皮肤", "category": "皮肤",
		"handler": FxMaidAtelierSkin.apply_skin,
	}]
