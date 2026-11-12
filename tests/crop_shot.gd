extends SceneTree
## 截图裁剪小工具（纯 Image，不依赖渲染）。

func _initialize() -> void:
	var base := "user://graph_test/ui.png"
	var image := Image.load_from_file(base)
	if image == null:
		push_error("找不到 ui.png")
		_quit(1)
		return
	_crop(image, Rect2i(0, 0, 1100, 70), "user://graph_test/crop_toolbar.png", 2)
	_crop(image, Rect2i(1040, 300, 400, 250), "user://graph_test/crop_panel.png", 2)
	_quit(0)


func _crop(image: Image, rect: Rect2i, path: String, scale: int) -> void:
	var region := image.get_region(rect)
	region.resize(rect.size.x * scale, rect.size.y * scale, Image.INTERPOLATE_NEAREST)
	region.save_png(path)
	print(path)


## 无头脚本退出前必须卸载插件注册表：静态表里的 Callable 不能活过脚本类。
func _quit(code: int = 0) -> void:
	FxPluginHost.shutdown()
	quit(code)
