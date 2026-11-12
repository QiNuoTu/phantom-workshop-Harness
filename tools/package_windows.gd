extends SceneTree
## 导出后置步骤：把「外部资源根」拷到 exe 旁边，生成便携目录结构。
##
## 用法（先导出，再执行）：
##   godot --headless --path . --export-release "Windows Desktop"
##   godot --headless --path . --script res://tools/package_windows.gd -- ../dist
##
## 不做的事：不修改 PCK、不重新导出、不写注册表。
## bin/ 里的插件清单/节点 JSON/脚本已由 export_presets.cfg 打进 PCK；
## 这里只搬运两样「不该进包」的东西：
##   · plugins/<id>/assets 插件自带的外部素材（.gdignore，不进 PCK，跟着插件走）
##   · plugins/            外部插件目录（用户可往里放自己的插件）
##
## 运行期由 FxResourceRoot / FxPluginHost 按 <exe>/... 解析，拷走整个目录即可用。

const DEFAULT_DIST := "../dist"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var dist := DEFAULT_DIST
	for arg in args:
		if not arg.begins_with("--"):
			dist = String(arg)
			break
	var raw := dist if dist.is_absolute_path() else ProjectSettings.globalize_path("res://".path_join(dist))
	var abs_dist := raw.simplify_path()
	if not DirAccess.dir_exists_absolute(abs_dist):
		DirAccess.make_dir_recursive_absolute(abs_dist)
	print("== 便携目录：%s ==" % abs_dist)

	# 插件只有一种形态：整个 plugins/ 目录原样搬到便携目录，
	# 用户可以直接打开、修改、替换任何插件（素材也各自在插件目录里）。
	_copy_tree("res://plugins", abs_dist.path_join("plugins"))
	_prepare_plugin_dir(abs_dist.path_join("plugins"))
	# 插件契约文档随包发布，用户在外置目录里就能查
	if FileAccess.file_exists("res://README.md"):
		DirAccess.copy_absolute(ProjectSettings.globalize_path("res://README.md"),
			abs_dist.path_join("README.md"))
	_write_readme(abs_dist)
	print("完成。把整个目录拷走，双击 exe 即可；插件放 plugins/<id>/ 下。")
	quit(0)


func _copy_tree(src: String, dst: String) -> void:
	var dir := DirAccess.open(src)
	if dir == null:
		push_warning("找不到源目录：%s" % src)
		return
	DirAccess.make_dir_recursive_absolute(dst)
	dir.list_dir_begin()
	var name := dir.get_next()
	var files := 0
	while not name.is_empty():
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		var from := src.path_join(name)
		var to := dst.path_join(name)
		if dir.current_is_dir():
			_copy_tree(from, to)
		else:
			DirAccess.copy_absolute(ProjectSettings.globalize_path(from), to)
			files += 1
		name = dir.get_next()
	dir.list_dir_end()
	print("  %s → %s（本层 %d 个文件）" % [src, dst, files])


func _prepare_plugin_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(path)
	var note := FileAccess.open(path.path_join("放插件到这里.txt"), FileAccess.WRITE)
	if note != null:
		note.store_string("把插件目录整包放进本文件夹；插件契约见随包 README.md。\n"
			+ "例如：plugins/my.pack/plugin.json + plugin.gd + nodes.json\n"
			+ "重启或在「插件」菜单点「重新扫描」即可生效，无需重新导出 exe。\n")
		note.close()
	print("  plugins/ 外部插件目录就绪")


func _write_readme(dist: String) -> void:
	var f := FileAccess.open(dist.path_join("说明.txt"), FileAccess.WRITE)
	if f == null:
		return
	f.store_string("幻像工坊 · 便携版\n"
		+ "==================\n\n"
		+ "幻像工坊.exe + 幻像工坊.pck   程序与内置插件（已打进 PCK）\n"
		+ "plugins/core.asset/assets/    pixelfx 素材包（随插件，可删）\n"
		+ "plugins/skin.maid-atelier/assets/ 皮肤贴图包（随插件，含第三方许可素材）\n"
		+ "README.md                     插件契约与架构说明\n"
		+ "plugins/                      外部插件目录（放插件即可扩展）\n"
		+ "user://plugins/               用户插件目录（AppData 下，同样有效）\n\n"
		+ "三个插件根按 内置 → 便携 → 用户 顺序扫描，同 id 先到先得。\n"
		+ "删掉 plugins/core.asset/assets 软件仍可启动，只是没有 pixelfx 素材。\n"
		+ "删掉 plugins/skin.maid-atelier/assets 皮肤自动回落为纯色/几何装饰，不会崩。\n\n"
		+ "【许可提示】plugins/skin.maid-atelier/assets/ 内的美术素材来自\n"
		+ "smalltailqwq/dsh-client-ui-skin-maid-atelier，采用 CC BY-NC-SA 4.0：\n"
		+ "署名 / 非商业性使用 / 相同方式共享。完整创作链见该目录 NOTICE.md，\n"
		+ "许可全文见 LICENSE-ARTWORK.txt。商业发行前必须移除整个目录；\n"
		+ "这些图片未打进 pck，仅作为可卸载的外部资源随便携目录提供。\n")
	f.close()
