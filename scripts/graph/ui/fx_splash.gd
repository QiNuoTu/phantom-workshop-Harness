class_name FxSplash
extends Control
## 启动页：在界面搭起来之前就出现，逐条显示 FxBoot 的进度与当前加载项。
##
## 启动期还没有任何插件面板，所以这一层属于基座 chrome，只依赖 FxBoot 的
## 纯数据事件；换一套皮肤时 `FxUiKit` 的颜色会经 theme 自动生效。

var _bar: ProgressBar
var _current: Label
var _count: Label
var _error: Label
var _title: Label
var _hidden: bool = false


static func install(host: Control) -> FxSplash:
	var splash := FxSplash.new()
	splash.name = "BootSplash"
	host.add_child(splash)
	splash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	splash.mouse_filter = Control.MOUSE_FILTER_STOP
	splash._build()
	FxBoot.listen(Callable(splash, "_on_boot"))
	return splash


func _build() -> void:
	var background := ColorRect.new()
	background.color = Color(0.09, 0.10, 0.12, 1.0)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(520, 210)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 28)
	pad.add_theme_constant_override("margin_right", 28)
	pad.add_theme_constant_override("margin_top", 24)
	pad.add_theme_constant_override("margin_bottom", 24)
	card.add_child(pad)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	pad.add_child(column)

	_title = Label.new()
	_title.text = FxI18n.text("幻像工坊")
	_title.add_theme_font_size_override("font_size", 26)
	_title.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG)
	column.add_child(_title)

	var version := Label.new()
	version.text = "%s · %s" % [FxI18n.text("插件化特效工作台"), "Godot " + String(Engine.get_version_info().get("string", ""))]
	version.add_theme_font_size_override("font_size", 11)
	version.add_theme_color_override("font_color", FxUiKit.MUTED)
	column.add_child(version)

	column.add_child(HSeparator.new())

	_current = Label.new()
	_current.text = FxI18n.text("正在启动…")
	_current.add_theme_font_size_override("font_size", 13)
	_current.add_theme_color_override("font_color", FxUiKit.TEXT)
	_current.clip_text = true
	_current.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(_current)

	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 0.0
	_bar.custom_minimum_size = Vector2(0, 8)
	column.add_child(_bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_count = Label.new()
	_count.text = "0 / 0"
	_count.add_theme_font_size_override("font_size", 11)
	_count.add_theme_color_override("font_color", FxUiKit.MUTED)
	_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_count)
	_error = Label.new()
	_error.text = ""
	_error.add_theme_font_size_override("font_size", 11)
	_error.add_theme_color_override("font_color", FxUiKit.DANGER)
	row.add_child(_error)
	column.add_child(row)


func _on_boot(event: Dictionary) -> void:
	if _hidden or not is_instance_valid(_bar):
		return
	var kind := String(event.get("kind", ""))
	if kind == "step":
		_current.text = String(event.get("current", ""))
		_count.text = "%d / %d" % [int(event.get("done", 0)), int(event.get("total", 0))]
		var ratio := float(event.get("ratio", -1.0))
		_bar.value = clampf(ratio, 0.0, 1.0) if ratio >= 0.0 else 0.0
	elif kind == "error":
		_error.text = "%s：%s" % [String(event.get("where", "")), String(event.get("message", ""))]
	elif kind == "finish":
		_count.text = FxBoot.summary()
		_bar.value = 1.0


## 启动页淡出：等两帧，让最后一格进度真的画出来再收。
func finish() -> void:
	_hidden = true
	_fade.call_deferred()


func _fade() -> void:
	if not is_inside_tree():
		queue_free()
		return
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.25)
	tween.tween_callback(queue_free)
