class_name FxVisualIcon
extends RefCounted
## 图标解析：**字形 / 静态纹理 / 精灵表动图** 三种形态，一级比一级退。
##
## 插件（plugin.json）与节点（nodes*.json）共用这套规则：
##   · `icon` 写 1~2 个字符        → 当字形画（最省事，老插件不用改）
##   · `icon` 写图片路径           → 当纹理读（相对该插件目录）
##   · 再加 `icon_anim: {cols,rows,fps}` → 把这张图当精灵表播动画
##   · 什么都没有 / 读不出来       → 调用方退到分类色块 + 分类字形
##
## 路径解析统一走 FxResourceRoot：工程里读 `res://`，便携版读 exe 旁的 plugins/，
## 所以插件把图标放 `<插件>/assets/` 就能跟着插件一起装卸。

const IMAGE_EXTENSIONS: Array[String] = [".png", ".webp", ".jpg", ".jpeg", ".bmp", ".svg", ".tga"]

## 分类 → 字形。找不到就用首字母，保证永远有东西可画。
const CATEGORY_GLYPHS := {
	"图像/来源": "▣", "图像/处理": "◐", "图像/合成": "◑", "图像/调色": "◒",
	"图像/扭曲": "≈", "图像/生成": "✦", "图像/着色器": "◇", "图像对象": "▤",
	"特效/生成": "✸", "输出": "▢", "数值/逻辑": "#", "动画/曲线": "∿",
	"动画/运动": "↻", "流程": "→", "图属性": "▥", "子图": "⧉",
	"导出与保存": "⤓",
}

static var _textures: Dictionary = {}


static func clear_cache() -> void:
	_textures.clear()


## 这段文字是不是一个图片路径（而不是字形）。字形都很短，路径一定带扩展名。
static func is_image_path(text: String) -> bool:
	if text.is_empty() or text.length() > 260:
		return false
	var lower := text.to_lower()
	for ext in IMAGE_EXTENSIONS:
		if lower.ends_with(ext):
			return true
	return false


## 把 `path` 解析成可读的完整路径。
## base_dir 是「所属插件目录」，形如 `res://plugins/core.image` 或 `plugins/core.image`。
static func resolve(base_dir: String, path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("user://") or path.begins_with("res://"):
		return _resolve_absolute(path)
	if path.is_absolute_path():
		return path if FileAccess.file_exists(path) else ""
	var base := base_dir
	if base.is_empty():
		base = "plugins"
	if base.begins_with("res://"):
		base = base.substr(6)
	return _resolve_absolute(base.path_join(path))


static func _resolve_absolute(path: String) -> String:
	var relative := path
	if relative.begins_with("res://") or relative.begins_with("user://"):
		if FileAccess.file_exists(relative):
			return relative
		if not relative.begins_with("res://"):
			return ""
		relative = relative.substr(6)
	var found := FxResourceRoot.resolve(relative)
	if not found.is_empty():
		return found
	# 退回原路径：编辑器里 res:// 文件能被 load()，没必要因为外部根没找到就放弃。
	return "res://" + relative


## 读一张图（带缓存）。读不出来返回 null，调用方自己回退。
static func texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _textures.has(path):
		return _textures[path] as Texture2D
	var made: Texture2D = null
	if ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is Texture2D:
			made = res as Texture2D
	if made == null:
		var image := image_of(path)
		if image != null:
			made = ImageTexture.create_from_image(image)
	_textures[path] = made
	return made


## 原始像素（动图需要按帧切，所以单独给一个入口）。
static func image_of(path: String) -> Image:
	if path.is_empty():
		return null
	var global := path
	if path.begins_with("res://") or path.begins_with("user://"):
		if not FileAccess.file_exists(path):
			return null
		global = ProjectSettings.globalize_path(path)
	elif not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	var err := image.load(global)
	if err != OK:
		# 可能是 PCK 内的虚拟路径：退回资源加载器。
		if ResourceLoader.exists(path):
			var res: Variant = load(path)
			if res is Texture2D:
				return (res as Texture2D).get_image()
		return null
	return image


## 精灵表参数归一化：cols 写 0 时按「正方形帧」自动推列数。
## 返回 {cols, rows, count, fps}；anim 为空表示静帧（count = 1）。
static func frames(anim: Dictionary, image_size: Vector2i) -> Dictionary:
	var out := {"cols": 1, "rows": 1, "count": 1, "fps": 0.0, "animated": false}
	if anim.is_empty() or image_size.x <= 0 or image_size.y <= 0:
		return out
	var rows := maxi(1, int(anim.get("rows", 1)))
	var cols := int(anim.get("cols", 1))
	if cols <= 0:
		var cell := maxi(1, image_size.y / rows)
		cols = maxi(1, image_size.x / cell)
	cols = maxi(1, cols)
	out["cols"] = cols
	out["rows"] = rows
	out["count"] = cols * rows
	out["fps"] = maxf(1.0, float(anim.get("fps", 8.0)))
	out["animated"] = int(out["count"]) > 1
	return out


## 第 index 帧在原图里的矩形。
static func frame_rect(index: int, grid: Dictionary, image_size: Vector2i) -> Rect2:
	var cols := maxi(1, int(grid.get("cols", 1)))
	var rows := maxi(1, int(grid.get("rows", 1)))
	var count := cols * rows
	var i := posmod(index, maxi(1, count))
	var cw := float(image_size.x) / float(cols)
	var ch := float(image_size.y) / float(rows)
	return Rect2(Vector2(float(i % cols) * cw, float(i / cols) * ch), Vector2(cw, ch))


## 分类的稳定配色（同一分类永远同一个颜色，跨插件也一致）。
static func category_color(key: String) -> Color:
	if key.is_empty():
		return FxUiKit.MUTED
	var seed := 0
	for i in range(key.length()):
		seed = (seed * 131 + key.unicode_at(i)) % 100003
	var hue := float(seed % 360) / 360.0
	return Color.from_hsv(hue, 0.46, 0.72)


static func category_glyph(key: String) -> String:
	if CATEGORY_GLYPHS.has(key):
		return String(CATEGORY_GLYPHS[key])
	if key.is_empty():
		return "◇"
	return key.substr(key.find("/") + 1 if key.contains("/") else 0, 1).to_upper()


## 分类色块：纹理缺失时的兜底视觉。返回一个可直接放进卡片的 Control。
static func swatch(color: Color, glyph: String, size_px: Vector2, font_px: int = 26) -> Control:
	var holder := PanelContainer.new()
	holder.custom_minimum_size = size_px
	holder.clip_contents = true
	var gradient := Gradient.new()
	gradient.set_color(0, Color(color, 0.34))
	gradient.set_color(1, Color(color.darkened(0.55), 0.20))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(1.0, 1.0)
	var style := StyleBoxTexture.new()
	style.texture = texture
	holder.add_theme_stylebox_override("panel", style)
	var label := FxUiKit.strong(glyph, font_px)
	label.add_theme_color_override("font_color", Color(color.lightened(0.42), 0.95))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(label)
	return holder
