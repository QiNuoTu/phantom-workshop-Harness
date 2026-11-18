extends FxPlugin
## 风格化 —— **只贡献节点定义**；28 个算子的实现全部在原生包 `fx.native-kit` 里。
##
## 为什么这里一个 `ops()` 都没有：同一段像素逻辑只留一份实现。
## 保留 GDScript 版本等于留下一条「原生没加载时悄悄慢十倍」的第二条路径，
## 而那条路径没人跑测试，漂移了也看不出来。
##
## 代价写在 manifest 里：本插件 `inject` 了 `plugin.fx.native-kit`，
## 没有它就不激活 —— 依赖不满足时「不生效」比「慢一点」诚实。

func node_files() -> Array[String]:
	return [local("nodes.json")]
