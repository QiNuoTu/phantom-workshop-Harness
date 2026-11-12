extends FxPlugin
## 渲染编排组件：贡献 services["render"]、默认 CPU 后端与后端切换设置。
## 编排层（何时画）与求帧后端（怎么画）分离，第三方插件可加自己的后端。

func services() -> Dictionary:
	return {"render": FxRenderApi.create}


func render_backends() -> Array[Dictionary]:
	return [{
		"id": "cpu.standard",
		"label": "标准 CPU 逐像素",
		"description": "每帧完整求值，节点预览齐全；导出与预览一致。",
		"order": 10,
		"factory": FxCpuStandardBackend.create,
	}]


func settings() -> Array[Dictionary]:
	return [{
		"id": "render.threaded", "label": "后台线程渲染", "group": "渲染质量",
		"kind": "bool", "default": true, "applies": "runtime", "order": 4,
		"description": "求帧放在工作线程上，界面不被大图卡住；画质完全不变（全分辨率、逐节点预览照旧）",
	}, {
		"id": "render.cache", "label": "逐帧缓存", "group": "渲染质量",
		"kind": "bool", "default": true, "applies": "runtime", "order": 6,
		"description": "算过的帧存进内存热层与紧密单文件 frames.fxc；时间轴标尺上的小色块显示状态（红=未缓存 / 黄=缓存中 / 绿=已缓存）",
	}, {
		"id": "render.prefetch", "label": "空闲时后台预渲染", "group": "渲染质量",
		"kind": "bool", "default": true, "applies": "runtime", "order": 7,
		"description": "打开工程或改完参数后立刻（0.18 秒防抖）用多条工作线程把整段动画按精确质量算一遍并落盘；播放只读缓存，帧号连续不跳",
	}, {
		"id": "render.prefetch_workers", "label": "预渲染并行线程", "group": "渲染质量",
		"kind": "int", "default": 0, "min": 0, "max": 8, "step": 1,
		"applies": "runtime", "order": 7,
		"description": "0 = 按 CPU 核数自动（最多 6 条）。各帧互不依赖，多条线程同时算；12 核机器上 60 帧工程从约 36 秒压到几秒",
	}, {
		"id": "render.cache_location", "label": "帧缓存位置", "group": "渲染质量",
		"kind": "enum", "default": "exe", "applies": "runtime", "order": 10,
		"options": [
			{"value": "exe", "label": "软件本体目录（紧密文件）"},
			{"value": "user", "label": "用户数据目录"},
			{"value": "memory", "label": "纯内存（不落盘）"},
		],
		"description": "紧密单文件 frames.fxc 按帧号定长偏移直接 seek 读取，零 PNG 编码；exe 目录无写权限时自动回退用户目录",
	}, {
		"id": "render.cache_max_mb", "label": "磁盘缓存上限 (MB)", "group": "渲染质量",
		"kind": "int", "default": 512, "min": 64, "max": 4096, "step": 64,
		"applies": "runtime", "order": 11,
		"description": "超过上限按工程桶的最后修改时间 LRU 自动删除；当前正在用的桶不会被清",
	}, {
		"id": "render.cache_memory_mb", "label": "内存缓存上限 (MB)", "group": "渲染质量",
		"kind": "int", "default": 128, "min": 32, "max": 1024, "step": 32,
		"applies": "runtime", "order": 12,
		"description": "纯内存模式下尤其重要：按写入顺序淘汰，避免长时间预览占用过大",
	}, {
		"id": "render.gpu_ops", "label": "GPU 算子（预览与预渲染）", "group": "渲染质量",
		"kind": "bool", "default": true, "applies": "runtime", "order": 9,
		"description": "把逐像素算子交给 compute shader；工作线程通过渲染线程桥批量提交，无图形设备时自动回落 CPU",
	}, {
		"id": "render.cache_clear", "label": "帧缓存", "group": "渲染质量",
		"kind": "action", "button": "清理帧缓存", "default": null,
		"action": FxRenderApi.clear_cache, "applies": "none", "order": 8,
		"description": "清掉内存与磁盘上的全部逐帧缓存（含软件本体目录 fx_cache/frames），下次渲染重新算",
	}, {
		"id": "render.backend", "label": "渲染后端", "group": "渲染质量",
		"kind": "enum", "default": "cpu.standard",
		"options": [
			{"value": "cpu.standard", "label": "标准 CPU 逐像素"},
			{"value": "cpu.economy", "label": "经济模式（跳帧 · 省预览）"},
			{"value": "gpu.standard", "label": "GPU 合成（实验 · 需插件）"},
		],
		"capability": "render.backend", "applies": "runtime", "order": 5,
		"description": "后端由插件贡献；切换只换求帧实现，不重建工作台、不动文档。",
	}]


## 帧缓存的两个手动入口：命令给快捷键/命令面板，菜单项挂在「视图」下。
## 状态栏片段：帧缓存与播放帧号的文案由本插件自己描述，基座不认识这些字段。
func status_fragments() -> Array[Dictionary]:
	return [{
		"id": "render.cache", "order": 10, "handler": FxRenderStatus.fragment,
		"diagnostic": FxRenderStatus.diagnostic,
	}]


func commands() -> Array[Dictionary]:
	return [
		{"id": "render.prefetch", "label": "预渲染整段动画", "category": "渲染",
			"handler": FxRenderApi.cmd_prefetch},
		{"id": "render.cache_clear", "label": "清理帧缓存", "category": "渲染",
			"handler": FxRenderApi.cmd_clear_cache},
	]


func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "view", "label": "预渲染整段动画", "command": "render.prefetch", "order": 300},
		{"menu": "view", "label": "清理帧缓存", "command": "render.cache_clear", "order": 310},
	]


func capabilities() -> Array[Dictionary]:
	return [{
		"key": "render.backend", "apply": FxRenderApi.invalidate_backend,
		"order": 10, "description": "切换后端时清空代理缓存与后端内部状态。",
	}]
