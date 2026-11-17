class_name FxRenderHost
extends Node
## 呈现器契约（论文 §6.2 Service Broker）：基座只认识「有个东西负责把文档+时间
## 变成图像」，不认识它是 CPU 求值、GPU 服务器、还是别的实现。
##
## 这里同时是**空呈现器**：不渲染、不缓存，只维护播放状态。
## 停用 `core.render` 之后外壳照常启动、菜单照常出现、按钮照常按下 ——
## 只是没有画面。这正是「可卸载」的含义：缺一个插件不该让整个软件解析失败。
## 旧实现让外壳 `FxRenderService.new()` 兜底，等于把插件的类名钉死在基座里，
## 插件目录一删基座就编译不过 —— 那不是微内核，是硬编码。

signal rendered(image: Image, stats: Dictionary)
signal stats_changed(stats: Dictionary)
signal playback_changed(playing: bool)

## 文档上下文。外壳负责注入；没有文档时保持 null。
var store: FxDocumentStore = null
## 播放状态由呈现器持有：外壳只读、只发命令，不实现时钟。
var playing: bool = false
## 为 false 时只标记脏、不自动渲染（批处理 / 导出期间临时关闭）。
var auto_render: bool = true
## 暂停时质量档：0 = 交互预览，1 = 精确。播放档由策略代理决定。
var quality: int = 1


func setup(p_store: FxDocumentStore) -> void:
	store = p_store


## 设置变化后重新解析质量策略。空实现：没有呈现器就没有策略。
func apply_policy() -> void:
	pass


## 作废派生结果。`kind` 是**影响面**，不是调用者身份：
##
##   · `content` —— 像素内容身份变了：整段帧缓存必须重建（默认，旧语义）；
##   · `derived` —— 内容没变、算法变了（质量档/算子系数）：保留已算好的精确帧，
##                  只丢静态求值表、节点样张与显示层；
##   · `display` —— 只影响贴屏那一步（后处理强度）：连求值结果都不用动。
##
## 为什么由基座传这个字符串：只有设置声明者知道「这一项改的是像素、是算法，还是仅调度」。
## 基座不解释它的含义，只做转达 —— 空实现连转达都免了。
##
## `source` 是**谁要求的**（设置项 id / 命令 id / 空 = 文档变更）。它只进归因日志，
## 不参与任何判断：把「谁让缓存失效」记下来，才不会出现「重建了 24 次但没人知道为什么」。
func invalidate(_kind: String = "content", _source: String = "") -> void:
	pass


## 帧缓存重建的归因日志（只读，最近若干条）。
## 空实现返回空表：没有呈现器就没有缓存，也就没有重建可查。
## 诊断（`diag.cache`）只经这条契约取数，不认识任何具体呈现器。
func cache_trace() -> Array:
	return []


## 清空归因日志（诊断用来「从现在开始记」）。空实现：没有日志可清。
func cache_reset_trace() -> void:
	pass


func set_playing(value: bool) -> void:
	if playing == value:
		return
	playing = value
	playback_changed.emit(playing)


func toggle_playback() -> void:
	set_playing(not playing)


func last_image() -> Image:
	return null


func last_stats() -> Dictionary:
	return {}
