extends FxPlugin
## Godot 导出：PNG 当前帧 / 序列帧 / 精灵表 / 粒子发生器；同一套能力也有节点版本。
##
## 新增一种导出只需要往 exporters() 里加一项，再到 commands()/menu_items() 里
## 加对应入口；外壳与其它插件都不需要改。

## 导出能力的**节点版本**：菜单能做的事，图里也要能做（可组合、可自动化）。
func node_files() -> Array[String]:
	return [local("nodes_io.json")]


func ops() -> Dictionary:
	return {
		&"io.export_image": FxOpsExport.export_image,
		&"io.export_sequence": FxOpsExport.export_sequence,
		&"io.export_sheet": FxOpsExport.export_sheet,
		&"io.export_godot": FxOpsExport.export_godot,
		&"io.save_doc": FxOpsExport.save_doc,
	}


## 写盘节点会读文档与时间轴，不能吃跨帧缓存。
func time_dependent_ops() -> Array:
	return [&"io.export_sequence", &"io.export_sheet", &"io.export_godot", &"io.save_doc"]


func exporters() -> Array[Dictionary]:
	return [
		{
			"id": "png.frame",
			"label": "当前帧 PNG…",
			"mode": "file",
			"suffix": "*.png",
			"default_suffix": ".png",
			"handler": FxExportService.handler_frame,
		},
		{
			"id": "png.sequence",
			"label": "PNG 序列帧…",
			"mode": "dir",
			"handler": FxExportService.handler_sequence,
		},
		{
			"id": "png.sheet",
			"label": "精灵表 PNG + JSON…",
			"mode": "file",
			"suffix": "*.png",
			"default_suffix": ".png",
			"handler": FxExportService.handler_sheet,
		},
		{
			"id": "godot.particles",
			"label": "Godot 粒子发生器 (.tscn)…",
			"mode": "file",
			"suffix": "*.tscn",
			"default_suffix": "_emitter.tscn",
			"handler": FxExportService.handler_particles,
		},
	]


func commands() -> Array[Dictionary]:
	return [
		{"id": "export.frame", "label": "导出当前帧 PNG…", "category": "导出",
			"handler": FxExportService.cmd_frame},
		{"id": "export.sequence", "label": "导出 PNG 序列帧…", "category": "导出",
			"handler": FxExportService.cmd_sequence},
		{"id": "export.sheet", "label": "导出精灵表…", "category": "导出",
			"handler": FxExportService.cmd_sheet},
		{"id": "export.particles", "label": "导出 Godot 粒子发生器…", "category": "导出",
			"handler": FxExportService.cmd_particles},
	]


func menus() -> Array[Dictionary]:
	return [{"id": "export", "title": "导出", "order": 45}]


func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "export", "label": "当前帧 PNG…", "command": "export.frame", "order": 10},
		{"menu": "export", "label": "PNG 序列帧…", "command": "export.sequence", "order": 20},
		{"menu": "export", "label": "精灵表 PNG + JSON…", "command": "export.sheet", "order": 30},
		{"menu": "export", "label": "", "separator": true, "order": 40},
		{"menu": "export", "label": "Godot 粒子发生器 (.tscn)…", "command": "export.particles", "order": 50},
	]


func toolbar() -> Array[Dictionary]:
	return [{"label": "导出", "menu": "exporters", "order": 300, "separator": true, "quick": true}]
