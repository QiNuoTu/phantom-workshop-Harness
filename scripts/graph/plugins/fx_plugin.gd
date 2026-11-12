class_name FxPlugin
extends RefCounted
## 插件基类（论文里“一切皆插件”的运行时形态）。
##
## 一个插件可以贡献这些，全部是数据/回调，不需要改外壳或执行器：
##   node_files()     节点定义     .json 路径（由 FxCatalog 统一加载）
##   ops()            算子         op_id -> Callable
##   native_ops()     原生算子     GDExtension 类的窄 ABI 绑定（C++ 性能算子）
##   time_dependent_ops()         会读时钟的算子（关闭跨帧缓存）
##   param_kinds()    参数控件     kind -> 构建函数（FxWidgetRegistry）
##   exporters()      导出格式     菜单项 + 处理函数
##   panels()         停靠面板     id/title/area/factory
##   windows()        浮动窗口     id/title/factory/size
##   commands()       命令         id/label/shortcut/handler
##   menus()          菜单定义     id/title/order
##   menu_items()     菜单项       menu/label/command/order
##   toolbar()        工具栏项     label/command/order
##   services()       服务工厂     id -> (ctx) -> Variant
##   skins()          皮肤         id/name/factory -> FxSkin
##   dock_factories() 停靠容器     id/name/factory(area) -> FxDockArea
##   settings()       设置条目     声明式配置（FxSettings 持久化 + 按字段协调）
##   capabilities()   能力代理     key/apply —— 多 provider 共存（§6.2）
##   quality_policies() 质量策略   局部覆盖渲染/算子质量
##   panel_features() 面板注入     target/label/command —— 含菜单项
##   locales()        语言包       locale/entries —— 多语言支持
##   graph_access()   图能力实现   id/factory -> FxGraphAccess（替换解释器核心）
##   render_backends() 渲染后端    id/factory -> FxRenderBackend（替换渲染器）
##   node_pickers()   节点选择器   id/factory -> FxNodePicker（替换创建节点弹窗）
##
## 生命周期：host 扫描 plugin.json → 加载 script → new() → setup() →
## 收集贡献 → 内置插件立刻释放实例（注册表只留静态 Callable）；
## 外部插件保留实例到 shutdown，否则实例方法的 Callable 会悬空。
##
## 硬性规则：**内置插件的算子/导出器/面板/命令必须是静态 Callable**，
## 不能捕获插件实例，否则静态注册表会活过插件对象，引擎退出时段错误。

var id: String = ""
var name: String = ""
var version: String = "1.0"
var description: String = ""
var manifest: Dictionary = {}
var plugin_dir: String = ""
var root_path: String = ""
var external: bool = false
var host = null  # FxPluginHost；不写类型，避免与宿主形成静态循环依赖


func setup(p_host, p_manifest: Dictionary, p_dir: String) -> void:
	host = p_host
	manifest = p_manifest
	plugin_dir = p_dir
	root_path = String(p_manifest.get("root", ""))
	external = bool(p_manifest.get("external", false))
	id = String(p_manifest.get("id", p_dir.get_file()))
	name = String(p_manifest.get("name", id))
	version = String(p_manifest.get("version", "1.0"))
	description = String(p_manifest.get("description", ""))


func activate() -> void:
	pass


func deactivate() -> void:
	pass


func ops() -> Dictionary:
	return {}


## 原生算子（GDExtension）。每项：{op, class, thread_safe}
##   op          算子 id，节点定义里的 "op" 直接写它，图不知道实现是 C++ 还是 GDScript
##   class       扩展里注册的类名（GDREGISTER_CLASS）；必须以 `fx_exec(inputs, params, env)`
##               的窄 ABI 暴露能力，细节见 FxNative
##   thread_safe 默认 true；false 时整条渲染链回退主线程（C++ 侧有可变状态就必须声明）
##
## 库本体的加载写在 plugin.json 的 `"native": {"library": "native/xxx.gdextension"}`，
## 宿主在激活插件前先加载，失败记到插件账本的 error 里，不影响其余贡献。
func native_ops() -> Array[Dictionary]:
	return []


## 声明哪些 op 会读时钟，执行器据此关闭跨帧缓存。
func time_dependent_ops() -> Array:
	return []


func node_files() -> Array[String]:
	return []


## 每项：{id, label, mode: "file"|"dir", suffix, default_suffix, handler(ctx)}
func exporters() -> Array[Dictionary]:
	return []


