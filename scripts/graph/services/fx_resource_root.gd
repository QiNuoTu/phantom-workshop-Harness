class_name FxResourceRoot
extends RefCounted
## 资源根解析（论文 §6.1「系统边界」的运行时形态）。
##
## 论文说：一个位置在边界外，是因为系统不能独占修改它、也不能恢复它；
## 把它 reify 成一个 coeffect，就等于把边界往内推了一格。这里做的是同一件事：
## 把「素材/插件目录」这种外部位置收进一个显式的、可枚举的根列表，
## 让运行时代码只依赖 `resolve()` 而不依赖 res:// 这一条物理路径。
##
## 优先级（先到先得）：
##   1. res://<relative>                     内置（PCK 内）
##   2. <exe 同级>/<relative>               便携（拷走即用，导出后主力）
##   3. user://<relative>                   用户安装（可写，可增删）
##   4. register_root() 额外根              插件注册的素材包 / 测试注入
##
## 为什么必须有 2/3：res:// 里的目录带 .gdignore 时 Godot 不会把它打进 PCK；
## 而且 186MB 的原始 PNG 本来也不该塞进包里。外部根让素材包和插件一样
## 是「可安装、可卸载、可替换」的单元，导出成 exe 后照样生效。
##
## 每个 register_root 都返回逆操作，删除时由调用方回放（可逆效应）。

static var _extra_roots: Array[String] = []


## 附加一个搜索根（绝对路径或 user:// 路径）。返回撤销用的逆操作。
static func register_root(root: String) -> Callable:
	if root.is_empty() or _extra_roots.has(root):
		return func() -> void: pass
	_extra_roots.append(root)
	return func() -> void:
		_extra_roots.erase(root)


static func clear_roots() -> void:
	_extra_roots.clear()


static func portable_dir() -> String:
	var exe := OS.get_executable_path()
	if exe.is_empty():
		return ""
	return exe.get_base_dir()


static func base_roots() -> Array[String]:
	var out: Array[String] = []
	_add(out, "res://")
	var portable := portable_dir()
	if not portable.is_empty():
		_add(out, portable)
	_add(out, "user://")
	for root in _extra_roots:
		_add(out, root)
	return out


## 所有可能存放 relative 的根，按顺序返回；不检查是否存在。
static func candidate_roots(relative: String) -> Array[String]:
	var out: Array[String] = []
	for base in base_roots():
		_add(out, base.path_join(relative))
	return out


## 只返回真实存在的根，供扫描器遍历。
static func existing_roots(relative: String) -> Array[String]:
	var out: Array[String] = []
	for root in candidate_roots(relative):
		if DirAccess.dir_exists_absolute(root):
			out.append(root)
	return out


## 解析一个相对文件路径，返回第一个可读的完整路径；找不到返回空串。
static func resolve(relative_path: String) -> String:
	for base in base_roots():
		var full := base.path_join(relative_path)
		if FileAccess.file_exists(full):
			return full
	return ""


static func _add(list: Array[String], path: String) -> void:
	if path.is_empty() or list.has(path):
		return
	list.append(path)
