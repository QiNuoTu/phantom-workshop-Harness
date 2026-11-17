class_name FxAssetStatus
extends RefCounted
## 素材库的诊断片段（由 `core.asset` 贡献）。
##
## 装配诊断里「素材根 / pixelfx 素材」两行原本写在外壳里，直接调 `FxAssetLibrary`。
## 那是插件的类，基座引用它等于停用本插件就编译不过。现在反过来：本插件自报。

## 状态栏片段：素材数量不需要常驻状态栏，返回空文本（占位以便注册诊断）。
static func fragment(_stats: Dictionary) -> Dictionary:
	return {"text": "", "tone": ""}


static func diagnostic(_service: Variant) -> String:
	var roots := FxResourceRoot.existing_roots(FxAssetLibrary.ROOT_RELATIVE)
	FxAssetLibrary.ensure_loaded()
	return "素材根 %d：%s · pixelfx 素材 %d 套" % [
		roots.size(), ", ".join(PackedStringArray(Array(roots))),
		FxAssetLibrary.all().size(),
	]
