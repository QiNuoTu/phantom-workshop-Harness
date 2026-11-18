extends FxPlugin
## 调色抠像套装的**原生实现**：5 个族类、28 个算子，全部在 C++ 里算。
##
## 为什么是独立插件、独立库，而不是往 pixels.native 里塞族类：
##   · `pixels.native` 的五个族是「供全工程复用的像素工具」，它们有 GDScript 回落；
##   · 这 28 个算子是某一套节点的**唯一实现**——语义随节点定义一起演进，
##     塞进公共库里会让「停用 pixels.native」的语义变得说不清；
##   · 两份库各自编译、各自分发，删掉任何一个目录都不影响另一个。
##
## 一个类一个族：某族编不出来时只丢那 5~6 个算子，其余四族照常绑定。
## 所有算子都是纯函数（不持跨帧状态），因此全部声明 `thread_safe: true`。

## 族类名 → 该族负责的算子。绑定顺序无关，执行器只认 op id。
const FAMILIES := {
	"FxKitKey": [
		"key.chroma_pro", "key.luma", "key.diff",
		"key.color_range", "key.matte_clean", "key.despill",
	],
	"FxKitChannel": [
		"channel.extract", "channel.combine", "channel.mixer",
		"channel.set_alpha", "channel.shift", "channel.swap",
	],
	"FxKitMask": [
		"mask.rect", "mask.ellipse", "mask.boolean",
		"mask.from_luma", "mask.feather", "mask.vignette",
	],
	"FxKitTone": [
		"tone.posterize_pro", "tone.palette", "tone.levels_pro",
		"tone.split_tone", "tone.temperature", "tone.curves",
	],
	"FxKitStyle": [
		"style.find_edges", "style.emboss", "style.cartoon",
		"style.halftone", "style.grain",
	],
}


func native_ops() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cls in FAMILIES.keys():
		for op_id in FAMILIES[cls]:
			out.append({"op": String(op_id), "class": String(cls), "thread_safe": true})
	return out


## 让「原生族在不在」变成可查的事实：装配诊断会打印这一行。
func status_fragments() -> Array[Dictionary]:
	return [{
		"id": "fx.native-kit.families",
		"order": 95,
		"handler": _badge,
		"diagnostic": _diag,
	}]


static func _present() -> Array[String]:
	var found: Array[String] = []
	for cls in FAMILIES.keys():
		if ClassDB.class_exists(StringName(String(cls))):
			found.append(String(cls))
	return found


static func _diag(_service: Variant) -> String:
	var found := _present()
	var total := 0
	for cls in FAMILIES.keys():
		total += (FAMILIES[cls] as Array).size()
	return "调色抠像原生包 fx.native-kit：%d/%d 族在场（%s）· 算子 %d 个" % [
		found.size(), FAMILIES.size(), ", ".join(PackedStringArray(found)), total,
	]


static func _badge(_stats: Dictionary) -> Dictionary:
	var found := _present()
	if found.size() == FAMILIES.size():
		return {"text": "", "tone": ""}
	return {"text": "原生 %d/5" % found.size(), "tone": "warn"}
