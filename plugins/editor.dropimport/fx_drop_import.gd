class_name FxDropImport
extends RefCounted
## 拖进蓝图的图片 → 纹理节点；按住 Shift 拖 → 精灵表节点。
##
## 位置由蓝图给出（图坐标），这里只负责「文件 → 节点参数」的映射：
## 图片读得到尺寸就顺手猜一下网格（正方形帧的精灵表很常见），猜错也只是参数不同，
## 用户在精灵表节点上改列数/行数/单元尺寸即可。
##
## 硬性规则：这里的函数都是静态的，注册表会长期持有 Callable。

const EXTENSIONS := ["png", "webp", "jpg", "jpeg", "bmp", "tga", "svg"]
## 多个文件落下来时的排布：每行 3 个，避免一条长蛇。
const COLUMNS := 3
const STEP := Vector2(360, 0)
const ROW_STEP := 150.0
const MAX_GUESS_CELL := 512


## 蓝图拖拽入口。
static func handle(ctx: Dictionary) -> Dictionary:
	var store: FxDocumentStore = ctx.get("store") as FxDocumentStore
	if store == null:
		return {"count": 0, "message": "没有打开的图"}
	var files: Array = ctx.get("files", [])
	var origin: Vector2 = ctx.get("position", Vector2.ZERO)
	if origin == Vector2.ZERO:
		origin = Vector2(200, 200)
	var as_sheet := Input.is_key_pressed(KEY_SHIFT)
	var created: Array[String] = []
	var skipped: Array[String] = []
	store.begin_batch()
	for i in range(files.size()):
		var path := String(files[i])
		if DirAccess.dir_exists_absolute(path):
			# 目录不是一张图：整段序列该由用户挑精灵表文件，不能瞎猜。
			skipped.append(path.get_file())
			continue
		if not is_supported(path):
			skipped.append(path.get_file())
			continue
		var pos := origin + Vector2(float(i % COLUMNS) * STEP.x,
			floor(float(i) / float(COLUMNS)) * ROW_STEP)
		var node := _make_node(store, path, pos, as_sheet)
		if String(node.get("id", "")).is_empty():
			skipped.append(path.get_file())
			continue
		created.append(String(node.get("id", "")))
	store.commit_batch()
	if created.is_empty():
		return {"count": 0, "message": "拖入的文件不是可导入的图片"}
	# 一次落下多个节点时让它们一起选中：接着按 Ctrl+C 就能整组复制。
	var editor = ctx.get("editor")
	if editor != null and editor.has_method("select_nodes"):
		editor.call("select_nodes", created)
	else:
		store.set_selection(created[0])
	var suffix := "（Shift = 精灵表）" if not as_sheet else "（精灵表：列/行已按图片猜，可在参数里改）"
	var message := "已导入 %d 个%s" % [created.size(), suffix]
	if not skipped.is_empty():
		message += "，跳过 %d 个" % skipped.size()
	return {"count": created.size(), "message": message}


## 菜单入口：没有拖拽也能导入（文件对话框选图）。
static func cmd_import(ctx: Dictionary) -> void:
	var shell = ctx.get("shell")
	if shell == null:
		return
	var dialog := FileDialog.new()
	dialog.title = "导入纹理"
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	# 走系统原生面板：多选、收藏夹、网络路径都由系统负责，也不用担心内嵌面板
	# 关闭时的 subwindow 焦点问题。
	dialog.use_native_dialog = true
	dialog.filters = PackedStringArray([
		"*.png, *.webp, *.jpg, *.jpeg, *.bmp, *.tga, *.svg ; 图片",
		"*.* ; 所有文件",
	])
	FxUiKit.style_window(dialog)
	shell.add_child(dialog)
	dialog.files_selected.connect(func(paths: PackedStringArray) -> void:
		var position := Vector2(200, 200)
		var panel = shell.panel("editor.graph")
		if panel != null and panel.has_method("paste_position"):
			position = panel.call("paste_position")
		var result := handle({
			"files": Array(paths),
			"position": position,
			"shell": shell,
			"store": shell.store,
			"editor": panel,
		})
		if not String(result.get("message", "")).is_empty():
			shell.status(String(result.get("message", "")))
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	FxUiKit.popup_later(dialog, "popup_centered_ratio", [0.62])


static func is_supported(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	return EXTENSIONS.has(ext)


static func _make_node(store: FxDocumentStore, path: String, pos: Vector2,
		as_sheet: bool) -> Dictionary:
	var params := {"path": path, "fit": "contain"}
	var node_type := "image.texture"
	if as_sheet:
		node_type = "image.sheet"
		var grid := guess_grid(path)
		params["mode"] = "grid"
		params["columns"] = grid.x
		params["rows"] = grid.y
	return store.add_node(node_type, "", pos, params)


## 猜网格：以最大公因数当作单元边长（96×64 → 32 → 3×2），正方形图当单帧。
## 猜不出来就退回 4×1，用户在精灵表节点上改两下就好。
static func guess_grid(path: String) -> Vector2i:
	var probe := FxTextureLibrary.probe(path)
	if not bool(probe.get("ok", false)):
		return Vector2i(4, 1)
	var size: Vector2i = probe.get("size", Vector2i.ZERO)
	var w := size.x
	var h := size.y
	if w <= 0 or h <= 0:
		return Vector2i(4, 1)
	if w == h:
		return Vector2i(1, 1)
	var cell := _gcd(w, h)
	if cell <= 0 or cell > MAX_GUESS_CELL:
		return Vector2i(4, 1)
	var cols := w / cell
	var rows := h / cell
	if cols * rows < 2 or cols * rows > 1024:
		return Vector2i(4, 1)
	return Vector2i(cols, rows)


static func _gcd(a: int, b: int) -> int:
	var x := absi(a)
	var y := absi(b)
	while y > 0:
		var t := y
		y = x % y
		x = t
	return x
