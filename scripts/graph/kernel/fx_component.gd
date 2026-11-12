class_name FxComponent
extends RefCounted
## 组件声明（论文 Definition 43 的运行时形态）：
##   inject   —— 它从环境读取哪些 coeffect 键（依赖声明 d）
##   provide  —— 它允许向环境写入哪些键（供给声明 p）
##   apply    —— 激活时执行的效果函数 (ctx, config, scope)
##   on_coeffects —— 依赖变化但组件仍应保持激活时的通知（paper 的 neutral/activating 区分）
##
## 注意 apply 不直接“返回逆操作”，而是把逆操作登记进 scope；
## 这与论文的 effect iterator 等价，且更适合 GDScript 的 UI 生命周期。

var inject: Array[String] = []
var provide: Array[String] = []
var apply: Callable = Callable()
var on_coeffects: Callable = Callable()
var label: String = ""


static func make(p_inject: Array[String], p_apply: Callable,
		p_on_coeffects: Callable = Callable(), p_label: String = "") -> FxComponent:
	var component := FxComponent.new()
	component.inject = p_inject
	component.apply = p_apply
	component.on_coeffects = p_on_coeffects
	component.label = p_label
	return component
