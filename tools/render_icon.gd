extends SceneTree
## 把 icon.svg 渲染成多尺寸 PNG（品牌物料 / 导出 exe 图标 / GitHub 头像）。
## 运行：godot --headless --path . --script res://tools/render_icon.gd

const SIZES := [1024, 512, 256, 128, 64]
const OUT_DIR := "res://assets/branding"


func _initialize() -> void:
	var svg := FileAccess.get_file_as_string("res://icon.svg")
	if svg.is_empty():
		print("ICON_FAIL 读不到 icon.svg")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for size in SIZES:
		var image := Image.new()
		# 以 512 为基准放大到目标尺寸再降采样，边缘比直接 scale 干净。
		var err := image.load_svg_from_string(svg, float(size) / 512.0)
		if err != OK or image.is_empty():
			print("ICON_FAIL size=%d err=%s" % [size, error_string(err)])
			continue
		image.convert(Image.FORMAT_RGBA8)
		var path := "%s/icon-%d.png" % [OUT_DIR, size]
		image.save_png(ProjectSettings.globalize_path(path))
		print("ICON ok %s %dx%d" % [path, image.get_width(), image.get_height()])
	# 工程与导出用的主图（Godot 会按需缩放）。
	var src := Image.new()
	if src.load_svg_from_string(svg, 1.0) == OK:
		src.convert(Image.FORMAT_RGBA8)
		src.save_png(ProjectSettings.globalize_path("res://icon.png"))
		print("ICON ok res://icon.png %dx%d" % [src.get_width(), src.get_height()])
	quit(0)
