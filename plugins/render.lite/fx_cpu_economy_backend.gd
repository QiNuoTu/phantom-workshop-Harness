class_name FxCpuEconomyBackend
extends FxRenderBackend
## 经济后端：由独立插件贡献，证明「渲染器可更换」不需要改基座或编排层。
##
## 与标准后端的真实差异：
##   · 播放时关闭节点预览（少生成/上传纹理）；
##   · 相邻帧间隔小于阈值时复用上一帧图，跳过整次求值；
##   · 精确帧（导出 / 测试 / render_once）绝不跳帧，保证结果一致。
## 后端自己持有这条时间状态，切换走时由 FxRenderBroker.invalidate() 清掉。

const SKIP_WINDOW := 0.033

var _last_image: Image = null
var _last_time: float = -999.0
var _skipped: int = 0


static func create() -> FxRenderBackend:
	return FxCpuEconomyBackend.new()


func _init() -> void:
	id = "cpu.economy"
	label = "经济模式（跳帧 · 省预览）"


func frame(doc: Dictionary, t: float, policy: Dictionary,
		runner: RefCounted, ctx: Dictionary) -> Dictionary:
	if runner == null:
		return {}
	var playing := bool(policy.get("playing", false))
	var exact := bool(ctx.get("exact", false))
	if playing and not exact and _last_image != null and absf(t - _last_time) < SKIP_WINDOW:
		_skipped += 1
		return {
			"image": _last_image,
			"previews": {},
			"stats": {"skipped": true, "skipped_total": _skipped},
		}
	var saved: Variant = runner.get("capture_previews")
	if playing and not exact:
		runner.set("capture_previews", false)
	var result: Variant = runner.call("run", doc, t)
	runner.set("capture_previews", saved)
	if not result is Dictionary:
		return {}
	var out: Dictionary = result
	var image: Variant = out.get("image")
	if image is Image:
		_last_image = image
		_last_time = t
	var stats: Dictionary = out.get("stats", {})
	stats["skipped"] = false
	out["stats"] = stats
	return out


func invalidate() -> void:
	_last_image = null
	_last_time = -999.0
	_skipped = 0
