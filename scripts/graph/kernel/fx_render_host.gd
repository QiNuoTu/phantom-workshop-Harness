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


## 文档内容变了：作废执行器缓存。空实现：没有缓存可作废。
func invalidate() -> void:
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
