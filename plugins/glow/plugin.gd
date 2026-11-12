extends FxPlugin
## 示例第三方插件：只靠清单 + 这个脚本就新增了 image.glow 节点。
## 没有改 FxCatalog / FxGraphRunner / 编辑器任何一行。
##
## 注意：ops() 返回的必须是**静态 Callable**（不绑定插件实例），
## 宿主只接受 get_object() == null 的 Callable。

func node_files() -> Array[String]:
	return [local("nodes.json")]


func ops() -> Dictionary:
	return {
		&"image.glow": FxGlowOps.apply,
	}
