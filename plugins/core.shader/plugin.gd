extends FxPlugin
## 着色器：把 `.gdshader` 当成一种算子接进图里。
##
## 只贡献「节点定义 + 算子 + 参数控件」三样，内核零改动。
## 离屏视口只能在渲染线程用，所以插件注册一个「主线程 GPU 泵」：
## 工作线程求帧遇到着色器时把请求排队，主线程每帧处理一小批并回写结果。
## 这样 GPU 节点依然拿到真正的着色器结果，却不再把整帧求值拖回主线程。


func activate() -> void:
	# 离屏视口要在第一次求值之前就存在（见 FxShaderRuntime.prewarm）。
	FxShaderRuntime.prewarm()
	FxShaderRuntime.open_bridge()
	FxRenderGate.set_main_thread_pump(FxShaderRuntime.pump)


func deactivate() -> void:
	FxRenderGate.set_main_thread_pump(Callable())
	FxShaderRuntime.close_bridge()
	FxShaderRuntime.shutdown()


func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return FxOpsShader.ops()


func time_dependent_ops() -> Array:
	# 着色器几乎都会用到 u_time；声明成时间相关，执行器每帧都会重新求值。
	return [&"shader.image"]


func param_kinds() -> Dictionary:
	return {"shader": FxShaderWidget.build}


func drop_handlers() -> Array[Dictionary]:
	return [{
		"id": "core.shader.drop",
		"order": 30,
		"extensions": ["gdshader"],
		"handler": FxShaderDrop.handle,
	}]


func settings() -> Array[Dictionary]:
	return [
		{"id": "shader.enabled", "label": "启用着色器节点", "group": "渲染",
			"kind": "bool", "default": true, "applies": "none", "order": 10,
			"description": "关闭后 shader.image 节点按「原样输出」处理（不调用 GPU，适合排查问题）"},
	]
