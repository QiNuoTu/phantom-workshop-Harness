class_name FxTextureLibrary
extends RefCounted
## 外部纹理 / 序列帧导入。
##
## 与 FxAssetLibrary（内置 pixelfx 素材包）分工：
##   · FxAssetLibrary 只认识插件自带的 Aseprite 图集；
##   · 这里处理**用户的外部文件**：PNG / WebP / JPG / BMP / SVG 渲染结果等，
##     路径可以是绝对路径、res:// 或相对资源根（导出后到 <exe>/... 找）。
##
## 统一把文件读成 Image，再按需切片成单帧或转成 ImageTexture：
## 节点只依赖「纹理对象」（Image / ImageTexture），不关心它来自哪里。

const EXTENSIONS := ["png", "webp", "jpg", "jpeg", "bmp", "tga", "svg"]

static var _cache: Dictionary = {}
static var _order: Array[String] = []
const MAX_CACHE := 12
## 渲染线程也会走到这里（image.file 之类）：缓存字典必须互斥访问。
static var _mutex := Mutex.new()


static func resolve(path: String) -> String:
	var key := path.strip_edges()
	if key.is_empty():
		return ""
	if FileAccess.file_exists(key):
		return key
	return FxResourceRoot.resolve(key)


static func is_supported(path: String) -> bool:
	var ext := path.get_extension().to_lower()
	return EXTENSIONS.has(ext)


## 读成 Image（带按修改时间的缓存）。返回的 Image 是缓存本体，调用方要改先 duplicate。
static func image(path: String) -> Image:
	var full := resolve(path)
	if full.is_empty():
		return null
	var stamp := FileAccess.get_modified_time(full)
	_mutex.lock()
	if _cache.has(full):
		var hit: Dictionary = _cache[full]
		if int(hit.get("stamp", -1)) == stamp:
			_mutex.unlock()
			return hit.get("image") as Image
	_mutex.unlock()
	var loaded := Image.load_from_file(full)
	if loaded == null:
		return null
	if loaded.is_compressed():
		loaded.decompress()
	_mutex.lock()
	_cache[full] = {"stamp": stamp, "image": loaded}
	_order.erase(full)
	_order.append(full)
	while _order.size() > MAX_CACHE:
		var oldest: String = _order.pop_front()
		_cache.erase(oldest)
	_mutex.unlock()
	return loaded


## 供 UI 预览用：直接得到纹理对象。
static func texture(path: String) -> ImageTexture:
	var img := image(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


## 探测文件：{ok, path, size, format}，参数控件用它显示「找到了 / 找不到」。
static func probe(path: String) -> Dictionary:
	var full := resolve(path)
	if full.is_empty():
		return {"ok": false, "path": "", "size": Vector2i.ZERO, "format": ""}
	var img := image(path)
	if img == null:
		return {"ok": false, "path": full, "size": Vector2i.ZERO, "format": ""}
	return {"ok": true, "path": full, "size": img.get_size(), "format": img.get_format()}


## 从一张精灵表里切出第 index 帧；cols/rows 为网格，index 会按帧数取模。
static func sheet_frame(sheet: Image, columns: int, rows: int, index: int) -> Image:
	if sheet == null:
		return null
	return sheet_frame_at(sheet, grid_of(sheet.get_size(), "grid", columns, rows,
		Vector2i.ZERO, 0, 0), index)


## 网格换算：把「列 × 行」或「单元尺寸」两种切法统一成同一份描述。
## 精灵表节点的执行、参数行的「共 N 帧」提示、拖拽导入的猜测都用它，
## 三处不会各算一遍导致数目对不上。
##   mode = "size"   按单元像素尺寸切，列/行由图片尺寸算出来
##   mode = "grid"   按列 × 行切，单元尺寸由图片尺寸算出来
static func grid_of(size: Vector2i, mode: String, columns: int, rows: int,
		cell: Vector2i, margin: int, spacing: int) -> Dictionary:
	var w := maxi(1, size.x)
	var h := maxi(1, size.y)
	var m := maxi(0, margin)
	var sp := maxi(0, spacing)
	var cols := 1
	var rws := 1
	var cw := w
	var ch := h
	if mode == "size":
		cw = maxi(1, cell.x)
		ch = maxi(1, cell.y)
		cols = maxi(1, int(floor(float(w - m * 2 + sp) / float(cw + sp))))
		rws = maxi(1, int(floor(float(h - m * 2 + sp) / float(ch + sp))))
	else:
		cols = clampi(columns, 1, 64)
		rws = clampi(rows, 1, 64)
		cw = maxi(1, int(floor(float(w - m * 2 - sp * (cols - 1)) / float(cols))))
		ch = maxi(1, int(floor(float(h - m * 2 - sp * (rws - 1)) / float(rws))))
	return {
		"cols": cols, "rows": rws, "cell": Vector2i(cw, ch),
		"count": cols * rws, "margin": m, "spacing": sp,
	}


## 按网格描述切出第 index 帧（从左上角起，先行后列）。
## 越界返回 null：留白导致最后一格超出图片时不要给一张半截图。
static func sheet_frame_at(sheet: Image, grid: Dictionary, index: int) -> Image:
	if sheet == null:
		return null
	var cols := maxi(1, int(grid.get("cols", 1)))
	var rws := maxi(1, int(grid.get("rows", 1)))
	var cell: Vector2i = grid.get("cell", Vector2i.ZERO)
	if cell.x <= 0 or cell.y <= 0:
		return null
	var total := cols * rws
	var frame := posmod(index, total)
	var m := int(grid.get("margin", 0))
	var sp := int(grid.get("spacing", 0))
	var origin := Vector2i(m + (frame % cols) * (cell.x + sp), m + (frame / cols) * (cell.y + sp))
	if origin.x + cell.x > sheet.get_width() or origin.y + cell.y > sheet.get_height():
		return null
	return sheet.get_region(Rect2i(origin, cell))


## 目录里的一批帧文件（按文件名排序），用于「序列图」导入。
static func list_frames(folder: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(folder)
	if dir == null:
		return out
	var names := Array(dir.get_files())
	names.sort()
	for raw in names:
		var name := String(raw)
		if is_supported(name):
			out.append(folder.path_join(name))
	return out
