class_name FxRenderGate
extends RefCounted
## 渲染闸门：后台渲染线程与「插件注册表变更」之间的一把互斥锁。
##
## 为什么需要它：渲染可以跑在工作线程上（不阻塞界面），而插件热重载会重建
## FxRegistry / FxCatalog / FxOpRegistry 这些**静态**表。一边读一边换表就是
## 未定义行为，轻则算错一帧，重则崩在 C++ 里。
##
## 约定（只有两条，越简单越不容易死锁）：
##   · 求一帧的过程持锁（工作线程 / 导出 / 单帧渲染都走同一把锁）；
##   · 插件表的结构性变更持同一把锁。
## 锁的持有时间都是"毫秒级的一次操作"，不做嵌套等待，所以不会互相饿死。

static var _mutex := Mutex.new()
## 有算子这一帧没准备好（例如 GPU 渲染目标刚建出来，首帧读回来是空的）。
## 谁遇到谁打标记，渲染服务在发布这一帧之后再补算一帧。
static var _reframe := false
## 主线程泵：只有渲染线程能碰的资源（离屏视口 / RenderingDevice / 纹理）由插件
## 在这里注册一个「每帧处理一批跨线程请求」的回调。
## 基座只提供「每帧回调一次」这个通用组合规则，**不认识 GPU / 着色器 / 子窗口**；
## 具体是什么设备、队列里放什么请求，全由插件决定。
static var _main_thread_pump: Callable = Callable()


static func mutex() -> Mutex:
	return _mutex


static func set_main_thread_pump(callback: Callable) -> void:
	_main_thread_pump = callback


## 渲染服务每个 process 调一次；没有插件注册时是零成本的空调用。
static func pump_main_thread() -> void:
	if _main_thread_pump.is_valid():
		_main_thread_pump.call()


static func has_main_thread_pump() -> bool:
	return _main_thread_pump.is_valid()


# 兼容旧名：早期版本把「主线程泵」叫成 GPU 泵，基座因此耦合了设备类型。
# 保留别名让外部插件不断，新代码一律用 main_thread_*。
static func set_gpu_pump(callback: Callable) -> void:
	set_main_thread_pump(callback)


static func pump_gpu() -> void:
	pump_main_thread()


static func has_gpu_pump() -> bool:
	return has_main_thread_pump()


## 请求「再算一帧」。
##
## GPU / 异步资源类算子在资源刚建好时常常要第二帧才出正确结果。它们没法自己
## 触发重算（也够不着渲染服务），就打个标记；渲染服务发布完当前帧会看到它，
## 把这一帧标记为脏帧，下一帧自然再算一遍。停顿住的图也能自愈。
static func request_reframe() -> void:
	_reframe = true


## 取走标记（读后即清）。
static func take_reframe() -> bool:
	var wanted := _reframe
	_reframe = false
	return wanted


## 便捷包装：持锁执行，异常时也保证解锁。
static func guarded(action: Callable) -> Variant:
	var mutex := _mutex
	mutex.lock()
	var result: Variant = action.call()
	mutex.unlock()
	return result
