class_name FxParticleExport
extends RefCounted
## Godot 原生粒子发生器导出（GPUParticles2D + 翻转书贴图）。
##
## 三种贴图来源：
##   sheet    渲染整段动画 → 精灵表，粒子按帧播放（默认）
##   frame    只取当前帧 → 单帧纹理，适合火星/碎片这类静态贴图
##   texture  直接使用外部 PNG/精灵表，可指定列×行
##
## 输出：<stem>.tscn + <stem>_tex.res（内嵌贴图）+ 精灵表 PNG/JSON（sheet 模式）。
## 场景不依赖本工具，拖进任意 Godot 4 项目即可播放。

const SHAPES := {
	"point": 0,
	"sphere": 1,
	"sphere_surface": 2,
	"box": 3,
	"ring": 6,
}

const DEFAULTS := {
	"source": "sheet",
	"texture": "",
	"columns": 0,
	"rows": 0,
	"time": 0.0,
	"amount": 1,
	"lifetime": 0.0,
	"explosiveness": 0.0,
	"randomness": 0.0,
	"one_shot": false,
	"fixed_fps": 0,
	"emission_shape": "point",
	"emission_radius": 12.0,
	"box_extents": 16.0,
	"ring_radius": 24.0,
	"direction": [0.0, -1.0],
	"spread": 0.0,
	"gravity": [0.0, 0.0],
	"initial_velocity": 0.0,
	"scale_min": 1.0,
	"scale_max": 1.0,
	"anim_speed": 1.0,
	"texture_filter": 1,
	"local_coords": false,
	"name": "FxEmitter",
}


static func export(doc: Dictionary, scene_path: String, options: Dictionary = {}) -> Dictionary:
	var opts := DEFAULTS.duplicate(true)
	for key in options.keys():
		opts[key] = options[key]
	var stem := scene_path.get_basename()
	var texture: Image = null
	var columns := 1
	var rows := 1
	var files: Array[String] = []
	var source := String(opts.get("source", "sheet"))

	if source == "texture":
		var texture_path := String(opts.get("texture", ""))
		if texture_path.is_empty():
			return {"ok": false, "message": "外部纹理路径为空"}
		texture = _load_texture(texture_path)
		if texture == null:
			return {"ok": false, "message": "读不到纹理：%s" % texture_path}
		columns = maxi(1, int(opts.get("columns", 0)))
		rows = maxi(1, int(opts.get("rows", 0)))
	elif source == "frame":
		var runner := FxGraphRunner.new()
		runner.capture_previews = false
		texture = runner.run(doc, float(opts.get("time", 0.0))).get("image")
		if texture == null:
			return {"ok": false, "message": "当前没有输出图像"}
		var frame_png := stem + "_frame.png"
		texture.save_png(frame_png)
		files.append(frame_png)
	else:
		var built := FxExportService.build_sheet(doc)
		if not bool(built.get("ok", false)):
			return built
		texture = built["image"]
		columns = int(built["columns"])
		rows = int(built["rows"])
		var sheet_png := stem + ".png"
		texture.save_png(sheet_png)
		files.append(sheet_png)
		var sheet_json := stem + ".json"
		_write_sheet_json(doc, sheet_json, texture, built)
		files.append(sheet_json)
		if int(opts.get("columns", 0)) > 0:
			columns = int(opts["columns"])
		if int(opts.get("rows", 0)) > 0:
			rows = int(opts["rows"])

	if texture.get_format() != Image.FORMAT_RGBA8 or texture.is_compressed():
		if texture.is_compressed():
			texture.decompress()
		if texture.get_format() != Image.FORMAT_RGBA8:
			texture.convert(Image.FORMAT_RGBA8)
	var texture_res := stem + "_tex.res"
	var tex_err := ResourceSaver.save(ImageTexture.create_from_image(texture), texture_res)
	if tex_err != OK:
		return {"ok": false, "message": "贴图资源写入失败：%s" % error_string(tex_err)}
	files.append(texture_res)

	var timeline := FxExportService.timeline_of(doc)
	var lifetime := float(opts.get("lifetime", 0.0))
	if lifetime <= 0.0:
		lifetime = float(timeline["duration"])
	var fixed_fps := int(opts.get("fixed_fps", 0))
	if fixed_fps <= 0:
		fixed_fps = int(timeline["fps"])
	# Godot 4 的 GPUParticles2D 没有 hframes/vframes：翻转书用一张 canvas_item 着色器
	# 按时间取格子。多帧时写出 .gdshader 并在场景里建 ShaderMaterial。
	var shader_path := ""
	if columns * rows > 1:
		shader_path = stem + "_flipbook.gdshader"
		var shader_file := FileAccess.open(shader_path, FileAccess.WRITE)
		if shader_file == null:
			return {"ok": false, "message": "着色器写入失败：%s" % error_string(FileAccess.get_open_error())}
		shader_file.store_string(_flipbook_shader())
		shader_file.close()
		files.append(shader_path)
	var scene := _scene_text(scene_path, texture_res, shader_path, opts, columns, rows, lifetime,
		fixed_fps, bool(timeline["loop"]), int(timeline["fps"]))
	var file := FileAccess.open(scene_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "message": "场景写入失败：%s" % error_string(FileAccess.get_open_error())}
	file.store_string(scene)
	file.close()
	files.push_front(scene_path)
	return {
		"ok": true,
		"message": "已导出粒子发生器：%s（%d×%d 帧网格）" % [scene_path.get_file(), columns, rows],
		"files": files,
	}


