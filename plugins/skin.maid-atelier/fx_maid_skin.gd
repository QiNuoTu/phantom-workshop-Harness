class_name FxMaidAtelierSkin
extends FxSkin
## 「深海女仆工坊」皮肤（由 smalltailqwq/dsh-client-ui-skin-maid-atelier 移植）。
##
## 配色取自原 skin.json：深海蓝、陶瓷白、长春花蓝、柔金 #c5a468。
## 贴图走基座的 FxSkin.textures 通道，由外部资源根 plugins/skin.maid-atelier/assets/
## 按 manifest.json 语义映射加载；贴图**不进 PCK**，删掉该目录会自动回落到
## 自绘几何花边（glass_alpha 归 1.0），软件照常可用。
##
## 许可：原包美术资源为 CC BY-NC-SA 4.0（署名 / 非商业 / 相同方式共享），
## 完整创作链与许可全文见 plugins/skin.maid-atelier/assets/NOTICE.md。
## 商业发行版必须移除整个贴图目录；本文件与布局代码仅为 MIT 概念移植。


## 插件功能：在插件中心里一键应用本皮肤（命令是插件自己的贡献）。
static func apply_skin(ctx: Dictionary) -> void:
	var shell: Variant = ctx.get("shell")
	if shell != null and shell is Object and (shell as Object).has_method("apply_skin"):
		(shell as Object).call("apply_skin", "maid-atelier")


static func create() -> FxSkin:
	return FxMaidAtelierSkin.new()


func _init() -> void:
	id = "maid-atelier"
	display_name = "深海女仆工坊"
	_apply_palette(false)
	_rebuild_layers()


func _apply_palette(light: bool) -> void:
	if light:
		bg = Color("#eef1f8")
		panel = Color("#ffffff")
		panel_alt = Color("#e2e9f6")
		bar = Color("#dbe4f4")
		border = Color("#9a7d3f")
		border_soft = Color("#c9d2e6")
		text = Color("#1d2b4d")
		text_strong = Color("#0b1b33")
		muted = Color("#5a6c96")
		button_normal = Color("#e8eefb")
		button_hover = Color("#d6e2fa")
		button_pressed = Color("#c2d3f5")
		button_border_hover = Color("#9a7d3f")
		input_bg = Color("#ffffff")
		selected = Color("#bfd3f7")
	else:
		bg = Color("#081228")
		panel = Color("#0e2340")
		panel_alt = Color("#123055")
		bar = Color("#070f22")
		border = Color("#c5a468")
		border_soft = Color("#3c4a6b")
		text = Color("#efe9dc")
		text_strong = Color("#fffaf0")
		muted = Color("#a6b3cd")
		button_normal = Color("#15345c")
		button_hover = Color("#1d4575")
		button_pressed = Color("#27548c")
		button_border_hover = Color("#c5a468")
		input_bg = Color("#061126")
		selected = Color("#25446f")
	accent_cool = Color("#8a9cff")
	danger = Color("#ff8a9b")
	ok = Color("#9be7c4")


func apply_options(settings: Dictionary) -> void:
	options = settings.duplicate(true)
	var light := String(settings.get("variant", "dark")) == "light"
	_apply_palette(light)
	# 背景亮度 60~100%：越低越深，只作用于大面积底色，文字对比度保持不变。
	var brightness := clampf(float(settings.get("background_brightness", 80)) / 100.0, 0.6, 1.0)
	var dim := (1.0 - brightness) * 1.2
	bg = bg.darkened(dim)
	panel = panel.darkened(dim * 0.6)
	bar = bar.darkened(dim * 0.8)
	var accent_raw := String(settings.get("accent", "#c5a468"))
	if Color.html_is_valid(accent_raw):
		accent = Color(accent_raw)
	var targets: Array = settings.get("accent_targets", ["title", "frame"])
	if targets.has("frame"):
		border = accent.darkened(0.25)
	if targets.has("button"):
		button_border_hover = accent
	# 「显示侧栏 U 形花边」 = 圆角与几何装饰开关；贴图花边另由 show_trim 控制。
	corner_radius = 10 if bool(settings.get("show_lace", true)) else 0
	if bool(settings.get("simple_process", false)):
		bar = bg
		border_soft = border_soft.darkened(0.35)
	_rebuild_layers()


