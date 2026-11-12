extends SceneTree
## 探针：验证 Godot 4.7 能否同步把外部字体栅格化成 Image。
## 用法：godot --headless --path . --script res://tests/probe_font.gd

func _initialize() -> void:
	var path := "C:/Windows/Fonts/msyh.ttc"
	if not FileAccess.file_exists(path):
		path = "C:/Windows/Fonts/arial.ttf"
	print("font path=", path, " exists=", FileAccess.file_exists(path))
	var font := FontFile.new()
	var err := font.load_dynamic_font(path)
	print("load_dynamic_font err=", err, " rid_count=", font.get_rids().size())
	if font.get_rids().is_empty():
		_quit(1)
		return
	var rid: RID = font.get_rids()[0]
	var ts: TextServer = TextServerManager.get_primary_interface()
	var size_i := 32
	var size := Vector2i(size_i, 0)
	var glyph := ts.font_get_glyph_index(rid, size_i, "A".unicode_at(0), 0)
	print("glyph=", glyph)
	ts.font_render_glyph(rid, size, glyph)
	var tex_idx := ts.font_get_glyph_texture_idx(rid, size, glyph)
	var uv := ts.font_get_glyph_uv_rect(rid, size, glyph)
	var offset := ts.font_get_glyph_offset(rid, size, glyph)
	var advance := ts.font_get_glyph_advance(rid, size_i, glyph)
	print("tex_idx=", tex_idx, " uv=", uv, " offset=", offset, " advance=", advance)
	print("texture_count=", font.get_texture_count(0, size))
	var atlas := font.get_texture_image(0, size, tex_idx)
	print("atlas=", atlas, " size=", atlas.get_size() if atlas != null else Vector2i.ZERO)

	var shaped := ts.create_shaped_text(TextServer.DIRECTION_LTR, TextServer.ORIENTATION_HORIZONTAL)
	ts.shaped_text_add_string(shaped, "Hi 幻像", [rid], size_i)
	ts.shaped_text_shape(shaped)
	var glyphs := ts.shaped_text_get_glyphs(shaped)
	print("shaped glyphs=", glyphs.size())
	for g in glyphs:
		print("  index=", g.get("index"), " rid=", g.get("font_rid"), " primary=", rid, " offset=", g.get("offset"), " advance=", g.get("advance"))
	ts.free_rid(shaped)
	_quit(0)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
