extends SceneTree
func _initialize() -> void:
	FxPluginHost.ensure()
	FxSettings.ensure()
	FxSettings.apply_all()
	print("pack entries zh=", FxI18n.coverage())
	FxSettings.set_value("general.locale", "en_US")
	for key in ["窗口", "文件", "插件", "插件中心", "设置中心", "渲染质量", "深海女仆工坊", "启用皮肤贴图", "界面语言"]:
		print("  %-12s -> %s" % [key, FxI18n.text(key)])
	print("en coverage=", FxI18n.coverage())
	FxSettings.set_value("general.locale", "zh_CN")
	FxPluginHost.shutdown()
	quit(0)
