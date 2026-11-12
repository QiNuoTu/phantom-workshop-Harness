extends FxPlugin
## 质量策略插件：所有贡献都是静态 Callable，宿主停用时会 LIFO 撤回。

func settings() -> Array[Dictionary]:
	return FxQualitySettings.settings()


func capabilities() -> Array[Dictionary]:
	return FxQualitySettings.capabilities()


func quality_policies() -> Array[Dictionary]:
	return FxQualitySettings.quality_policies()
