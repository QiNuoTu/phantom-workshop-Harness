class_name FxSkin
extends RefCounted
## 皮肤契约（基座只定义接口与最小默认实现）。
##
## 插件继承 FxSkin 覆盖任意颜色 / build_theme() / 控件工厂，即可替换整套视觉。
## FxUiKit 是稳定门面：所有面板继续调用 FxUiKit.xxx，实际委托给
## FxUiKit.current，FxShell 从插件注册表选中皮肤后调用 FxUiKit.use(skin)。
##
## 默认实现是 **Qt / Fusion 风格**：中性灰阶、1px 硬边、3–4px 圆角、
## 28px 左右的控件高度、清晰的层级与分隔线，不用渐变和大圆角。
## 控件不要在自身写死十六进制，一律走这里的 token；换肤时外壳重建 UI。

var id: String = "default"
var display_name: String = "默认（Qt 深色）"

var bg: Color = Color("#1f2124")
var panel: Color = Color("#25272b")
var panel_alt: Color = Color("#2a2d32")
var bar: Color = Color("#232528")
var border: Color = Color("#3a3d42")
var border_soft: Color = Color("#2f3237")
var text: Color = Color("#d4d7dc")
var text_strong: Color = Color("#f2f4f7")
var muted: Color = Color("#8d939c")
var accent: Color = Color("#3d8bfd")
var accent_cool: Color = Color("#56b6ff")
var danger: Color = Color("#e5534b")
var ok: Color = Color("#3fb950")

var button_normal: Color = Color("#2c2f34")
var button_hover: Color = Color("#383c42")
var button_pressed: Color = Color("#43474e")
var button_border_hover: Color = Color("#4a4f57")
var input_bg: Color = Color("#1a1c1f")
var selected: Color = Color("#2c4f7f")
var corner_radius: int = 4
## 面板内边距（Qt 默认较紧，靠留白而不是大圆角分层）。
var pad_x: int = 8
var pad_y: int = 6
## 玻璃透明度：1.0 = 不透明；<1 时所有 panel_style 背景变半透明，
## 让下方贴图装饰层透出来。文字颜色不变，皮肤自己负责对比度。
var glass_alpha: float = 1.0
## 皮肤自定义选项（协议 v2）。由皮肤插件声明、管理器渲染表单并持久化。
var options: Dictionary = {}
## 贴图通道：id -> Texture2D。由 FxSkinTextureLibrary 从**外部资源根**加载，
## 不进 PCK（美术素材可能是第三方许可，见插件目录 assets/NOTICE.md）。
## texture_layers 是声明式布局，交给通用 FxSkinTextureLayer 渲染，
## 因此皮肤插件不必自己写 draw_texture 代码就能用贴图。
var textures: Dictionary = {}
var texture_layers: Array[Dictionary] = []
var texture_root: String = ""


## 收到贴图集合时调用；子类可覆盖它重建 texture_layers。
func set_textures(p_textures: Dictionary) -> void:
	textures = p_textures


func texture(texture_id: String) -> Texture2D:
	var value: Variant = textures.get(texture_id)
	return value if value is Texture2D else null


func has_textures() -> bool:
	return not textures.is_empty()


func texture_layout() -> Array[Dictionary]:
	return texture_layers


## 皮肤收到用户选项时调用；子类覆盖它调整上面的 token。
## 基座不解释任何具体选项，管理器也不认识皮肤内部实现。
func apply_options(_settings: Dictionary) -> void:
	pass


## 可选背景装饰层（在底板之上、面板之下）。返回 null 表示不挂装饰。
## 默认实现：若皮肤声明了贴图布局，就用通用贴图渲染器画 back 层。
func build_decoration() -> Control:
	if texture_layers.is_empty():
		return null
	var layer := FxSkinTextureLayer.new()
	layer.setup(self, false)
	return layer


## 可选前景装饰层（在所有面板之上、浮动窗口之下，且不拦截输入）。
## 花边、纹章、角饰这类「压在 UI 上」的贴图放这里。
func build_overlay() -> Control:
	return null


