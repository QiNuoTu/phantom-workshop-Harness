class_name FxFiber
extends RefCounted
## 组件的实例（论文 Definition 44 的 fiber）。
##
## 生命周期只有两态，与论文 Figure 1 对齐：
##   INACTIVE  — 依赖未满足 / 已卸载
##   ACTIVE    — apply 已执行，scope 里攒着逆操作
##
## refresh() 就是论文 Algorithm 5 的同步简化版：
## 依赖从未满足到满足 → 激活；从满足到不满足 → 卸载并恢复；
## 仍满足但依赖值变化 → 只发 on_coeffects（neutral 通知）。
## 编辑器不需要异步惯性链，所以这里用同步实现，保留同样的语义顺序：
## 先停止提供，再卸载依赖者，最后执行逆操作。

var uid: int = 0
var component: FxComponent
var config: Dictionary = {}
var ctx: FxContext
var parent: FxFiber = null

var active: bool = false
## 退休标记（论文 Definition 44 的 𝜏 / O-Retire）。
## 退休是「编排器请求这个 fiber 停止存在」，与依赖是否满足正交：
## 没有它，一个无依赖的 fiber 在卸载时发出的 notify 会把自己重新激活。
var retired: bool = false
var scope: FxEffectScope = null
var committed_view: Dictionary = {}
var provided_keys: Array[String] = []


func refresh(keys: Array = []) -> void:
	if component == null or ctx == null:
		return
	# O-Retire 把 target 永久置为 ⊥；任何 notify 都不能让已退休的 fiber 复活。
	if retired:
		if active:
			_deactivate()
		return
	var target := ctx.satisfies(component.inject)
	if target and not active:
		_activate()
	elif not target and active:
		_deactivate()
	elif active and not keys.is_empty() and component.on_coeffects.is_valid():
		if _intersects(keys, component.inject):
			component.on_coeffects.call(ctx, keys)


## 供编排器显式卸载（O-Retire + L-Unload + O-Remove 的同步合并版）。
func dispose() -> void:
	retired = true
	_deactivate()
	if ctx != null:
		ctx._forget_fiber(self)


## 只发退休请求，让 notify 把它带回 INACTIVE（论文 O-Retire 与 O-Remove 分离）。
func retire() -> void:
	retired = true
	refresh()


func _activate() -> void:
	active = true
	scope = FxEffectScope.new()
	committed_view.clear()
	for key in component.inject:
		if ctx.values.has(key):
			committed_view[key] = ctx.values[key]
	if component.apply.is_valid():
		component.apply.call(ctx, config, scope)


func _deactivate() -> void:
	if not active:
		return
	# 先停止提供，让依赖者在本 fiber 的逆操作执行前看到“不再可用”。
	active = false
	ctx._remove_provisions(self)
	if scope != null:
		scope.dispose()
		scope = null
	committed_view.clear()
	provided_keys.clear()


func _intersects(changed: Array, inject: Array) -> bool:
	for key in changed:
		if key == "*" or inject.has(key):
			return true
	return false
