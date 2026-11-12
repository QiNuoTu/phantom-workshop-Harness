extends FxPlugin
## 输出预览：订阅渲染服务，显示最终图像与耗时。

func panels() -> Array[Dictionary]:
	return [{
		"id": "editor.preview",
		"title": "预览",
		"area": "right",
		"order": 10,
		"factory": FxPreviewPanel.create,
	}]
