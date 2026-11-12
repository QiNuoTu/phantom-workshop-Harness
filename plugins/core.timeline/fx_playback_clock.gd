class_name FxPlaybackClock
extends RefCounted
## 线性帧时钟 —— **时间维度**的参考实现（`core.timeline` 插件贡献）。
##
## 与空间组合（图结构、子图）完全解耦：这里只有「真实时间 → 帧号」的推进规则，
## 不认识节点、图、缓存或 UI。`FxRenderService` 通过 `FxClockBroker` 拿到它，
## 每帧问一次「该不该进下一帧」，再拿帧号去问 `FxFrameCache`（空间结果的
## 时间索引）。两者可独立替换，这正是时空可组合。
##
## 关键不变量：一次 advance 至多跨一个帧号。界面掉帧时播放变慢，
## 但帧号永远是 0→1→2…，不会出现 0→18 的跳帧。

## 当前帧号（只读语义由调用方遵守；reset 可重新定位）。
var frame: int = 0
## 不足一帧的真实时间余量。
var accum: float = 0.0
## 上一帧是否绕回起点（循环播放时给 UI 用）。
var wrapped: bool = false
## 播放速率：1.0 = 实时。变速 / 慢放由插件自己解释，不改渲染服务。
var speed: float = 1.0


static func create() -> FxPlaybackClock:
	return FxPlaybackClock.new()


func reset(at_frame: int) -> void:
	frame = maxi(0, at_frame)
	accum = 0.0
	wrapped = false


## 返回 true 表示帧号前进了一格；false 时帧号不变。
func advance(delta: float, fps: float, count: int) -> bool:
	if count <= 0 or fps <= 0.0:
		return false
	var step := 1.0 / fps
	accum += maxf(delta, 0.0) * speed
	if accum < step:
		return false
	accum = fmod(accum, step)
	frame = (frame + 1) % count
	wrapped = frame == 0
	return true


func time_of(index: int, fps: float) -> float:
	return float(index) / maxf(fps, 1.0)


func frame_at(t: float, fps: float, count: int) -> int:
	if count <= 0:
		return 0
	return clampi(int(round(t * fps)), 0, count - 1)


func set_speed(value: float) -> void:
	speed = clampf(value, 0.01, 16.0)
