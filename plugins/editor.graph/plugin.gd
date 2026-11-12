extends FxPlugin
## 蓝图画布：GraphEdit + 节点视图 + 内联参数 + 节点搜索面板。
## 面板、命令、菜单、工具栏都从这里注册，外壳不认识 GraphEdit。

func panels() -> Array[Dictionary]:
	return [{
		"id": "editor.graph",
		"title": "蓝图",
		"area": "center",
		"order": 10,
		"factory": FxGraphEditor.create,
	}]


func commands() -> Array[Dictionary]:
	return [
		{"id": "graph.add_node", "label": "添加节点…", "shortcut": "Shift+A",
			"category": "节点", "handler": FxGraphEditor.cmd_add_node},
		{"id": "graph.fit", "label": "适应视图", "shortcut": "F",
			"category": "节点", "handler": FxGraphEditor.cmd_fit_view},
		{"id": "graph.arrange", "label": "自动排列",
			"category": "节点", "handler": FxGraphEditor.cmd_arrange},
		{"id": "graph.pack", "label": "打包成子图", "shortcut": "Ctrl+G",
			"category": "节点", "handler": FxGraphEditor.cmd_pack},
		{"id": "graph.unpack", "label": "展开子图", "shortcut": "Ctrl+Shift+G",
			"category": "节点", "handler": FxGraphEditor.cmd_unpack},
	]


func menus() -> Array[Dictionary]:
	return [{"id": "node", "title": "节点", "order": 30}]


func menu_items() -> Array[Dictionary]:
	return [
		{"menu": "node", "label": "添加节点…", "command": "graph.add_node", "order": 10, "shortcut": "Shift+A"},
		{"menu": "node", "label": "自动排列", "command": "graph.arrange", "order": 20},
		{"menu": "node", "label": "适应视图", "command": "graph.fit", "order": 30, "shortcut": "F"},
		{"menu": "node", "label": "", "separator": true, "order": 35},
		{"menu": "node", "label": "打包成子图（预合成）", "command": "graph.pack", "order": 40, "shortcut": "Ctrl+G"},
		{"menu": "node", "label": "展开子图", "command": "graph.unpack", "order": 50, "shortcut": "Ctrl+Shift+G"},
	]


func toolbar() -> Array[Dictionary]:
	return [
		{"label": "添加节点", "command": "graph.add_node", "order": 110, "separator": true, "quick": true},
		{"label": "适应视图", "command": "graph.fit", "order": 120},
	]


## 蓝图默认收起预览：想看大图时点节点右下角的小三角展开即可。
func settings() -> Array[Dictionary]:
	return [
		{"id": "graph.preview_collapsed", "label": "节点预览默认收起", "group": "蓝图",
			"kind": "bool", "default": true, "applies": "none", "order": 10,
			"description": "加载工程后节点只占内容高度；单个节点的展开状态会被记住"},
	]
