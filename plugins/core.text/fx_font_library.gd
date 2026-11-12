class_name FxFontLibrary
extends RefCounted
## 外部字体库：按路径加载 FontFile，带缓存。
##
## 路径可以是绝对路径、res:// 路径，或**相对资源根的路径**（推荐写成
## "plugins/core.text/assets/fonts/..."）：导出后 PCK 里没有字体文件，
## 由 FxResourceRoot 到 <exe 同级>/plugins/... 里找，所以启动即可用。
## 文本栅格化在 FxTextRaster 里完成；这里只负责“把一个字体文件变成 FontFile”。

static var _fonts: Dictionary = {}

## 插件自带的默认字体（相对资源根），让文字节点开箱即用。
## 用 SC（简体中文）家族：HarmonyOS_Sans 本体只有拉丁字形，中文要靠系统回退，
## 换一台没有中文字体的机器就会掉字。SC 家族自带全套汉字。
const DEFAULT_FONT := "plugins/core.text/assets/fonts/HarmonyOS Sans/HarmonyOS_Sans_SC/HarmonyOS_Sans_SC_Regular.ttf"


static func resolve_path(path: String) -> String:
	var key := path.strip_edges()
	if key.is_empty():
		return ""
	if FileAccess.file_exists(key):
		return key
	return FxResourceRoot.resolve(key)


static func font(path: String) -> FontFile:
	var key := resolve_path(path)
	if key.is_empty():
		return null
	if _fonts.has(key):
		return _fonts[key] as FontFile
	var file := FontFile.new()
	var err := file.load_dynamic_font(key)
	if err != OK:
		push_warning("FxFontLibrary：无法加载字体 %s（%s）" % [key, error_string(err)])
		return null
	_fonts[key] = file
	return file


## 找一个可用的系统字体作为演示/兜底。找不到返回空字符串。
## 注意：蓝图的字体参数永远优先使用用户显式选择的路径。
static func system_font_candidates() -> Array[String]:
	var names := ["Microsoft YaHei", "SimHei", "Noto Sans CJK SC", "Source Han Sans SC", "Arial"]
	var out: Array[String] = []
	for name in names:
		var path := OS.get_system_font_path(name, 400, 100, false)
		if not path.is_empty() and FileAccess.file_exists(path) and not out.has(path):
			out.append(path)
	return out
