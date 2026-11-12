class_name FxSkinTextureLibrary
extends RefCounted
## 皮肤贴图的外部资源加载器（论文 §6.1 系统边界）。
##
## 贴图不是 PCK 内的资源，而是「可安装 / 可卸载 / 可替换」的外部包：
## FxResourceRoot 按 res:// → <exe 同级> → user:// → 附加根 解析相对路径，
## 于是同一套代码在开发期与导出后都能找到素材；删掉整个目录，皮肤自动
## 回落到无贴图的几何装饰，不会崩。
##
## 这对第三方美术素材尤其重要：受 CC BY-NC-SA 等非商业许可约束的图片
## 可以不随程序主体分发，由使用者自行按许可放置（见插件目录 assets/NOTICE.md）。

static var _cache: Dictionary = {}


static func resolve(root: String, filename: String) -> String:
	return FxResourceRoot.resolve(root.path_join(filename))


static func load_set(root: String, manifest: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if root.is_empty() or manifest.is_empty():
		return out
	for key in manifest.keys():
		var filename := String(manifest[key])
		var path := resolve(root, filename)
		if path.is_empty():
			continue
		var cache_key := path
		var tex: Texture2D = null
		if _cache.has(cache_key) and is_instance_valid(_cache[cache_key]):
			tex = _cache[cache_key]
		else:
			var image := Image.load_from_file(path)
			if image != null:
				tex = ImageTexture.create_from_image(image)
				_cache[cache_key] = tex
		if tex != null:
			out[String(key)] = tex
	return out


static func available(root: String, manifest: Dictionary) -> int:
	var count := 0
	for key in manifest.keys():
		if not resolve(root, String(manifest[key])).is_empty():
			count += 1
	return count


static func clear_cache() -> void:
	_cache.clear()
