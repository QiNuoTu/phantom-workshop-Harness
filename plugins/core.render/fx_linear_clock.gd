class_name FxLinearClock
extends RefCounted
## `core.render` 的最小降级时钟：只有 `core.timeline` 被停用/未安装时才用。
##
## 故意不放在基座：`FxClockBroker` 只负责挑选 provider，时间推进规则属于插件层。
## 接口与 `FxPlaybackClock` 一致（duck typing），保证「帧号连续」不变量不丢。

var frame: int = 0
var accum: float = 0.0
var wrapped: bool = false

static func create() -> FxLinearClock:
	return FxLinearClock.new()

func reset(at_frame: int) -> void:
	frame = maxi(0, at_frame)
	accum = 0.0
	wrapped = false

func advance(delta: float, fps: float, count: int) -> bool:
	if count <= 0 or fps <= 0.0:
		return false
	var step := 1.0 / fps
	accum += maxf(delta, 0.0)
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