static func _load_texture(path: String) -> Image:
	var source := path.strip_edges()
	if source.is_empty():
		return null
	if ResourceLoader.exists(source):
		var res: Resource = load(source)
		if res is Texture2D:
			return (res as Texture2D).get_image()
		if res is Image:
			return res
	if FileAccess.file_exists(source):
		return Image.load_from_file(source)
	return null


static func _write_sheet_json(doc: Dictionary, json_path: String, sheet: Image,
		built: Dictionary) -> void:
	var frame_size: Vector2i = built["frame_size"]
	var columns := int(built["columns"])
	var count := int(built["frames"])
	var stem := FxExportService.safe_stem(doc)
	var rects: Array = []
	for i in range(count):
		rects.append({
			"filename": "%s %d" % [stem, i],
			"frame": {"x": (i % columns) * frame_size.x, "y": int(i / columns) * frame_size.y,
				"w": frame_size.x, "h": frame_size.y},
			"rotated": false, "trimmed": false,
			"spriteSourceSize": {"x": 0, "y": 0, "w": frame_size.x, "h": frame_size.y},
			"sourceSize": {"w": frame_size.x, "h": frame_size.y},
			"duration": int(round(1000.0 / float(int(built["fps"])))),
		})
	var payload := {
		"frames": rects,
		"meta": {
			"app": "幻像工坊", "version": "1", "image": sheet_path_name(json_path),
			"format": "RGBA8888",
			"size": {"w": sheet.get_width(), "h": sheet.get_height()},
			"scale": "1",
			"pixelfx": {
				"id": stem,
				"name": String(FxGraphDoc.meta_value(doc, "name", "幻像工坊")),
				"fps": int(built["fps"]), "loop": bool(built["loop"]), "frames": count,
				"frameSize": [frame_size.x, frame_size.y],
				"pivot": [frame_size.x / 2, frame_size.y / 2],
				"columns": columns,
			},
		},
	}
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "\t"))
		file.close()


static func sheet_path_name(json_path: String) -> String:
	return json_path.get_basename().get_file() + ".png"


static func _flipbook_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_mix;

uniform float columns = 1.0;
uniform float rows = 1.0;
uniform float frame_count = 1.0;
uniform float fps = 30.0;
uniform bool loop = true;

