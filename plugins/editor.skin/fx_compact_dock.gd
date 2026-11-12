class_name FxCompactDock
extends FxDockArea
## 示例「自定义停靠容器」：继承默认 FxDockArea，只改标签条密度与折叠条文案。
##
## 插件通过 dock_factories() 注册它，外壳的 _make_dock() 就会换成这个实现；
## 任何 FxDockArea 子类都能这样接进来，基座完全不认识具体类。

const BAR_HEIGHT: int = 22


static func create(area_id: String) -> FxDockArea:
	return FxCompactDock.new(area_id)


func _ready() -> void:
	super._ready()
	if _bar != null:
		_bar.custom_minimum_size.y = BAR_HEIGHT
	if _collapse_bar != null:
		_collapse_bar.tooltip_text = "展开紧凑停靠区"
	_rebuild_bar()


func _rebuild_bar() -> void:
	super._rebuild_bar()
	if _bar == null:
		return
	for cell in _bar.get_children():
		if cell is HBoxContainer:
			for child in (cell as HBoxContainer).get_children():
				if child is Control:
					(child as Control).custom_minimum_size.y = BAR_HEIGHT
		elif cell is Control:
			(cell as Control).custom_minimum_size.y = BAR_HEIGHT
