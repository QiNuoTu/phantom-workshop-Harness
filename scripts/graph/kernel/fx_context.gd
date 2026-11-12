class_name FxContext
extends RefCounted
## 统一上下文（论文 Definition 32 的运行时简化）：
##   values / providers —— 余效果上下文 Σ：键 → 值，键 → 提供者 fiber
##   fibers            —— 活动组件实例表
##   changed(keys)     —— 键变化通知；组件按自己的 inject 规格被激活/通知/卸载
##
## 这里刻意不把“文档”“选中节点”“时间”写死成字段：
## 它们只是键。节点内联编辑器、底部轨道、输出预览都是消费者，各自声明依赖。
## 新增一种上下文（比如“资产库版本”“字体列表”）不需要改任何组件的基类。

signal changed(keys: Array)

var values: Dictionary = {}
var providers: Dictionary = {}
var fibers: Array[FxFiber] = []

var _next_uid: int = 1
var _notifying: bool = false
var _pending: Array = []


func get_value(key: String, fallback: Variant = null) -> Variant:
	return values.get(key, fallback)


func has_key(key: String) -> bool:
	return values.has(key) and values[key] != null


## 依赖规格是否满足（论文 𝛾 ⊧ d 的运行时判定）。
func satisfies(keys: Array[String]) -> bool:
	for key in keys:
		if not has_key(key):
			return false
	return true


## 实例化一个组件（O-Insert + L-Reload）。返回的 fiber 由调用方持有；
## 节点/面板销毁时调用 fiber.dispose()，其 scope 会自动回收所有逆操作。
func use(component: FxComponent, config: Dictionary = {}, parent: FxFiber = null) -> FxFiber:
	var fiber := FxFiber.new()
	fiber.uid = _next_uid
	_next_uid += 1
	fiber.component = component
	fiber.config = config
	fiber.ctx = self
	fiber.parent = parent
	fibers.append(fiber)
	fiber.refresh()
	return fiber


## 写入一个 coeffect 键，返回逆操作（恢复旧值）。这是所有 UI 状态的唯一写入口。
func set_value(key: String, value: Variant) -> Callable:
	var had := values.has(key)
	var old: Variant = values.get(key)
	values[key] = value
	notify([key])
	var disposed := false
	return func() -> void:
		if disposed:
			return
		disposed = true
		if had:
			values[key] = old
		else:
			values.erase(key)
		notify([key])


## 组件向环境提供键（p）。只有 provide 声明过的键才允许写。
func provide(fiber: FxFiber, key: String, value: Variant) -> void:
	if fiber == null or fiber.component == null:
		return
	if not fiber.component.provide.has(key):
		push_error("FxContext：组件 %s 未声明 provide(%s)" % [fiber.component.label, key])
		return
	values[key] = value
	providers[key] = fiber.uid
	if not fiber.provided_keys.has(key):
		fiber.provided_keys.append(key)
	notify([key])


func _remove_provisions(fiber: FxFiber) -> void:
	if fiber.provided_keys.is_empty():
		return
	var changed_keys: Array = []
	for key in fiber.provided_keys.duplicate():
		if int(providers.get(key, -1)) == fiber.uid:
			providers.erase(key)
			values.erase(key)
			changed_keys.append(key)
	fiber.provided_keys.clear()
	if not changed_keys.is_empty():
		notify(changed_keys)


func _forget_fiber(fiber: FxFiber) -> void:
	fibers.erase(fiber)


## 通知依赖者。重入安全：回调里再次 set_value 会排队到当前批次之后。
func notify(keys: Array) -> void:
	if keys.is_empty():
		return
	if _notifying:
		for key in keys:
			if not _pending.has(key):
				_pending.append(key)
		return
	_notifying = true
	var batch: Array = keys.duplicate()
	while not batch.is_empty():
		changed.emit(batch)
		for fiber in fibers.duplicate():
			if is_instance_valid(fiber):
				fiber.refresh(batch)
		batch = _pending.duplicate()
		_pending.clear()
	_notifying = false


func dispose_all() -> void:
	for fiber in fibers.duplicate():
		if is_instance_valid(fiber):
			fiber.dispose()
	fibers.clear()