void fragment() {
	float total = max(1.0, frame_count);
	float frame = floor(TIME * fps);
	if (loop) {
		frame = mod(frame, total);
	} else {
		frame = min(frame, total - 1.0);
	}
	float cols = max(1.0, columns);
	float row_count = max(1.0, rows);
	float col = mod(frame, cols);
	float row = floor(frame / cols);
	vec2 uv = UV / vec2(cols, row_count);
	uv.x += col / cols;
	uv.y += row / row_count;
	COLOR = texture(TEXTURE, uv) * COLOR;
}
"""


static func _scene_text(_scene_path: String, texture_res: String, shader_path: String,
		opts: Dictionary, columns: int, rows: int, lifetime: float, fixed_fps: int,
		timeline_loop: bool, sheet_fps: int) -> String:
	var texture_path := ProjectSettings.localize_path(texture_res)
	var shape := String(opts.get("emission_shape", "point"))
	var shape_id := int(SHAPES.get(shape, 0))
	var direction := _vec2(opts.get("direction", [0.0, -1.0]))
	var gravity := _vec2(opts.get("gravity", [0.0, 0.0]))
	var one_shot := bool(opts.get("one_shot", false))
	var anim_loop := timeline_loop and not one_shot and columns * rows > 1

	var use_shader := not shader_path.is_empty() and columns * rows > 1
	var text := "[gd_scene load_steps=%d format=3]\n\n" % (5 if use_shader else 3)
	text += "[ext_resource type=\"Texture2D\" path=\"%s\" id=\"1_tex\"]\n" % texture_path
	if use_shader:
		text += "[ext_resource type=\"Shader\" path=\"%s\" id=\"2_shader\"]\n" % ProjectSettings.localize_path(shader_path)
	text += "\n"
	text += "[sub_resource type=\"ParticleProcessMaterial\" id=\"ParticleProcessMaterial_1\"]\n"
	text += "particle_flag_disable_z = true\n"
	text += "emission_shape = %d\n" % shape_id
	if shape == "sphere" or shape == "sphere_surface":
		text += "emission_sphere_radius = %.4f\n" % float(opts.get("emission_radius", 12.0))
	elif shape == "box":
		var extent := float(opts.get("box_extents", 16.0))
		text += "emission_box_extents = Vector3(%.4f, %.4f, 1.0)\n" % [extent, extent]
	elif shape == "ring":
		var radius := float(opts.get("ring_radius", 24.0))
		text += "emission_ring_axis = Vector3(0, 0, 1)\n"
		text += "emission_ring_radius = %.4f\n" % radius
		text += "emission_ring_inner_radius = %.4f\n" % (radius * 0.5)
		text += "emission_ring_height = 1.0\n"
	text += "direction = Vector3(%.4f, %.4f, 0)\n" % [direction.x, direction.y]
	text += "spread = %.4f\n" % float(opts.get("spread", 0.0))
	text += "gravity = Vector3(%.4f, %.4f, 0)\n" % [gravity.x, gravity.y]
	var velocity := float(opts.get("initial_velocity", 0.0))
	text += "initial_velocity_min = %.4f\n" % velocity
	text += "initial_velocity_max = %.4f\n" % velocity
	text += "scale_min = %.4f\n" % float(opts.get("scale_min", 1.0))
	text += "scale_max = %.4f\n" % float(opts.get("scale_max", 1.0))
	var anim_speed := float(opts.get("anim_speed", 1.0))
	text += "anim_speed_min = %.4f\n" % anim_speed
	text += "anim_speed_max = %.4f\n" % anim_speed
	text += "anim_offset_min = 0.0\nanim_offset_max = 0.0\n"
	text += "anim_loop = %s\n\n" % ("true" if anim_loop else "false")
	if use_shader:
		text += "[sub_resource type=\"ShaderMaterial\" id=\"ShaderMaterial_1\"]\n"
		text += "shader = ExtResource(\"2_shader\")\n"
		text += "shader_parameter/columns = %.4f\n" % float(columns)
		text += "shader_parameter/rows = %.4f\n" % float(rows)
		text += "shader_parameter/frame_count = %.4f\n" % float(columns * rows)
		var playback_fps := float(sheet_fps) * maxf(0.01, float(opts.get("anim_speed", 1.0)))
		text += "shader_parameter/fps = %.4f\n" % playback_fps
		text += "shader_parameter/loop = %s\n\n" % ("true" if anim_loop else "false")

	text += "[node name=\"%s\" type=\"GPUParticles2D\"]\n" % String(opts.get("name", "FxEmitter"))
	text += "texture = ExtResource(\"1_tex\")\n"
	if use_shader:
		text += "material = SubResource(\"ShaderMaterial_1\")\n"
	text += "amount = %d\n" % maxi(1, int(opts.get("amount", 1)))
	text += "lifetime = %.4f\n" % maxf(0.01, lifetime)
	text += "one_shot = %s\n" % ("true" if one_shot else "false")
	text += "explosiveness = %.4f\n" % clampf(float(opts.get("explosiveness", 0.0)), 0.0, 1.0)
	text += "randomness = %.4f\n" % clampf(float(opts.get("randomness", 0.0)), 0.0, 1.0)
	text += "fixed_fps = %d\n" % clampi(fixed_fps, 1, 240)
	text += "interpolate = false\n"
	text += "local_coords = %s\n" % ("true" if bool(opts.get("local_coords", false)) else "false")
	text += "texture_filter = %d\n" % clampi(int(opts.get("texture_filter", 1)), 0, 2)
	text += "emitting = true\n"
	text += "process_material = SubResource(\"ParticleProcessMaterial_1\")\n"
	return text


static func _vec2(raw: Variant) -> Vector2:
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	if raw is Vector2:
		return raw
	return Vector2.ZERO
