extends RefCounted
## 抠像台：**点画面取色**，把颜色写进当前选中的抠像节点。
##
## 给美工的工作流是三步：选中抠像节点 → 在画面上点一下绿布 → 看着蒙版调黑点白点。
## 没有这个面板时，第一步之后要在取色器弹窗里翻色轮、猜色号，
## 而"绿布到底是哪个绿"本来一眼就能看出来。
##
## 它只用公开契约：`render.last_image()`（当前帧）与
## `store.apply_param()`（可撤销的写入）。不认识任何具体节点类型以外的内部结构，
## 停用 fx.keying 时这个面板随之消失。

## 本插件的节点里，哪些参数是"键色"。
## 面板只认这里列出的参数名，因此新增节点时改这一行即可，不用改面板逻辑。
const KEY_PARAMS := ["screen", "target"]


static func build(ctx: Dictionary) -> Control:
	var state := {"image": null, "node_id": "", "param_id": "", "color": Color(0, 1, 0, 1)}

	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 6)
	panel.custom_minimum_size = Vector2(240, 300)

	var head := Label.new()
	head.text = "抠像台 · 点画面取色"
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", FxUiKit.TEXT_STRONG)
	panel.add_child(head)

	var picker_row := HBoxContainer.new()
	picker_row.add_theme_constant_override("separation", 4)
	panel.add_child(picker_row)
	var target := OptionButton.new()
	target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target.custom_minimum_size = Vector2(0, 22)
	target.tooltip_text = "要写入哪个抠像节点（默认跟随棋盘上选中的那个）"
	picker_row.add_child(target)
	var rescan := Button.new()
	rescan.text = "刷新"
	rescan.tooltip_text = "重新读一遍当前工程里的抠像节点"
	rescan.custom_minimum_size = Vector2(44, 22)
	picker_row.add_child(rescan)

	var canvas := TextureRect.new()
	canvas.custom_minimum_size = Vector2(0, 150)
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	canvas.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	canvas.tooltip_text = "在画面上点一下：取 3×3 平均色写入键色"
	panel.add_child(canvas)

	var swatch_row := HBoxContainer.new()
	swatch_row.add_theme_constant_override("separation", 6)
	panel.add_child(swatch_row)
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(28, 22)
	swatch_row.add_child(swatch)
	var readout := Label.new()
	readout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	readout.add_theme_font_size_override("font_size", 11)
	readout.add_theme_color_override("font_color", FxUiKit.TEXT)
	swatch_row.add_child(readout)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	panel.add_child(actions)
	var auto := Button.new()
	auto.text = "自动选键色"
	auto.tooltip_text = "取画面四角与中心的平均色，选最饱和的一个当键色"
	auto.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(auto)

	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", FxUiKit.MUTED)
	hint.text = "没有画面时先让预览跑一帧；写入走文档撤销栈，Ctrl+Z 可回退。"
	panel.add_child(hint)

	# ---- 行为 ----

	var store: Variant = ctx.get("store")
	var render: Variant = ctx.get("render")

	var refresh_image := func() -> void:
		if render == null or not (render as Object).has_method("last_image"):
			return
		var image: Variant = render.call("last_image")
		if not image is Image:
			return
		state["image"] = image
		canvas.texture = ImageTexture.create_from_image(image)

	var scan_nodes := func() -> void:
		target.clear()
		if store == null:
			return
		var doc: Dictionary = store.get("doc")
		for raw in doc.get("nodes", []):
			if not raw is Dictionary:
				continue
			var node: Dictionary = raw
			var def: FxNodeDef = FxCatalog.def(node.get("type", ""))
			if def == null or def.owner_plugin != "fx.keying":
				continue
			var param_id := ""
			for candidate in KEY_PARAMS:
				if def.param(String(candidate)).is_empty():
					continue
				param_id = String(candidate)
				break
			if param_id.is_empty():
				continue
			var index := target.item_count
			target.add_item("%s（%s）" % [String(def.label), String(node.get("id", ""))])
			target.set_item_metadata(index, {"node": String(node.get("id", "")), "param": param_id})
		if target.item_count == 0:
			target.add_item("（本工程还没有抠像节点）")
			target.set_item_metadata(0, {})

	var sync_selection := func() -> void:
		if store == null:
			return
		var selected := String(store.get("selected_id"))
		if selected.is_empty():
			return
		for i in range(target.item_count):
			var meta: Variant = target.get_item_metadata(i)
			if meta is Dictionary and String((meta as Dictionary).get("node", "")) == selected:
				target.select(i)
				return

	var write_color := func(color: Color) -> void:
		var meta: Variant = target.get_item_metadata(target.selected)
		if not meta is Dictionary or (meta as Dictionary).is_empty():
			hint.text = "先选一个抠像节点（或在上方下拉里挑一个）。"
			return
		var node_id := String((meta as Dictionary).get("node", ""))
		var param_id := String((meta as Dictionary).get("param", ""))
		if store == null or node_id.is_empty() or param_id.is_empty():
			return
		state["color"] = color
		store.call("apply_param", node_id, param_id, "#" + color.to_html(false))
		swatch.color = color
		readout.text = "键色 #%s  →  %s" % [color.to_html(false), node_id]
		hint.text = "已写入 %s 的「键色」；接着调黑点/白点看蒙版。" % node_id

	var sample_avg := func(px: int, py: int) -> Color:
		var image: Image = state["image"]
		if image == null:
			return Color(0, 1, 0, 1)
		var sum := Color(0, 0, 0, 1)
		var count := 0
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var x: int = clampi(px + dx, 0, image.get_width() - 1)
				var y: int = clampi(py + dy, 0, image.get_height() - 1)
				var c := image.get_pixel(x, y)
				sum.r += c.r
				sum.g += c.g
				sum.b += c.b
				count += 1
		if count <= 0:
			return Color(0, 1, 0, 1)
		return Color(sum.r / float(count), sum.g / float(count), sum.b / float(count), 1.0)

	var pick_at := func(local: Vector2) -> void:
		var image: Image = state["image"]
		if image == null or canvas.size.x <= 0.0 or canvas.size.y <= 0.0:
			return
		var tex_size := Vector2(image.get_width(), image.get_height())
		var scale := minf(canvas.size.x / maxf(tex_size.x, 1.0),
			canvas.size.y / maxf(tex_size.y, 1.0))
		var draw := tex_size * scale
		var origin := (canvas.size - draw) * 0.5
		var p := (local - origin) / maxf(scale, 0.0001)
		if p.x < 0.0 or p.y < 0.0 or p.x >= tex_size.x or p.y >= tex_size.y:
			return
		write_color.call(sample_avg.call(int(p.x), int(p.y)))

	canvas.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var click := event as InputEventMouseButton
			if click.button_index == MOUSE_BUTTON_LEFT and click.pressed:
				pick_at.call(click.position)
	)

	auto.pressed.connect(func() -> void:
		var image: Image = state["image"]
		if image == null:
			hint.text = "还没有画面：先让预览算一帧。"
			return
		var w := image.get_width()
		var h := image.get_height()
		var points := [
			Vector2i(2, 2), Vector2i(w - 3, 2), Vector2i(2, h - 3),
			Vector2i(w - 3, h - 3), Vector2i(w / 2, h / 2),
		]
		var best := Color(0, 1, 0, 1)
		var best_score := -1.0
		for point in points:
			var c: Color = sample_avg.call((point as Vector2i).x, (point as Vector2i).y)
			# 键色的特征通常是「饱和度高」：取 HSV 的 s×v 作为打分。
			var score := c.s * maxf(c.v, 0.05)
			if score > best_score:
				best_score = score
				best = c
		write_color.call(best)
		hint.text = "自动选色：%s（饱和 %.2f）。不准就点画面自己取。" % [
			"#" + best.to_html(false), best.s]
	)

	rescan.pressed.connect(func() -> void:
		scan_nodes.call()
		sync_selection.call()
		refresh_image.call()
	)

	target.item_selected.connect(func(_index: int) -> void:
		var meta: Variant = target.get_item_metadata(target.selected)
		if meta is Dictionary and not (meta as Dictionary).is_empty():
			state["node_id"] = String((meta as Dictionary).get("node", ""))
	)

	# 预览出新帧时跟着换图：抠像时看到的就是"当前这一帧"。
	var on_rendered := func(image: Image, _stats: Dictionary) -> void:
		if image == null or not is_instance_valid(canvas):
			return
		state["image"] = image
		canvas.texture = ImageTexture.create_from_image(image)
	if render != null and (render as Object).has_signal("rendered"):
		(render as Object).connect("rendered", on_rendered)
		panel.tree_exiting.connect(func() -> void:
			if render != null and is_instance_valid(render) and (render as Object).is_connected("rendered", on_rendered):
				(render as Object).disconnect("rendered", on_rendered)
		)

	scan_nodes.call()
	sync_selection.call()
	refresh_image.call()
	return panel
