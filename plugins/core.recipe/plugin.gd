extends FxPlugin
## VfxEngine 配方节点：配方 JSON → Image。
## 算子/控件工厂都是静态 Callable，符合插件契约。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return {&"image.recipe": FxOpsRecipe.apply}


func time_dependent_ops() -> Array:
	return [&"image.recipe"]


func param_kinds() -> Dictionary:
	return {"recipe": FxRecipeWidget.build}
