class_name FxShaderDrop
extends RefCounted
## 把 `.gdshader` 拖进蓝图 → 直接落一个着色器节点，路径已经填好。
##
## 契约见 FxDropBroker：只声明扩展名和 handler，蓝图侧完全不知道有这回事。

const COLUMNS := 3
const STEP := Vector2(360, 0)
const ROW_STEP := 150.0


static func handle(ctx: Dictionary) -> Dictionary:
	var store: FxDocumentStore = ctx.get("store") as FxDocumentStore
	if store == null:
		return {"count": 0, "message": "没有打开的图"}
	var files: Array = ctx.get("files", [])
	var origin: Vector2 = ctx.get("position", Vector2.ZERO)
	if origin == Vector2.ZERO:
		origin = Vector2(240, 200)
	var created: Array[String] = []
	store.begin_batch()
	for i in range(files.size()):
		var path := String(files[i])
		if not path.to_lower().ends_with(".gdshader"):
			continue
		var pos := origin + Vector2(float(i % COLUMNS) * STEP.x,
			floor(float(i) / float(COLUMNS)) * ROW_STEP)
		var node := store.add_node("shader.image", "", pos, {"path": path})
		if String(node.get("id", "")).is_empty():
			continue
		created.append(String(node.get("id", "")))
	store.commit_batch()
	if created.is_empty():
		return {"count": 0, "message": "拖入的文件不是 .gdshader"}
	var editor: Variant = ctx.get("editor")
	if editor != null and editor.has_method("select_nodes"):
		editor.call("select_nodes", created)
	else:
		store.set_selection(created[0])
	return {"count": created.size(), "message": "已导入 %d 个着色器节点" % created.size()}
