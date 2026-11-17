extends FxPlugin
## 原生像素内核插件（此前是一个裸的 GDExtension，不是插件）。
##
## 它贡献的不是算子，而是**一整套加速开关**：五个 C++ 算子族。
## GDScript 侧的算子仍然各自决定语义，只在最内层循环处调用
## `FxNativeBridge`，桥再按族取对应的原生类。
##
## 三条可观测的行为，全部经由这里：
##   · 激活 → 桥开始使用原生路径；
##   · 停用 → 桥立刻回落 GDScript（画面不变、只是慢），这就是「可撤销」；
##   · 库缺失 / 架构不符 → 启动时记一条 warning，其余照常。
##
## 为什么不做成 `native_ops()`：那套窄 ABI（`fx_exec`）是给「整个算子写在 C++ 里」
## 用的，而本插件是**混合实现** —— 算子语义在图/插件层，只有逐像素内层在 C++。
## 两者都在协议内，只是粒度不同；混用会让「算子的语义在哪」变得说不清。

const FAMILIES := ["point", "warp", "blend", "edge", "gen"]


func activate() -> void:
	# 顺序很重要：**先打开桥，再探测**。
	# 反过来会踩一个自造的坑：停用后 `_enabled=false`，重新启用时探测一律为「缺席」，
	# 于是插件明明活着却永远回落 —— 而且只在"停用再启用"这条路径上出现。
	if OS.get_environment("FX_NATIVE") == "0":
		# 环境变量是显式的全局否决，尊重它，别用 activate 把它盖掉。
		push_warning("FX_NATIVE=0：原生像素内核保持关闭，全部算子回落 GDScript")
		return
	FxNativeBridge.set_enabled(true)
	var report := FxNativeBridge.abi_report()
	if not bool(report.get("available", false)):
		# 不报错：库缺席是合法状态（没编、换平台、或用户删了 native/）。
		push_warning("原生像素内核不可用，全部算子回落 GDScript：%s"
			% String(report.get("message", "")))


func deactivate() -> void:
	# 停用 = 真的不用。不是「留着但假装没有」：桥下一次调用就走 GDScript，
	# 于是「停用插件后画面是否仍然正确」变成一条可测的事实。
	FxNativeBridge.set_enabled(false)


## 能力键：**原生实现由谁提供**。
##
## 这不是装饰：`FxNativeBridge` 用它判断「原生路径现在该不该用」。
## 插件被停用（或依赖不满足）时这条能力自动从注册表撤回，于是桥立刻回落
## GDScript —— 停用插件真的会掉性能，而不是"看起来停了"。
func capabilities() -> Array[Dictionary]:
	return [{
		"key": FxNativeBridge.CAPABILITY,
		"apply": _on_capability,
		"order": 0,
	}]


static func _on_capability(_value: Variant) -> void:
	# 消费者用 `FxCapabilities.has()` 判断存在性；这里不需要被 dispatch。
	pass


func status_fragments() -> Array[Dictionary]:
	return [{
		"id": "pixels.native", "order": 60,
		"handler": FxNativeBridge.fragment,
		"diagnostic": FxNativeBridge.diagnostic,
	}]