## 外部贴图注入点：基座把语义名 -> Texture2D 的字典交给皮肤，
## 皮肤自己决定玻璃透明度与布局；没有贴图时全部回归不透明 + 自绘花边。
func set_textures(p_textures: Dictionary) -> void:
	textures = p_textures
	var light := String(options.get("variant", "dark")) == "light"
	glass_alpha = 1.0 if textures.is_empty() else (0.90 if light else 0.90)
	_rebuild_layers()


func _rebuild_layers() -> void:
	var has_art := not textures.is_empty()
	var show_art := has_art and bool(options.get("show_artwork", true))
	var show_chars := show_art and bool(options.get("show_characters", true)) and not _sfw_hidden()
	var show_trim := show_art and bool(options.get("show_trim", true))
	var show_chibi := show_art and bool(options.get("show_chibi", false)) and not _sfw_hidden()
	var art_opacity := clampf(float(options.get("artwork_opacity", 0.72)), 0.05, 1.0)
	var char_opacity := clampf(float(options.get("character_opacity", 0.80)), 0.05, 1.0)
	var char_scale := clampf(float(options.get("character_scale", 1.0)), 0.4, 1.6)
	var light := String(options.get("variant", "dark")) == "light"
	var palace := "palace_light" if light else "palace_dark"
	var layers: Array[Dictionary] = []
	layers.append({
		"id": "background", "texture": palace, "layer": "back",
		"anchor": "full", "mode": "cover", "opacity": art_opacity, "visible": show_art,
	})
	layers.append({
		# 立绘放在 back 层：透过半透明面板可见，但不会盖住列表/表单文字。
		"id": "maid_left", "texture": "maid_left", "layer": "back",
		"anchor": "bottom_left", "mode": "fit",
		"height_ratio": 0.74 * char_scale, "opacity": char_opacity,
		"offset": [-4, 0], "visible": show_chars,
	})
	layers.append({
		"id": "maid_right", "texture": "maid_right", "layer": "back",
		"anchor": "bottom_right", "mode": "fit",
		"height_ratio": 0.72 * char_scale, "opacity": char_opacity,
		"offset": [4, 0], "visible": show_chars,
	})
	layers.append({
		"id": "chibi", "texture": "chibi", "layer": "front",
		"anchor": "bottom_right", "mode": "fit",
		"height_ratio": 0.22 * char_scale, "opacity": 0.9,
		"offset": [-10, -10], "visible": show_chibi,
	})
	# 前景装饰：顶部蕾丝、底部纹章与花边带，压在面板之上但不拦截输入。
	layers.append({
		# 顶部蕾丝放在 back 层：压在前景会盖住「文件/编辑/窗口」菜单文字。
		"id": "top_lace", "texture": "top_lace", "layer": "back",
		"anchor": "top", "mode": "tile_x", "height_px": 40.0,
		"opacity": 0.9, "visible": show_trim,
	})
	layers.append({
		# 纹章放回背层：放在前景会浮在时间轴/状态栏上，看起来像错位。
		"id": "crest", "texture": "crest", "layer": "back",
		"anchor": "bottom", "mode": "fit", "height_px": 36.0,
		"opacity": 0.75, "visible": show_trim,
	})
	layers.append({
		"id": "bottom_trim", "texture": "bottom_trim", "layer": "back",
		"anchor": "bottom", "mode": "tile_x", "height_px": 12.0,
		"opacity": 0.65, "visible": show_trim,
	})
	layers.append({
		"id": "swag", "texture": "swag", "layer": "front",
		"anchor": "top", "mode": "fit", "height_px": 68.0,
		"opacity": 0.55, "visible": show_trim and bool(options.get("show_swag", false)),
	})
	texture_layers = layers


func _sfw_hidden() -> bool:
	var raw: Variant = options.get("sfw_schedule", {})
	if not raw is Dictionary:
		return false
	var schedule: Dictionary = raw
	if not bool(schedule.get("enabled", false)):
		return false
	if String(schedule.get("outside", "visible")) != "hidden":
		return false
	var hour := int(Time.get_time_dict_from_system().get("hour", 12))
	for entry in schedule.get("ranges", []):
		if not entry is Dictionary:
			continue
		var range_entry: Dictionary = entry
		var start := int(range_entry.get("start", 0))
		var end := int(range_entry.get("end", 24))
		if start <= end:
			if hour >= start and hour < end:
				return false
		elif hour >= start or hour < end:
			return false
	return true


