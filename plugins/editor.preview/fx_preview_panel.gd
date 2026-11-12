class_name FxPreviewPanel
extends Control
## 输出预览面板（插件 editor.preview 提供）。
##
## 只订阅 FxRenderService.rendered，不自己跑执行器。棋盘背景 + 适应/1:1 两种视图，
## 底部显示画布、时长、帧率与实测耗时。

var shell: FxShell
var store: FxDocumentStore
var render: FxRenderService
var preview_rect: TextureRect

var _info: Label
var _texture: ImageTexture
var _fit_button: Button
var _pixel_button: Button


static func create(ctx: Dictionary) -> Control:
	var panel := FxPreviewPanel.new()
	panel.setup(ctx)
	return panel


func setup(ctx: Dictionary) -> void:
	shell = ctx.get("shell")
	store = ctx.get("store")
	render = ctx.get("render")
	name = "PreviewPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	if render != null:
		render.rendered.connect(_on_rendered)
		render.stats_changed.connect(_on_stats)
		if render.last_image() != null:
			_on_rendered(render.last_image(), render.last_stats())
	elif store != null and store.doc.get("nodes", []).is_empty():
		pass


func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := FxUiKit.strong("输出预览", 12)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_fit_button = FxUiKit.flat_button("适应", "缩放显示整张图", 10)
	_fit_button.toggle_mode = true
	_fit_button.set_pressed_no_signal(true)
	header.add_child(_fit_button)
	_pixel_button = FxUiKit.flat_button("1:1", "按像素显示（可裁切）", 10)
	_pixel_button.toggle_mode = true
	header.add_child(_pixel_button)
	_fit_button.toggled.connect(func(pressed: bool) -> void:
		if pressed:
			_pixel_button.set_pressed_no_signal(false)
			preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	)
	_pixel_button.toggled.connect(func(pressed: bool) -> void:
		if pressed:
			_fit_button.set_pressed_no_signal(false)
			preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	)

	var stage := Control.new()
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.custom_minimum_size = Vector2(0, 220)
	stage.clip_contents = true
	root.add_child(stage)

	var checker := TextureRect.new()
	checker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	checker.texture = _make_checker()
	checker.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	checker.stretch_mode = TextureRect.STRETCH_TILE
	checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(checker)

	preview_rect = TextureRect.new()
	preview_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(preview_rect)

	_info = FxUiKit.label("等待渲染…", 11, FxUiKit.MUTED)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_info)


func _make_checker() -> ImageTexture:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	image.fill(FxUiKit.PANEL)
	image.fill_rect(Rect2i(0, 0, 8, 8), FxUiKit.PANEL_ALT)
	image.fill_rect(Rect2i(8, 8, 8, 8), FxUiKit.PANEL_ALT)
	return ImageTexture.create_from_image(image)


func _on_rendered(image: Image, _stats: Dictionary) -> void:
	if image == null:
		preview_rect.texture = null
		return
	if _texture != null and _texture.get_width() == image.get_width() \
			and _texture.get_height() == image.get_height():
		_texture.update(image)
	else:
		_texture = ImageTexture.create_from_image(image)
		preview_rect.texture = _texture
	_update_info(image.get_size(), render.last_stats())


func _on_stats(stats: Dictionary) -> void:
	_update_info(_texture.get_size() if _texture != null else Vector2i.ZERO, stats)


func _update_info(size: Vector2i, stats: Dictionary) -> void:
	if _info == null:
		return
	var doc := store.doc if store != null else {}
	var timeline := FxGraphDoc.timeline(doc)
	var parts: Array[String] = []
	if size.x > 0:
		parts.append("%d × %d" % [size.x, size.y])
	parts.append("%.2fs" % float(timeline.get("duration", 1.0)))
	parts.append("%d fps" % int(timeline.get("fps", 30)))
	if not stats.is_empty():
		parts.append("%.1f ms" % float(stats.get("ms", 0.0)))
	_info.text = " · ".join(parts)
