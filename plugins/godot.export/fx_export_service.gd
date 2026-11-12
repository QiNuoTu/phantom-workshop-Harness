class_name FxExportService
extends RefCounted
## 导出服务：当前帧 / PNG 序列 / 精灵表（PNG + Aseprite JSON）。
##
## 被“Godot 导出”插件与粒子导出复用；不依赖任何 UI，可在无头模式跑。
## 所有导出都使用 quality = 1 的执行器，保证与最终画面一致，不做预览降采样。

static func timeline_of(doc: Dictionary) -> Dictionary:
	var timeline := FxGraphDoc.timeline(doc)
	return {
		"fps": clampi(int(timeline.get("fps", 30)), 1, 120),
		"duration": maxf(0.001, float(timeline.get("duration", 1.0))),
		"loop": bool(timeline.get("loop", true)),
	}


static func frame_count(doc: Dictionary) -> int:
	var info := timeline_of(doc)
	return maxi(1, int(round(float(info["duration"]) * float(info["fps"]))))


static func safe_stem(doc: Dictionary) -> String:
	var name := String(FxGraphDoc.meta_value(doc, "name", "image"))
	for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", " "]:
		name = name.replace(ch, "_")
	return name if not name.is_empty() else "image"


static func save_frame(doc: Dictionary, path: String, at_time: float = 0.0) -> Dictionary:
	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	var image: Image = runner.run(doc, at_time).get("image")
	if image == null:
		return {"ok": false, "message": "当前没有输出图像"}
	var err := image.save_png(path)
	if err != OK:
		return {"ok": false, "message": "写入失败：%s" % error_string(err)}
	return {"ok": true, "message": "已导出当前帧：%s" % path.get_file(), "files": [path]}


static func save_sequence(doc: Dictionary, dir_path: String) -> Dictionary:
	var info := timeline_of(doc)
	var fps := int(info["fps"])
	var count := frame_count(doc)
	DirAccess.make_dir_recursive_absolute(dir_path)
	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	var stem := safe_stem(doc)
	var written: Array[String] = []
	for i in range(count):
		var image: Image = runner.run(doc, float(i) / float(fps)).get("image")
		if image == null:
			break
		var path := dir_path.path_join("%s_%04d.png" % [stem, i])
		if image.save_png(path) == OK:
			written.append(path)
	return {
		"ok": not written.is_empty(),
		"message": "导出序列帧：%d / %d 帧 → %s" % [written.size(), count, dir_path],
		"files": written,
	}


## 渲染整段动画并拼成精灵表。返回 {ok, image, columns, rows, frames, frame_size, fps, loop}。
static func build_sheet(doc: Dictionary) -> Dictionary:
	var info := timeline_of(doc)
	var fps := int(info["fps"])
	var count := frame_count(doc)
	var runner := FxGraphRunner.new()
	runner.capture_previews = false
	var frames: Array[Image] = []
	for i in range(count):
		var image: Image = runner.run(doc, float(i) / float(fps)).get("image")
		if image == null:
			break
		frames.append(image)
	if frames.is_empty():
		return {"ok": false, "message": "当前没有输出图像"}
	var frame_size := frames[0].get_size()
	var columns := maxi(1, int(ceil(sqrt(float(frames.size())))))
	var rows := int(ceil(float(frames.size()) / float(columns)))
	var sheet := Image.create_empty(columns * frame_size.x, rows * frame_size.y, false,
		Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for i in range(frames.size()):
		var x := (i % columns) * frame_size.x
		var y := int(i / columns) * frame_size.y
		sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, frame_size), Vector2i(x, y))
	return {
		"ok": true,
		"image": sheet,
		"columns": columns,
		"rows": rows,
		"frames": frames.size(),
		"frame_size": frame_size,
		"fps": fps,
		"loop": bool(info["loop"]),
	}


