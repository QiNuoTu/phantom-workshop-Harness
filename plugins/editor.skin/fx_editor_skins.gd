class_name FxEditorSkins
extends RefCounted
## 三套示例皮肤。每个工厂都返回一个 FxSkin，插件不需要改基座一行代码。
## 想做自己的皮肤：照这里复制一个函数，或在自己的插件里 extends FxSkin。


static func dark() -> FxSkin:
	var skin := FxSkin.new()
	skin.id = "dark"
	skin.display_name = "暗色 · 琥珀"
	skin.accent = Color("#ffb454")
	skin.accent_cool = Color("#4cc2ff")
	skin.button_pressed = Color("#3a3020")
	skin.selected = Color("#2c2a22")
	return skin


static func light() -> FxSkin:
	var skin := FxSkin.new()
	skin.id = "light"
	skin.display_name = "浅色 · 纸面"
	skin.bg = Color("#f2f4f8")
	skin.panel = Color("#ffffff")
	skin.panel_alt = Color("#e9edf4")
	skin.bar = Color("#e3e8f0")
	skin.border = Color("#c4cdda")
	skin.border_soft = Color("#dce2ec")
	skin.text = Color("#2c3648")
	skin.text_strong = Color("#111827")
	skin.muted = Color("#6b7688")
	skin.accent = Color("#b45309")
	skin.accent_cool = Color("#0369a1")
	skin.danger = Color("#b91c1c")
	skin.ok = Color("#15803d")
	skin.button_normal = Color("#e8edf5")
	skin.button_hover = Color("#d8e2f0")
	skin.button_pressed = Color("#c8d6ea")
	skin.button_border_hover = Color("#8fa5c0")
	skin.input_bg = Color("#ffffff")
	skin.selected = Color("#cfe0f7")
	skin.corner_radius = 5
	return skin


static func contrast() -> FxSkin:
	var skin := FxSkin.new()
	skin.id = "contrast"
	skin.display_name = "高对比 · 无障碍"
	skin.bg = Color("#000000")
	skin.panel = Color("#0a0a0a")
	skin.panel_alt = Color("#141414")
	skin.bar = Color("#000000")
	skin.border = Color("#ffffff")
	skin.border_soft = Color("#8a8a8a")
	skin.text = Color("#ffffff")
	skin.text_strong = Color("#ffffff")
	skin.muted = Color("#c8c8c8")
	skin.accent = Color("#ffd400")
	skin.accent_cool = Color("#64d8ff")
	skin.danger = Color("#ff5c5c")
	skin.ok = Color("#5cff9d")
	skin.button_normal = Color("#1a1a1a")
	skin.button_hover = Color("#333333")
	skin.button_pressed = Color("#4d4d00")
	skin.button_border_hover = Color("#ffd400")
	skin.input_bg = Color("#000000")
	skin.selected = Color("#4d4d00")
	skin.corner_radius = 0
	return skin
