class_name FxEvalContext
extends RefCounted
## 一次求值的上下文：时间、画布、缓存、循环变量、素材、状态。
##
## 刻意不继承 Node：执行器可以在无头/导出/批处理里跑，不需要场景树。
## 所有“跨节点共享但只属于本次执行”的东西都放这里，算子之间不互相认识。
## ctx.flow 由执行器注入（follow 执行出口），执行结束后清空以断开引用环。

var doc: Dictionary = {}
var canvas: Vector2i = Vector2i(128, 128)
var t: float = 0.0
var fps: float = 30.0
var duration: float = 1.0
var loop: bool = true
var seed: int = 1

var outputs: Dictionary = {}
## 每个节点本帧真正用到的参数（关键帧已采样、端口已回填）。
## 编辑器用它显示「被连线驱动的参数」当前值，核心不认识 UI。
var node_params: Dictionary = {}
var previews: Dictionary = {}
var evaluating: Dictionary = {}
var volatile: Dictionary = {}
## 时间相关节点（自身或上游有轨道/时间算子）。执行器用它决定能否跨帧复用结果。
var time_dependent: Dictionary = {}
var assets: Dictionary = {}
var state: Dictionary = {}
var loop_vars: Array[Dictionary] = []
## 子图边界：外层经连线传进来的值（键 = 子图输入端口的 id），
## 以及子图内部「输出节点」写回给外层的值。两者都只活这一次求值。
var subgraph_inputs: Dictionary = {}
var subgraph_outputs: Dictionary = {}
## 子图组合的**作用域状态**：递归路径栈与内层执行器池。
##
## 时空可组合范式里，「空间组合」（子图嵌套）的运行时状态必须属于这一次求值，
## 不能是进程级静态单例：预渲染有 6 条线程并行求帧，共享 runner 会让 A 线程的
## evaluating / doc / 索引被 B 线程覆盖，报出「检测到循环依赖 s_out」这种假错误。
## 放在 ctx 上，线程隔离与嵌套隔离天然同时成立。
var subgraph_stack: Array[String] = []
var subgraph_runners: Dictionary = {}

var timings: Dictionary = {}
var steps: int = 0
var max_steps: int = 20000
var loop_ticks: int = 0
var max_loop_ticks: int = 8192
## 0 = 交互预览（可用降采样近似）；1 = 精确（导出/测试）。
var quality: int = 1
## 算子级质量系数 [0,1]：由质量策略代理注入，算子自己决定怎么用。
## 插件可以贡献策略覆盖它，也可以往 options 里放任意自定义旋钮。
var operator_quality: float = 1.0
var options: Dictionary = {}
var capture_previews: bool = true
var preview_limit: int = 128

var warnings: Array[String] = []

## 执行器注入：follow(node_id, exec_port_id) -> void。控制流算子靠它推进。
var flow: Callable = Callable()


func step() -> bool:
	steps += 1
	if steps <= max_steps:
		return true
	push_error("FxEvalContext：单帧执行步数超过 %d，已中止（检查循环上限）" % max_steps)
	warn("执行步数超限，已中止")
	return false


func loop_tick() -> bool:
	loop_ticks += 1
	if loop_ticks <= max_loop_ticks:
		return true
	push_error("FxEvalContext：循环次数超过 %d，已中止" % max_loop_ticks)
	warn("循环次数超限，已中止")
	return false


func follow(node_id: String, port_id: String) -> void:
	if flow.is_valid():
		flow.call(node_id, port_id)


func push_var(key: String, value: Variant) -> void:
	loop_vars.append({"name": key, "value": value})


func pop_var() -> void:
	if not loop_vars.is_empty():
		loop_vars.pop_back()


## 由内向外找同名循环变量；找不到返回 fallback。
func var_of(key: String, fallback: Variant = 0) -> Variant:
	for i in range(loop_vars.size() - 1, -1, -1):
		var frame: Dictionary = loop_vars[i]
		if String(frame.get("name", "")) == key:
			return frame.get("value", fallback)
	return fallback


## 读质量策略里的自定义旋钮；策略没提供时使用算子自带默认值。
func option(key: String, fallback: Variant = null) -> Variant:
	return options.get(key, fallback)


func int_option(key: String, fallback: int) -> int:
	return int(options.get(key, fallback))


func float_option(key: String, fallback: float) -> float:
	return float(options.get(key, fallback))


func bool_option(key: String, fallback: bool) -> bool:
	return bool(options.get(key, fallback))


## 节点专属随机种子：同图同 id 必得同一序列，预览与导出一致。
func node_seed(node_id: String) -> int:
	return abs(hash(node_id) + seed * 7919 + 17)


## 读图片，带缓存。res:// 走 Texture2D（编辑器导入），其余走 Image.load_from_file。
func load_image(path: String) -> Image:
	var key := path.strip_edges()
	if key.is_empty():
		return null
	if assets.has(key):
		return assets[key] as Image
	var image: Image = null
	if ResourceLoader.exists(key):
		var res: Resource = load(key)
		if res is Texture2D:
			image = (res as Texture2D).get_image()
		elif res is Image:
			image = res
	if image == null and FileAccess.file_exists(key):
		image = Image.load_from_file(key)
	if image == null:
		warn("读不到图片：%s" % key)
	assets[key] = image
	return image


func warn(message: String) -> void:
	if not warnings.has(message):
		warnings.append(message)