func build_decoration() -> Control:
	if textures.is_empty():
		# 没有外部贴图包时回落到自绘 U 形花边（原移植版行为）。
		var lace := FxMaidLace.new()
		lace.setup(bool(options.get("show_lace", true)),
			float(options.get("banner_height", 48)))
		return lace
	var layer := FxSkinTextureLayer.new()
	layer.setup(self, false)
	return layer


func build_overlay() -> Control:
	if textures.is_empty():
		return null
	var layer := FxSkinTextureLayer.new()
	layer.setup(self, true)
	return layer


## 标题栏用皮肤自带的金色花边横幅（只此一处，避免每条标签栏都堆花边）。
## 停靠标签条保持深色细条 + 金色下边线，文字不会被花纹压住。
func chrome_style(kind: String) -> StyleBox:
	var tex := texture("settings_frame")
	if kind == "title" and tex != null:
		var bar_style := StyleBoxTexture.new()
		bar_style.texture = tex
		bar_style.texture_margin_left = 120.0
		bar_style.texture_margin_right = 120.0
		bar_style.texture_margin_top = 18.0
		bar_style.texture_margin_bottom = 18.0
		# 两侧留够花边的宽度，文字不会压在花纹上。
		bar_style.content_margin_left = 104.0
		bar_style.content_margin_right = 104.0
		bar_style.content_margin_top = 4.0
		bar_style.content_margin_bottom = 4.0
		return bar_style
	if kind == "dock_bar":
		var dock_style := StyleBoxFlat.new()
		dock_style.bg_color = Color(bar, 0.92)
		dock_style.border_color = Color(accent, 0.45)
		dock_style.border_width_bottom = 1
		dock_style.content_margin_top = 3.0
		dock_style.content_margin_bottom = 3.0
		return dock_style
	if kind == "toolbar":
		var tool_style := StyleBoxFlat.new()
		tool_style.bg_color = Color(bar, 0.55)
		tool_style.border_color = Color(accent, 0.28)
		tool_style.border_width_bottom = 1
		tool_style.content_margin_top = 3.0
		tool_style.content_margin_bottom = 3.0
		return tool_style
	return super.chrome_style(kind)


## 面板：金色 1px 细边 + 皮肤圆角，卡片与停靠区都吃这套。
func panel_style(bg_color: Color, border_color: Color, corner: int = -1) -> StyleBoxFlat:
	var tint := border_color
	if tint == border or tint == border_soft:
		tint = Color(accent, 0.55)
	return super.panel_style(bg_color, tint, corner if corner >= 0 else corner_radius)


## 停靠标签：选中项金边 + 深蓝底，像参考图里的绶带。
func tab_style(active: bool, hover: bool = false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	if active:
		style.bg_color = Color(accent, 0.22)
		style.border_color = Color(accent, 0.9)
	elif hover:
		style.bg_color = Color(panel_alt, 0.85)
		style.border_color = Color(accent, 0.35)
	else:
		style.bg_color = Color(0, 0, 0, 0)
		style.border_color = Color(0, 0, 0, 0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0
	return style


## 让 GraphEdit 画布更透，背景宫殿与双立绘才能真正从中央区域显现。
func build_theme() -> Theme:
	var theme := super.build_theme()
	if not textures.is_empty():
		theme.set_stylebox("panel", "GraphEdit",
			panel_style(Color(bg, 0.10), Color(border, 0.28), 0))
	return theme


## 自绘 U 形花边：无贴图包时的降级装饰，纯几何、不依赖任何图片素材。
class FxMaidLace extends Control:
	var enabled: bool = true
	var band_height: float = 48.0

	func setup(p_enabled: bool, p_height: float) -> void:
		enabled = p_enabled
		band_height = p_height
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		queue_redraw()

	func _draw() -> void:
		if not enabled or band_height <= 0.0:
			return
		var color := Color(FxUiKit.ACCENT, 0.22)
		var dot := Color(FxUiKit.ACCENT, 0.55)
		var h := minf(band_height, size.y * 0.5)
		for side in [0.0, 1.0]:
			var x := 6.0 if side == 0.0 else size.x - 6.0
			for i in range(int(h / 10.0)):
				draw_circle(Vector2(x, size.y - h + float(i) * 10.0), 1.6, dot)
			draw_arc(Vector2(x + (10.0 if side == 0.0 else -10.0), size.y - h + 4.0),
				10.0, PI * 0.5 if side == 0.0 else -PI * 0.5,
				PI * 1.5 if side == 0.0 else PI * 0.5, 12, color, 1.5)
