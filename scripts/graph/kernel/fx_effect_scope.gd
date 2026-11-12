class_name FxEffectScope
extends RefCounted
## 可逆效果的累积器（论文 Definition 2 / Algorithm 1 的 Godot 版）。
##
## 一个组件做的每一件事都通过 add(inverse) 登记逆操作；卸载时按 LIFO 顺序全部执行，
## 于是“组件消失”与“它造成的副作用消失”是同一件事。UI 事件连接、节点、定时器、
## 子组件都通过这里回收，不写 deactivate() 里的手工清理清单。
##
## 论文强调 inverse 只在**施加效果的那个状态**上被要求成立；这里的逆操作通常是
## “恢复快照”或“释放某个具体对象”，两者都满足这个约束。

var _disposers: Array[Callable] = []
var _disposed: bool = false


func add(disposer: Callable) -> Callable:
	if not disposer.is_valid():
		return disposer
	if _disposed:
		# 已卸载的作用域里再登记效果：立刻反向执行，避免泄漏。
		disposer.call()
		return disposer
	_disposers.append(disposer)
	return disposer


func add_node_to_free(node: Node) -> void:
	if node == null:
		return
	add(func() -> void:
		if is_instance_valid(node):
			node.queue_free()
	)


func add_signal(signal_ref: Signal, callable: Callable) -> void:
	if not signal_ref.is_connected(callable):
		signal_ref.connect(callable)
	add(func() -> void:
		if signal_ref.is_connected(callable):
			signal_ref.disconnect(callable)
	)


func is_disposed() -> bool:
	return _disposed


## 逆序执行所有逆操作。幂等：第二次调用不会重复恢复。
func dispose() -> void:
	if _disposed:
		return
	_disposed = true
	for i in range(_disposers.size() - 1, -1, -1):
		var disposer: Callable = _disposers[i]
		if disposer.is_valid():
			disposer.call()
	_disposers.clear()