## 供 FxUiKit 同步静态颜色 token。插件若新增 token 可覆盖本方法。
func colors() -> Dictionary:
	return {
		"BG": bg, "PANEL": panel, "PANEL_ALT": panel_alt, "BAR": bar,
		"BORDER": border, "BORDER_SOFT": border_soft,
		"TEXT": text, "TEXT_STRONG": text_strong, "MUTED": muted,
		"ACCENT": accent, "ACCENT_COOL": accent_cool,
		"DANGER": danger, "OK": ok,
	}


func surface(color: Color) -> Color:
	return Color(color, color.a * clampf(glass_alpha, 0.0, 1.0))


## 浮动窗口 / 弹窗用：不吃 glass_alpha，保证文字始终有不透明底。
func solid_panel_style(bg_color: Color, border_color: Color, corner: int = -1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.border_color = border_color
	style.set_border_width_all(1)
	style.set_corner_radius_all(corner if corner >= 0 else corner_radius)
	style.content_margin_left = float(pad_x)
	style.content_margin_right = float(pad_x)
	style.content_margin_top = float(pad_y)
	style.content_margin_bottom = float(pad_y)
	style.anti_aliasing = false
	return style


## 浮动窗口：不透明 + 极轻投影，明确「浮在界面之上」但不抢视觉。
func window_style(bg_color: Color, border_color: Color, corner: int = -1) -> StyleBoxFlat:
	var style := solid_panel_style(bg_color, border_color, corner)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 4)
	return style


