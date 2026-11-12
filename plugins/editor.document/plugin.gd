extends FxPlugin
## 文档：属性面板 + 新建/打开/保存服务 + 撤销重做命令。
##
## 这是“功能即插件”的典型：连“打开文件”都不在基座里。

func panels() -> Array[Dictionary]:
	return [{
		"id": "editor.document",
		"title": "文档",
		"area": "left",
		"order": 10,
		"factory": FxDocumentPanel.create,
	}]


func services() -> Dictionary:
	return {"document": FxDocumentActions.create}


func commands() -> Array[Dictionary]:
	return [
		{"id": "doc.new", "label": "新建", "shortcut": "Ctrl+N", "category": "文件",
			"handler": FxDocumentActions.cmd_new},
		{"id": "doc.open", "label": "打开…", "shortcut": "Ctrl+O", "category": "文件",
			"handler": FxDocumentActions.cmd_open},
		{"id": "doc.save", "label": "保存", "shortcut": "Ctrl+S", "category": "文件",
			"handler": FxDocumentActions.cmd_save},
		{"id": "doc.save_as", "label": "另存为…", "shortcut": "Ctrl+Shift+S", "category": "文件",
			"handler": FxDocumentActions.cmd_save_as},
		{"id": "project.welcome", "label": "欢迎页", "category": "文件",
			"handler": FxDocumentActions.cmd_welcome},
		{"id": "project.deps", "label": "依赖检查…", "category": "文件",
			"handler": FxDocumentActions.cmd_deps},
		{"id": "edit.undo", "label": "撤销", "shortcut": "Ctrl+Z", "category": "编辑",
			"handler": FxDocumentActions.cmd_undo},
		{"id": "edit.redo", "label": "重做", "shortcut": "Ctrl+Shift+Z", "category": "编辑",
			"handler": FxDocumentActions.cmd_redo},
		{"id": "edit.delete", "label": "删除选中节点", "shortcut": "Delete", "category": "编辑",
			"handler": FxDocumentActions.cmd_delete_selected},
		{"id": "app.quit", "label": "退出", "category": "应用",
			"handler": FxDocumentActions.cmd_quit},
	]


func menus() -> Array[Dictionary]:
	return [
		{"id": "file", "title": "文件", "order": 10},
		{"id": "edit", "title": "编辑", "order": 20},
	]


func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "file", "label": "新建", "command": "doc.new", "order": 10, "shortcut": "Ctrl+N"},
		{"menu": "file", "label": "打开…", "command": "doc.open", "order": 20, "shortcut": "Ctrl+O"},
		{"menu": "file", "label": "保存", "command": "doc.save", "order": 30, "shortcut": "Ctrl+S"},
		{"menu": "file", "label": "另存为…", "command": "doc.save_as", "order": 40, "shortcut": "Ctrl+Shift+S"},
		{"menu": "file", "label": "欢迎页…", "command": "project.welcome", "order": 60},
		{"menu": "file", "label": "依赖检查…", "command": "project.deps", "order": 65},
		{"menu": "file", "label": "", "separator": true, "order": 80},
		{"menu": "file", "label": "退出", "command": "app.quit", "order": 90},
		{"menu": "edit", "label": "撤销", "command": "edit.undo", "order": 10, "shortcut": "Ctrl+Z"},
		{"menu": "edit", "label": "重做", "command": "edit.redo", "order": 20, "shortcut": "Ctrl+Shift+Z"},
		{"menu": "edit", "label": "", "separator": true, "order": 25},
		{"menu": "edit", "label": "删除选中节点", "command": "edit.delete", "order": 30, "shortcut": "Delete"},
	]


func toolbar() -> Array[Dictionary]:
	return [
		{"label": "新建", "command": "doc.new", "order": 10},
		{"label": "打开", "command": "doc.open", "order": 20},
		{"label": "保存", "command": "doc.save", "order": 30},
		{"label": "", "separator": true, "order": 40},
		{"label": "撤销", "command": "edit.undo", "order": 50, "shortcut": "Ctrl+Z"},
		{"label": "重做", "command": "edit.redo", "order": 60, "shortcut": "Ctrl+Shift+Z"},
	]


## 工程级设置：欢迎页开关与定时保存间隔（0 = 关闭）。
func settings() -> Array[Dictionary]:
	return [
		{"id": "project.show_welcome", "label": "启动时显示欢迎页", "group": "工程",
			"kind": "bool", "default": true, "applies": "none", "order": 10,
			"description": "欢迎页可打开最近工程、新建或加载工程包"},
		{"id": "project.autosave_seconds", "label": "定时保存间隔（秒）", "group": "工程",
			"kind": "int", "default": 60, "min": 0, "max": 3600, "step": 10,
			"applies": "none", "order": 20,
			"description": "0 = 关闭；自动保存写到工程旁边同名文件夹，文件名带时间戳"},
		{"id": "ui.native_file_dialog", "label": "使用系统文件对话框", "group": "常规",
			"kind": "bool", "default": true, "applies": "none", "order": 30,
			"description": "打开/保存工程与选择素材时使用操作系统自带的文件面板，支持收藏夹与网络路径；关闭则用应用内面板"},
		{"id": "ui.native_windows", "label": "弹窗使用独立系统窗口", "group": "常规",
			"kind": "bool", "default": true, "applies": "none", "order": 31,
			"description": "保存面板、欢迎页、依赖提示等弹窗各自成为独立窗口（标题栏由系统绘制，可拖出主窗口、可最小化）；关闭则嵌在主窗口里显示"},
	]
