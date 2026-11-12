extends FxPlugin
## 节点创建面板插件：把「添加节点用什么 UI」从蓝图里彻底拆出来。
##
## 只贡献一个 node_pickers() 实现；蓝图通过 FxNodePickerBroker 取用。
## 停用本插件后，蓝图仍能打开、仍能编辑已有节点，只是「添加节点」没有弹窗
## （代理返回契约的空实现）—— 这正是服务代理相对硬编码的价值。

func node_pickers() -> Array[Dictionary]:
	return [{
		"id": "editor.node-picker",
		"label": "搜索式节点创建面板",
		"description": "编辑器内浮层：搜索 / 最近使用 / 键盘导航 / 按端口类型限定范围",
		"order": 10,
		"factory": FxNodePickerApi.create,
	}]