static func save_sheet(doc: Dictionary, path: String) -> Dictionary:
	var built := build_sheet(doc)
	if not bool(built.get("ok", false)):
		return built
	var sheet: Image = built["image"]
	var err := sheet.save_png(path)
	if err != OK:
		return {"ok": false, "message": "精灵表写入失败：%s" % error_string(err)}
	var frame_size: Vector2i = built["frame_size"]
	var columns := int(built["columns"])
	var fps := int(built["fps"])
	var count := int(built["frames"])
	var stem := safe_stem(doc)
	var rects: Array = []
	for i in range(count):
		var x := (i % columns) * frame_size.x
		var y := int(i / columns) * frame_size.y
		rects.append({
			"filename": "%s %d" % [stem, i],
			"frame": {"x": x, "y": y, "w": frame_size.x, "h": frame_size.y},
			"rotated": false, "trimmed": false,
			"spriteSourceSize": {"x": 0, "y": 0, "w": frame_size.x, "h": frame_size.y},
			"sourceSize": {"w": frame_size.x, "h": frame_size.y},
			"duration": int(round(1000.0 / float(fps))),
		})
	var payload := {
		"frames": rects,
		"meta": {
			"app": "幻像工坊",
			"version": "1",
			"image": path.get_file(),
			"format": "RGBA8888",
			"size": {"w": sheet.get_width(), "h": sheet.get_height()},
			"scale": "1",
			"pixelfx": {
				"id": stem,
				"name": String(FxGraphDoc.meta_value(doc, "name", "幻像工坊")),
				"fps": fps,
				"loop": bool(built["loop"]),
				"frames": count,
				"frameSize": [frame_size.x, frame_size.y],
				"pivot": [frame_size.x / 2, frame_size.y / 2],
				"columns": columns,
			},
		},
	}
	var json_path := path.get_basename() + ".json"
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t"))
		file.close()
	return {
		"ok": true,
		"message": "已导出精灵表：%d 帧 · %d 列 → %s" % [count, columns, path.get_file()],
		"files": [path, json_path],
	}


# ================= 导出器入口（静态 Callable，插件只引用这些） =================

static func handler_frame(ctx: Dictionary) -> Dictionary:
	return save_frame(ctx["doc"], String(ctx["path"]), float(ctx.get("time", 0.0)))


static func handler_sequence(ctx: Dictionary) -> Dictionary:
	return save_sequence(ctx["doc"], String(ctx["path"]))


static func handler_sheet(ctx: Dictionary) -> Dictionary:
	return save_sheet(ctx["doc"], String(ctx["path"]))


static func handler_particles(ctx: Dictionary) -> Dictionary:
	var options: Dictionary = ctx.get("options", {})
	if options.is_empty():
		# 没有预填选项时，由导出插件自己弹选项框；外壳只提供父节点与状态栏。
		var shell: Variant = ctx.get("shell", ctx.get("editor"))
		if not (shell is Node):
			return {"ok": false, "message": "没有可用的界面上下文"}
		var host := shell as Node
		var doc: Dictionary = ctx["doc"]
		var path := String(ctx["path"])
		var dialog := FxParticleExportDialog.new()
		host.add_child(dialog)
		dialog.setup(doc, path)
		dialog.export_requested.connect(func(chosen: Dictionary) -> void:
			var result := FxParticleExport.export(doc, path, chosen)
			if host.has_method("status"):
				host.call("status", String(result.get("message", "")))
			dialog.queue_free()
		)
		dialog.canceled.connect(func() -> void: dialog.queue_free())
		FxUiKit.popup_later(dialog)
		return {"ok": true, "message": "已打开粒子导出选项"}
	return FxParticleExport.export(ctx["doc"], String(ctx["path"]), options)


# ================= 命令入口（静态，供插件注册） =================

static func _open_dialog(ctx: Dictionary, exporter_id: String) -> void:
	var shell: Variant = ctx.get("shell")
	if shell != null and shell.has_method("export_dialog"):
		shell.call("export_dialog", exporter_id)


static func cmd_frame(ctx: Dictionary) -> void:
	_open_dialog(ctx, "png.frame")


static func cmd_sequence(ctx: Dictionary) -> void:
	_open_dialog(ctx, "png.sequence")


static func cmd_sheet(ctx: Dictionary) -> void:
	_open_dialog(ctx, "png.sheet")


static func cmd_particles(ctx: Dictionary) -> void:
	_open_dialog(ctx, "godot.particles")
