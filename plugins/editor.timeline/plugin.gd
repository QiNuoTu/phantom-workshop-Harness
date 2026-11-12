extends FxPlugin
## 时间轴泳道：显示全部节点已打帧的属性，双击打/删帧。
## 播放状态由 FxRenderService 持有，这里只发命令。

func panels() -> Array[Dictionary]:
	return [{
		"id": "editor.timeline",
		"title": "时间轴",
		"area": "bottom",
		"order": 10,
		"factory": FxTimelinePanel.create,
	}]


func commands() -> Array[Dictionary]:
	return [
		{"id": "playback.toggle", "label": "播放 / 暂停", "shortcut": "Space",
			"category": "播放", "handler": FxTimelinePanel.cmd_toggle_playback},
		{"id": "playback.start", "label": "回到开头",
			"category": "播放", "handler": FxTimelinePanel.cmd_goto_start},
		{"id": "playback.prev", "label": "上一帧",
			"category": "播放", "handler": FxTimelinePanel.cmd_step_back},
		{"id": "playback.next", "label": "下一帧",
			"category": "播放", "handler": FxTimelinePanel.cmd_step_forward},
	]


func menus() -> Array[Dictionary]:
	return [{"id": "playback", "title": "播放", "order": 35}]


func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "playback", "label": "播放 / 暂停", "command": "playback.toggle", "order": 10, "shortcut": "Space"},
		{"menu": "playback", "label": "回到开头", "command": "playback.start", "order": 20},
		{"menu": "playback", "label": "", "separator": true, "order": 25},
		{"menu": "playback", "label": "上一帧", "command": "playback.prev", "order": 30},
		{"menu": "playback", "label": "下一帧", "command": "playback.next", "order": 40},
	]


func toolbar() -> Array[Dictionary]:
	return [
		{"label": "播放", "command": "playback.toggle", "order": 200, "toggle": true, "quick": true,
			"shortcut": "Space", "tooltip": "空格：播放 / 暂停", "separator": true},
	]
