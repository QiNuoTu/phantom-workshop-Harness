class_name FxPixelfxWidget
extends RefCounted
## pixelfx 素材参数控件（由 core.asset 插件注册，kind = "pixelfx"）。
## 素材库的搜索/选择逻辑属于素材插件，核心参数面板不需要知道 pixelfx 是什么。

static func build(ctx: Dictionary) -> Dictionary:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 4)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 22)
	edit.placeholder_text = "分类/名称，例如 fire/campfire"
	edit.text = String(ctx["get"].call())
	line.add_child(edit)
	var browse := Button.new()
	browse.text = "库"
	browse.tooltip_text = "从 pixelfx 素材库选择"
	browse.custom_minimum_size = Vector2(26, 22)
	browse.add_theme_font_size_override("font_size", 11)
	line.add_child(browse)

	var commit := func() -> void:
		ctx["set"].call(edit.text.strip_edges())
	edit.text_submitted.connect(func(_text: String) -> void: commit.call())
	edit.focus_exited.connect(func() -> void: commit.call())
	browse.pressed.connect(func() -> void:
		var host: Control = ctx.get("host")
		if host != null:
			_open_library(host, edit, ctx)
	)
	var sync := func() -> void:
		if not edit.has_focus():
			edit.text = String(ctx["get"].call())
	return {"control": line, "sync": sync}


static func _open_library(host: Control, edit: LineEdit, ctx: Dictionary) -> void:
	var dialog := AcceptDialog.new()
	FxUiKit.style_window(dialog)
	dialog.title = "pixelfx 素材库"
	dialog.size = Vector2i(560, 540)
	dialog.ok_button_text = "选择"
	var box := VBoxContainer.new()
	dialog.add_child(box)
	var search := LineEdit.new()
	search.placeholder_text = "搜索名称 / 分类 / id"
	box.add_child(search)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size = Vector2(0, 420)
	box.add_child(list)
	var entries := FxAssetLibrary.all()
	var refresh := func(filter_text: String) -> void:
		list.clear()
		var needle := filter_text.strip_edges().to_lower()
		for item in entries:
			var entry: Dictionary = item
			var haystack := "%s %s %s" % [String(entry.get("name", "")), String(entry.get("id", "")),
				String(entry.get("category", ""))]
			if not needle.is_empty() and not haystack.to_lower().contains(needle):
				continue
			var index := list.add_item("%s   ·   %s" % [String(entry.get("name", "")),
				String(entry.get("id", ""))])
			list.set_item_metadata(index, String(entry.get("id", "")))
	refresh.call("")
	search.text_changed.connect(func(text: String) -> void: refresh.call(text))
	var apply := func() -> void:
		var selected := list.get_selected_items()
		if selected.is_empty():
			return
		var asset_id := String(list.get_item_metadata(selected[0]))
		edit.text = asset_id
		ctx["set"].call(asset_id)
		dialog.queue_free()
	dialog.confirmed.connect(apply)
	list.item_activated.connect(func(_index: int) -> void: apply.call())
	host.add_child(dialog)
	FxUiKit.popup_later(dialog)
