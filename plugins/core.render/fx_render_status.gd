class_name FxRenderStatus
extends RefCounted
## 渲染统计的状态栏片段（由 `core.render` 通过 `status_fragments()` 贡献）。
##
## 这段文案以前硬编码在 `scripts/graph/ui/fx_shell.gd` 里：基座要认识
## 「缓存 / 预渲染 / 并行线程 / 帧命中 / 缓冲 / 定格」这些纯渲染领域字段，
## 每加一种状态就得改基座。按时空可组合范式，时间维度（帧与缓存）由插件
## 自己描述，基座只负责「通用部分 + 按 order 拼接片段 + 映射三种通用语气色」。

## 返回 {text: String, tone: String}；tone 为空表示不改颜色。
## 必须是零副作用的静态函数：状态栏每 0.2s 调一次，可能在没有渲染服务时调用。
static func fragment(stats: Dictionary) -> Dictionary:
	var text := ""
	var tone := ""
	var cached: Variant = stats.get("cache")
	if cached is Dictionary:
		var info: Dictionary = cached
		var ready := int(info.get("ready", 0))
		var total := int(info.get("total", 0))
		var pending := int(info.get("pending", 0))
		var prefetch: Variant = info.get("prefetch")
		var active := prefetch is Dictionary and bool((prefetch as Dictionary).get("active", false))
		if total > 0:
			text += " · 缓存 %d/%d" % [ready, total]
			if ready >= total:
				tone = "ok"
			elif active or pending > 0:
				tone = "accent"
			if active:
				var progress: Dictionary = prefetch
				text += " · 预渲染 %d/%d" % [
					int(progress.get("done", 0)), int(progress.get("total", 0)),
				]
				var workers := int(progress.get("workers", 0))
				if workers > 1:
					text += " ×%d线程" % workers
	# 播放期：缓冲中 / 定格 / 命中，三者互斥。
	if stats.has("buffering"):
		text += " · 缓冲 f%d" % int(stats.get("buffering", 0))
		tone = "accent"
	elif bool(stats.get("paused", false)):
		text += " · 定格 f%d" % int(stats.get("frame", 0))
	elif bool(stats.get("cached", false)):
		text += " · 帧 %d 命中" % int(stats.get("frame", 0))
	return {"text": text, "tone": tone}

## 启动诊断：缓存落在哪、配额多少。基座不该直接摸 render.cache 的内部字段，
## 所以由本插件把领域对象翻译成一行纯文本。
static func diagnostic(render_service: Variant) -> String:
	if render_service == null or not render_service is Object:
		return ""
	var cache_obj: Variant = (render_service as Object).get("cache")
	if not cache_obj is Object:
		return ""
	var cache: Object = cache_obj
	return "帧缓存：%s · 位置 %s · 磁盘 %s · 上限 %d MB" % [
		ProjectSettings.globalize_path(String(cache.get("root_dir"))),
		String(cache.get("location")),
		"开" if bool(cache.get("disk_enabled")) else "关（纯内存）",
		int(cache.get("max_disk_bytes")) / (1024 * 1024),
	]