## 停靠区标签 / 菜单按钮：Qt 风格「下方 2px 强调线 + 轻微底色」。
func tab_style(active: bool, hover: bool = false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	if active:
		style.bg_color = panel
		style.border_color = accent
		style.border_width_bottom = 2
	elif hover:
		style.bg_color = button_hover
		style.border_color = Color(0, 0, 0, 0)
	else:
		style.bg_color = Color(0, 0, 0, 0)
		style.border_color = Color(0, 0, 0, 0)
	style.set_corner_radius_all(3)
	style.corner_radius_bottom_left = 0 if active else 3
	style.corner_radius_bottom_right = 0 if active else 3
	style.content_margin_left = 9.0
	style.content_margin_right = 9.0
	style.content_margin_top = 3.0
	style.content_margin_bottom = 3.0
	style.anti_aliasing = false
	return style


## 外壳 chrome 的背景样式：菜单条 / 工具栏 / 状态栏 / 停靠标签条。
## 返回 StyleBox（可以是 StyleBoxTexture），皮肤因此能用贴图做装饰条。
func chrome_style(kind: String) -> StyleBox:
	match kind:
		"title", "menu":
			return panel_style(bar, border_soft, 0)
		"toolbar":
			return panel_style(panel, border_soft, 0)
		"status":
			return panel_style(bar, border_soft, 0)
		"dock_bar":
			return panel_style(bar, border_soft, 0)
	return panel_style(panel, border_soft, 0)


func panel_style(bg_color: Color, border_color: Color, corner: int = -1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = surface(bg_color)
	style.border_color = border_color
	style.set_border_width_all(1)
	style.set_corner_radius_all(corner if corner >= 0 else corner_radius)
	style.content_margin_left = float(pad_x)
	style.content_margin_right = float(pad_x)
	style.content_margin_top = float(pad_y)
	style.content_margin_bottom = float(pad_y)
	style.anti_aliasing = false
	return style


## 统一主题：只覆盖项目实际用到的控件，避免和 Godot 默认主题打架。
func build_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 12
	for type_name in ["Label", "Button", "MenuButton", "CheckBox", "CheckButton",
			"PopupMenu", "OptionButton", "ItemList", "SpinBox", "TooltipLabel",
			"Tree", "RichTextLabel"]:
		theme.set_color("font_color", type_name, text)
	for type_name2 in ["LineEdit", "TextEdit"]:
		theme.set_color("font_color", type_name2, text_strong)
		theme.set_color("font_placeholder_color", type_name2, muted)
	theme.set_color("font_selected_color", "ItemList", text_strong)

	theme.set_stylebox("panel", "PanelContainer", panel_style(panel, border, 3))
	theme.set_stylebox("panel", "Panel", panel_style(bg, border_soft, 0))
	theme.set_stylebox("panel", "PopupMenu", window_style(panel_alt, border, 4))
	theme.set_stylebox("panel", "PopupPanel", window_style(panel_alt, border, 4))
	theme.set_stylebox("panel", "TooltipPanel", window_style(panel_alt, border, 3))

	# 按钮：1px 边、3px 角、左右 9px —— Fusion 的比例。
	var btn_normal := solid_panel_style(button_normal, border, 3)
	btn_normal.content_margin_left = 9.0
	btn_normal.content_margin_right = 9.0
	btn_normal.content_margin_top = 4.0
	btn_normal.content_margin_bottom = 4.0
	var btn_hover := solid_panel_style(button_hover, button_border_hover, 3)
	btn_hover.content_margin_left = 9.0
	btn_hover.content_margin_right = 9.0
	btn_hover.content_margin_top = 4.0
	btn_hover.content_margin_bottom = 4.0
	var btn_pressed := solid_panel_style(button_pressed, accent.darkened(0.15), 3)
	btn_pressed.content_margin_left = 9.0
	btn_pressed.content_margin_right = 9.0
	btn_pressed.content_margin_top = 4.0
	btn_pressed.content_margin_bottom = 4.0
	theme.set_stylebox("normal", "Button", btn_normal)
	theme.set_stylebox("hover", "Button", btn_hover)
	theme.set_stylebox("pressed", "Button", btn_pressed)
	theme.set_stylebox("disabled", "Button", solid_panel_style(panel_alt, border_soft, 3))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_pressed_color", "Button", text_strong)
	theme.set_color("font_hover_color", "Button", text_strong)
	theme.set_color("font_disabled_color", "Button", muted.darkened(0.25))

	var input_style := solid_panel_style(input_bg, button_border_hover, 3)
	input_style.content_margin_left = 7.0
	input_style.content_margin_right = 7.0
	input_style.content_margin_top = 4.0
	input_style.content_margin_bottom = 4.0
	theme.set_stylebox("normal", "LineEdit", input_style)
	var focus_style := solid_panel_style(input_bg, accent, 3)
	focus_style.content_margin_left = 7.0
	focus_style.content_margin_right = 7.0
	focus_style.content_margin_top = 4.0
	focus_style.content_margin_bottom = 4.0
	theme.set_stylebox("focus", "LineEdit", focus_style)
	theme.set_stylebox("read_only", "LineEdit", solid_panel_style(bg, border_soft, 3))
	theme.set_stylebox("normal", "TextEdit", input_style)
	theme.set_stylebox("focus", "TextEdit", focus_style)
	theme.set_stylebox("normal", "OptionButton", btn_normal)
	theme.set_stylebox("hover", "OptionButton", btn_hover)
	theme.set_stylebox("pressed", "OptionButton", btn_pressed)

	var item_selected := StyleBoxFlat.new()
	item_selected.bg_color = selected
	item_selected.set_corner_radius_all(2)
	theme.set_stylebox("selected", "ItemList", item_selected)
	theme.set_stylebox("selected_focus", "ItemList", item_selected)
	theme.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	theme.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	theme.set_color("font_color", "ItemList", text)
	theme.set_constant("v_separation", "ItemList", 3)
	theme.set_stylebox("selected", "Tree", item_selected)
	theme.set_stylebox("selected_focus", "Tree", item_selected)
	theme.set_stylebox("focus", "Tree", StyleBoxEmpty.new())
	theme.set_constant("v_separation", "Tree", 4)
	theme.set_constant("item_margin", "Tree", 12)

	# 滚动条：12px 槽 + 3px 圆角滑块，Qt 的「可见但安静」。
	var track := StyleBoxFlat.new()
	track.bg_color = Color(bg, 0.6)
	track.set_corner_radius_all(0)
	track.content_margin_left = 3.0
	track.content_margin_right = 3.0
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(button_hover.lightened(0.08), 1.0)
	grabber.set_corner_radius_all(3)
	var grabber_hover := StyleBoxFlat.new()
	grabber_hover.bg_color = button_border_hover
	grabber_hover.set_corner_radius_all(3)
	var grabber_down := StyleBoxFlat.new()
	grabber_down.bg_color = accent
	grabber_down.set_corner_radius_all(3)
	for bar_name in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", bar_name, track)
		theme.set_stylebox("grabber", bar_name, grabber)
		theme.set_stylebox("grabber_highlight", bar_name, grabber_hover)
		theme.set_stylebox("grabber_pressed", bar_name, grabber_down)
		theme.set_constant("minimum_grab_thickness", bar_name, 10)

	# 标签页：选中项下方 2px 强调线，不做大圆角。
	theme.set_stylebox("panel", "TabContainer", panel_style(panel, border, 3))
	var tab_selected := StyleBoxFlat.new()
	tab_selected.bg_color = panel
	tab_selected.border_color = accent
	tab_selected.border_width_bottom = 2
	tab_selected.content_margin_left = 12.0
	tab_selected.content_margin_right = 12.0
	tab_selected.content_margin_top = 5.0
	tab_selected.content_margin_bottom = 5.0
	var tab_unselected := StyleBoxFlat.new()
	tab_unselected.bg_color = Color(0, 0, 0, 0)
	tab_unselected.content_margin_left = 12.0
	tab_unselected.content_margin_right = 12.0
	tab_unselected.content_margin_top = 5.0
	tab_unselected.content_margin_bottom = 5.0
	var tab_hovered := StyleBoxFlat.new()
	tab_hovered.bg_color = button_hover
	tab_hovered.content_margin_left = 12.0
	tab_hovered.content_margin_right = 12.0
	tab_hovered.content_margin_top = 5.0
	tab_hovered.content_margin_bottom = 5.0
	for tab_name in ["TabContainer", "TabBar"]:
		theme.set_stylebox("tab_selected", tab_name, tab_selected)
		theme.set_stylebox("tab_unselected", tab_name, tab_unselected)
		theme.set_stylebox("tab_hovered", tab_name, tab_hovered)
	theme.set_color("font_selected_color", "TabContainer", text_strong)
	theme.set_color("font_unselected_color", "TabContainer", muted)
	theme.set_color("font_hovered_color", "TabContainer", text)

	var popup_style := window_style(panel_alt, border, 4)
	popup_style.content_margin_left = 4.0
	popup_style.content_margin_right = 4.0
	popup_style.content_margin_top = 4.0
	popup_style.content_margin_bottom = 4.0
	theme.set_stylebox("panel", "PopupMenu", popup_style)
	theme.set_stylebox("panel", "PopupPanel", popup_style)

	# 独立窗口与对话框（AcceptDialog / FileDialog / Window）不继承 Control 的 theme，
	# 必须在这里显式下发，否则插件弹出的面板永远是 Godot 默认灰。
	for window_class in ["Window", "AcceptDialog", "ConfirmationDialog", "FileDialog"]:
		theme.set_stylebox("panel", window_class, window_style(panel, border, 5))
		theme.set_stylebox("embedded_border", window_class, window_style(panel, border, 5))
		theme.set_stylebox("embedded_unfocused_border", window_class, window_style(panel, border_soft, 5))
		theme.set_color("title_color", window_class, text_strong)
		theme.set_constant("title_height", window_class, 30)
		theme.set_font_size("title_font_size", window_class, 12)
	var popup_hover := StyleBoxFlat.new()
	popup_hover.bg_color = Color(accent, 0.22)
	popup_hover.set_corner_radius_all(2)
	theme.set_stylebox("hover", "PopupMenu", popup_hover)
	theme.set_color("font_color", "PopupMenu", text)
	theme.set_color("font_hover_color", "PopupMenu", text_strong)
	theme.set_color("font_disabled_color", "PopupMenu", muted)
	theme.set_color("font_accelerator_color", "PopupMenu", muted)
	theme.set_constant("v_separation", "PopupMenu", 4)
	theme.set_constant("item_start_padding", "PopupMenu", 8)
	theme.set_constant("item_end_padding", "PopupMenu", 8)

	# 分隔条与拖动条：细、直、悬停变亮。
	theme.set_constant("separation", "HSplitContainer", 5)
	theme.set_constant("separation", "VSplitContainer", 5)
	theme.set_constant("separation", "HSeparator", 8)
	theme.set_constant("separation", "VSeparator", 8)
	var sep_style := StyleBoxLine.new()
	sep_style.color = border_soft
	sep_style.thickness = 1
	theme.set_stylebox("separator", "HSeparator", sep_style)
	theme.set_stylebox("separator", "VSeparator", sep_style)
	theme.set_stylebox("background", "ProgressBar", solid_panel_style(input_bg, border_soft, 2))
	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = accent
	fill_style.set_corner_radius_all(2)
	theme.set_stylebox("fill", "ProgressBar", fill_style)
	var groove := StyleBoxFlat.new()
	groove.bg_color = border
	groove.set_corner_radius_all(2)
	groove.content_margin_top = 3.0
	groove.content_margin_bottom = 3.0
	theme.set_stylebox("slider", "HSlider", groove)
	var grabber_area := StyleBoxFlat.new()
	grabber_area.bg_color = accent
	grabber_area.set_corner_radius_all(2)
	grabber_area.content_margin_top = 3.0
	grabber_area.content_margin_bottom = 3.0
	theme.set_stylebox("grabber_area", "HSlider", grabber_area)
	theme.set_stylebox("grabber_area_highlight", "HSlider", grabber_area)
	theme.set_color("font_color", "SpinBox", text_strong)

	# 蓝图画布：网格线跟随皮肤，选中框用强调色半透明。
	theme.set_stylebox("panel", "GraphEdit", panel_style(bg, border, 0))
	theme.set_color("grid_minor", "GraphEdit", border_soft)
	theme.set_color("grid_major", "GraphEdit", border)
	theme.set_color("selection_fill", "GraphEdit", Color(accent, 0.14))
	theme.set_color("selection_stroke", "GraphEdit", accent)
	theme.set_stylebox("panel", "GraphNode", solid_panel_style(panel_alt, border, 4))
	theme.set_stylebox("panel_selected", "GraphNode", solid_panel_style(panel_alt, accent, 4))
	theme.set_stylebox("titlebar", "GraphNode", solid_panel_style(bar, border, 4))
	theme.set_stylebox("titlebar_selected", "GraphNode", solid_panel_style(selected, accent, 4))
	theme.set_color("title_color", "GraphNode", text_strong)
	theme.set_color("title_color_selected", "GraphNode", text_strong)
	theme.set_color("close_color", "GraphNode", muted)
	theme.set_color("resizer_color", "GraphNode", muted)

	theme.set_constant("separation", "HBoxContainer", 6)
	theme.set_constant("separation", "VBoxContainer", 6)
	theme.set_constant("h_separation", "GridContainer", 6)
	theme.set_constant("v_separation", "GridContainer", 4)
	return theme


# ---- 控件工厂（插件可覆盖以换成完全不同的控件体系） ----

func label(text_value: String, font_size: int = 12, color: Color = muted) -> Label:
	var node := Label.new()
	node.text = text_value
	node.add_theme_font_size_override("font_size", font_size)
	node.add_theme_color_override("font_color", color)
	return node


func strong(text_value: String, font_size: int = 13) -> Label:
	return label(text_value, font_size, text_strong)


func wrapped(text_value: String, font_size: int = 11, color: Color = muted) -> Label:
	var node := label(text_value, font_size, color)
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return node


func button(text_value: String, font_size: int = 12, height: float = 26.0) -> Button:
	var node := Button.new()
	node.text = text_value
	node.custom_minimum_size = Vector2(0, height)
	node.focus_mode = Control.FOCUS_NONE
	node.add_theme_font_size_override("font_size", font_size)
	return node


func flat_button(text_value: String, tooltip: String = "", font_size: int = 11) -> Button:
	var node := Button.new()
	node.text = text_value
	node.flat = true
	node.tooltip_text = tooltip
	node.custom_minimum_size = Vector2(22, 22)
	node.focus_mode = Control.FOCUS_NONE
	node.add_theme_font_size_override("font_size", font_size)
	return node


func hsep(expand: bool = false) -> Control:
	var node := VSeparator.new()
	if expand:
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return node


func spacer(width: float = 0.0, expand: bool = false) -> Control:
	var node := Control.new()
	node.custom_minimum_size.x = width
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return node