func param_kinds() -> Dictionary:
	return {}


## 每项：{id, title, area: center|left|right|bottom, order, factory(ctx)->Control,
##        min_size: Vector2, hidden: bool}
func panels() -> Array[Dictionary]:
	return []


## 每项：{id, title, factory(ctx)->Control, size: Vector2i, singleton: bool}
func windows() -> Array[Dictionary]:
	return []


## 每项：{id, label, shortcut: "Ctrl+S"|"Space", handler(ctx), category}
func commands() -> Array[Dictionary]:
	return []


## 每项：{id, title, order}
func menus() -> Array[Dictionary]:
	return []


## 每项：{menu, label, command, order, separator, shortcut}
func menu_items() -> Array[Dictionary]:
	return []


## 每项：{label, command, order, separator, toggle, menu}
## menu 目前支持 "exporters"：由外壳用已注册导出器动态生成弹出菜单。
func toolbar() -> Array[Dictionary]:
	return []


## id -> 工厂 Callable(ctx) -> Variant（Node / RefCounted / 纯数据）
## ctx: {shell, store, render, services, plugin_id}
func services() -> Dictionary:
	return {}


## 每项：{id, name, order, factory() -> FxSkin}
## 皮肤可以覆盖颜色 token、Theme 与控件工厂；基座只保留最小默认皮肤。
func skins() -> Array[Dictionary]:
	return []


## 每项：{id, name, order, factory(area: String) -> FxDockArea}
## 自定义停靠容器直接继承 FxDockArea 覆盖任意方法即可，外壳不认识具体实现。
func dock_factories() -> Array[Dictionary]:
	return []


## 每项：{id, label, group, kind: bool|int|float|enum|string|color,
##        default, min, max, step, options, description, order,
##        capability: 变化时交给哪个能力代理, applies: runtime|ui|none}
## 插件通过它把自己的运行时旋钮暴露到统一「设置」窗口；基座不解释语义。
func settings() -> Array[Dictionary]:
	return []


## 每项：{key, apply(value: Variant), order} —— 能力键的服务代理 provider。
## 同一个 key 允许多个插件共存，按 order 合并（§6.2）。
func capabilities() -> Array[Dictionary]:
	return []


## 每项：{apply(ctx: Dictionary, current: Dictionary) -> Dictionary, order}
## 只返回需要覆盖的字段即可；输出链永不降采样的不变量由基座守住。
func quality_policies() -> Array[Dictionary]:
	return []


## 每项：{target: panel_id|"*", label, command, menu, order, icon, separator}
## 注入到任意面板的标题菜单 / 上下文功能；面板通过 FxPanelBroker 消费。
func panel_features() -> Array[Dictionary]:
	return []


## 每项：{locale, name, entries: {原文: 译文}, order}
## 多个插件可以叠加同一语言；FxI18n 按 order 合并后提供回退链。
func locales() -> Array[Dictionary]:
	return []


## 每项：{id, label, order, factory() -> FxGraphAccess}
## 蓝图层只依赖 FxGraphFacade 代理；贡献一个实现就等于换掉整个图解释器。
func graph_access() -> Array[Dictionary]:
	return []


## 每项：{id, label, description, order, factory() -> FxRenderBackend}
## 渲染服务把「求一帧」委托给当前选中的后端；设置项 render.backend 可切换。
func render_backends() -> Array[Dictionary]:
	return []


## 每项：{id, label, order, factory(host: Node) -> FxNodePicker}
## 蓝图通过 FxNodePickerBroker 取得创建节点弹窗，停用本插件时安全降级。
func node_pickers() -> Array[Dictionary]:
	return []


## 每项：{id, order, extensions: ["png", ...], handler(ctx) -> int|{count, message}}
## 把文件拖进蓝图时由 FxDropBroker 调用；ctx: {files, position, shell, store, editor}。
## handler 必须是静态 Callable —— 它会被注册表长期持有。
## 状态栏片段：不认识具体插件语义的基座按 order 拼接这些纯函数。
func status_fragments() -> Array[Dictionary]:
	return []


## 时钟提供者：时间维度的组合规则（帧号推进、时间↔帧换算）。
func clocks() -> Array[Dictionary]:
	return []


func drop_handlers() -> Array[Dictionary]:
	return []


## 插件目录下的相对路径，避免插件里写死 res:// 前缀。
func local(relative: String) -> String:
	return plugin_dir.path_join(relative)
