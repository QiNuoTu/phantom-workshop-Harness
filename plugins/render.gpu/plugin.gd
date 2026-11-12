extends FxPlugin
## GPU 渲染服务器（第一阶段）：贡献一个走 GPU 合成通道的后端，并在设备不可用时退回 CPU。
##
## 这一阶段刻意不碰求值链：图求值仍由 CPU 后端完成，GPU 负责「整帧合成」。
## 好处是随时可退回、界面永远有画面；坏处是它还不是完整的 GPU 渲染器 ——
## 那需要逐算子 GPU 实现，见 FxGpuBackend 顶部注释里的下一步。

## Phase 1：把最贵的两个逐像素算子换成 GPU 版（同名覆盖）。
## 不是无条件替换：FxGpuOps.active() 会检查后端/设备/线程，任一不满足就回落 CPU；
## 停用本插件时账本 LIFO 撤回会自动把 op 表恢复成 core.image 的实现。
func ops() -> Dictionary:
	return {
		&"image.blur": FxGpuOps.blur,
		&"image.mix": FxGpuOps.mix,
		&"image.outline": FxGpuOps.outline,
	}


func render_backends() -> Array[Dictionary]:
	return [{
		"id": "gpu.standard",
		"label": "GPU 合成（实验）",
		"description": "图求值在 CPU，整帧合成走 GPU 着色器；无图形设备时自动退回标准 CPU 后端。",
		# order 最小 = 默认后端。基座不再硬编码 "gpu.standard"，
		# 「谁该当默认」由插件用 order 自己声明（停用本插件就自动让位给 CPU）。
		"order": 5,
		"factory": FxGpuBackend.create,
	}]


func settings() -> Array[Dictionary]:
	return [{
		"id": "render.gpu_sharpen", "label": "GPU 锐化强度", "group": "渲染质量",
		"kind": "float", "default": 0.6, "min": 0.0, "max": 2.0, "step": 0.05,
		"applies": "runtime", "order": 40,
		"description": "GPU 后处理的锐化量；0 = 只上传不下指令（等同关闭）。仅在渲染后端选到 GPU 合成时生效",
	}, {
		"id": "render.gpu_probe", "label": "图形设备", "group": "渲染质量",
		"kind": "action", "button": "检测 GPU", "default": null,
		"action": FxGpuBackend.log_info.bind({}), "applies": "none", "order": 41,
		"description": "打印适配器、厂商、图形接口版本与 RenderingDevice 是否就绪",
	}]


func commands() -> Array[Dictionary]:
	return [{
		"id": "render.gpu_info", "label": "检测 GPU 设备", "category": "渲染",
		"handler": FxGpuBackend.cmd_info,
	}]


func menu_items() -> Array[Dictionary]:
	return [{"menu": "view", "label": "检测 GPU 设备", "command": "render.gpu_info", "order": 320}]
