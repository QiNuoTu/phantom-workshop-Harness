extends FxPlugin
## `core.timeline`：时间维度（播放时钟）。
##
## 只贡献一个 clock provider，不提供节点、算子、面板或设置。
## 空间维度归 `core.graph`，求帧与缓存归 `core.render`，三者通过基座的服务代理
## 组合 —— 换时间模型不需要动另外两个插件。


func clocks() -> Array[Dictionary]:
	return [{
		"id": "core.timeline.linear", "label": "线性帧时钟",
		"priority": 10, "factory": FxPlaybackClock.create,
	}]
