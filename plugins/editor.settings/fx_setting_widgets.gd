class_name FxSettingWidgets
extends RefCounted
## 设置控件工厂：设置中心与「插件信息 / 插件设置」面板共用同一套声明式表单。
## writer: Callable(id: String, value: Variant) -> void，由调用方决定如何写回。

static func build(entry: Dictionary, writer: Callable) -> Control:
	var id := String(entry.get("id", ""))
	var kind := String(entry.get("kind", "string"))
	var current: Variant = FxSettings.value(id)
	match kind:
		"bool":
			var check := CheckBox.new()
			check.text = FxI18n.text("启用")
			check.set_pressed_no_signal(bool(current))
			check.toggled.connect(func(value: bool) -> void: writer.call(id, value))
			return check
		"int", "float":
			var spin := SpinBox.new()
			spin.min_value = float(entry.get("min", -99999.0))
			spin.max_value = float(entry.get("max", 99999.0))
			spin.step = float(entry.get("step", 1.0 if kind == "int" else 0.01))
			spin.set_value_no_signal(float(current))
			spin.value_changed.connect(func(value: float) -> void:
				writer.call(id, int(round(value)) if kind == "int" else value)
			)
			return spin
		"enum":
			var option := OptionButton.new()
			var options: Array = entry.get("options", [])
			var index := 0
			for i in range(options.size()):
				var item: Variant = options[i]
				var value: Variant = item.get("value", "") if item is Dictionary else item
				var text := str(item.get("label", value)) if item is Dictionary else str(item)
				option.add_item(FxI18n.text(text))
				option.set_item_metadata(i, value)
				if value == current or str(value) == str(current):
					index = i
			option.select(index)
			option.item_selected.connect(func(i: int) -> void:
				writer.call(id, option.get_item_metadata(i))
			)
			return option
		"action":
			# 按钮型设置没有「值」：点一下执行声明里的零参数动作。
			var button := Button.new()
			button.text = FxI18n.text(String(entry.get("button", entry.get("label", "执行"))))
			button.custom_minimum_size = Vector2(0, 26)
			var action: Callable = entry.get("action", Callable())
			button.pressed.connect(func() -> void:
				if action.is_valid():
					action.call()
			)
			return button
		"color":
			var picker := ColorPickerButton.new()
			picker.color = Color.from_string(str(current), Color.WHITE)
			picker.custom_minimum_size = Vector2(0, 26)
			picker.color_changed.connect(func(color: Color) -> void:
				writer.call(id, "#" + color.to_html(false))
			)
			return picker
		_:
			var edit := LineEdit.new()
			edit.text = str(current)
			edit.text_changed.connect(func(text: String) -> void: writer.call(id, text))
			return edit


static func row(entry: Dictionary, writer: Callable) -> Control:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	var label := FxUiKit.label(FxI18n.text(String(entry.get("label", entry.get("id", "")))), 11)
	label.custom_minimum_size = Vector2(140, 0)
	line.add_child(label)
	var control := build(entry, writer)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(control)
	return line
