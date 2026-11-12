extends FxPlugin
## 第二个渲染后端插件：证明求帧实现可以不改基座、不改编排层直接替换/增删。
## 停用本插件后设置项里的「经济模式」会自动回落到标准后端。

func render_backends() -> Array[Dictionary]:
	return [{
		"id": "cpu.economy",
		"label": "经济模式（跳帧 · 省预览）",
		"description": "播放时关闭节点预览并复用相邻帧；精确帧仍完整求值。",
		"order": 20,
		"factory": FxCpuEconomyBackend.create,
	}]
