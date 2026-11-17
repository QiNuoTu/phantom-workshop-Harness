class_name FxNativeBridge
extends RefCounted
## 像素内核扩展（GDExtension）的薄封装层。
##
## 三条原则：
## 1. **扩展不存在也能跑**：不可用时一律返回 `null` / `false`，调用方走原 GDScript 实现。
##    所以 `.gdextension` 在、DLL 没编出来时工程照样启动（只是慢一些）。
## 2. **不认识节点类型**：只暴露通用图元（点运算 / 重采样 / 合成），
##    每个算子的语义仍然由它在 GDScript 侧那一段决定。
## 3. **线程数显式传**：主线程可以多线程，预渲染工作线程传 1 ——
##    它们本来就按帧并行了，再各自开满线程只会互相抢核。
##
## 环境变量 `FX_NATIVE=0` 可全局关掉（做 A/B 对照、排查「原生路径算错了」时用）。

## 五个算子族各是一个原生类。桥按「函数属于哪一族」取实例：
## 某一族没注册（只编出一半、或装了旧版 DLL）时，只有那几个算子回落 GDScript，
## 其余照常走原生 —— 这就是「一族一个类」换来的失败粒度。
## 能力键：「原生实现由谁提供」。插件 `pixels.native` 贡献它，桥只在它存在时用原生。
## 这样「停用插件」与「库没编」走同一条回落路径，不需要桥认识任何插件 id。
const CAPABILITY := "pixels.native"

const FAMILY_CLASSES := {
	"point": "FxNativePoint",
	"warp": "FxNativeWarp",
	"blend": "FxNativeBlend",
	"edge": "FxNativeEdge",
	"gen": "FxNativeGen",
}

static var _apis: Dictionary = {}
static var _enabled: bool = OS.get_environment("FX_NATIVE") != "0"
static var _calls: int = 0
static var _misses: int = 0


static func enabled() -> bool:
	return _enabled


## 测试与诊断用：临时关掉原生路径做逐字节对照。
## 插件 `pixels.native` 的 activate/deactivate 也走这里 —— 停用插件=真的回落 GDScript。
static func set_enabled(value: bool) -> void:
	_enabled = value
	_apis.clear()


## 某一族的原生实例。`ClassDB.instantiate` 而不是直接写类名：
## 扩展缺席时裸类名会在**解析期**就报「标识符不存在」，整份脚本都加载不了。
## 实际使用入口：开关 + 能力键都成立才返回实例。
static func api(family: String = "point") -> Object:
	if not _enabled or not _provided():
		return null
	return _instance(family)


## 真实探测：只问"库在不在、这个类注册了没"，不看插件是否被停用。
## 诊断要的是硬件事实，`api()` 要的是"现在能不能用"，两者不能混。
static func _instance(family: String = "point") -> Object:
	if not _enabled:
		return null
	if _apis.has(family):
		var kept: Variant = _apis[family]
		if is_instance_valid(kept):
			return kept as Object
		_apis.erase(family)
		return null
	var cls := String(FAMILY_CLASSES.get(family, ""))
	if cls.is_empty() or not ClassDB.class_exists(cls):
		_apis[family] = null
		return null
	var created: Variant = ClassDB.instantiate(cls)
	var handle: Object = created as Object if created is Object else null
	_apis[family] = handle
	return handle


## 原生实现当前是否被提供。
##
## 宿主还没起来时（探针 / 单测 / 单独跑某个算子）没有能力表可问，按开关走；
## 宿主起来了就以能力键为准：插件停用 → 键被撤回 → 一律回落 GDScript。
static func _provided() -> bool:
	if not FxRegistry.ready:
		return true
	return FxCapabilities.has(CAPABILITY)


## 至少一族可用。逐族的实况用 `abi_report()`，别用这个函数下结论。
static func available() -> bool:
	for family in FAMILY_CLASSES.keys():
		if api(String(family)) != null:
			return true
	return false


## 原生 ABI 实况：哪几族在、库路径、失败原因。诊断命令 `diag.blame` 与
## 「帮助 → 装配诊断」都读它，所以它只返回基础类型。
static func abi_report() -> Dictionary:
	var families: Dictionary = {}
	var missing: Array = []
	for family in FAMILY_CLASSES.keys():
		var handle := _instance(String(family))
		families[String(family)] = handle != null
		if handle == null:
			missing.append(String(family))
	var message := ""
	if not _enabled:
		message = "FX_NATIVE=0 或插件已停用"
	elif missing.size() == FAMILY_CLASSES.size():
		message = "没找到任何原生类（库未编译 / 未加载 / 架构不符）"
	elif not missing.is_empty():
		message = "缺族：%s" % ", ".join(PackedStringArray(missing))
	return {
		"available": missing.size() < FAMILY_CLASSES.size(),
		"complete": missing.is_empty(),
		"families": families,
		"missing": missing,
		"message": message,
		"enabled": _enabled,
		"provided": _provided(),
	}


## 本次调用该给几线程：主线程给到核数（上限 8），工作线程/渲染线程给 1。
static func threads() -> int:
	if not available():
		return 1
	if int(OS.get_thread_caller_id()) != int(OS.get_main_thread_id()):
		return 1
	return clampi(OS.get_processor_count(), 1, 8)


# ---------- 点运算 ----------

static func hue(image: Image, shift: float, saturation: float, value: float) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("hue", image, shift, saturation, value, threads()) as Image


static func tint(image: Image, color: Color, amount: float, preserve_luma: bool) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("tint", image, color, amount, preserve_luma, threads()) as Image


static func bright(image: Image, threshold: float) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("bright", image, threshold, threads()) as Image


static func bloom_add(base: Image, glow: Image, amount: float) -> Image:
	var handle := api("blend")
	if handle == null or base == null or glow == null:
		if _enabled:
			_misses += 1
		return null
	if base.get_size() != glow.get_size():
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("bloom_add", base, glow, amount, threads()) as Image


# ---------- 重采样 ----------

static func wave(image: Image, amplitude: float, omega: float, phase: float,
		axis_mode: int) -> Image:
	var handle := api("warp")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("wave", image, amplitude, omega, phase, axis_mode, threads()) as Image


static func remap(image: Image, coords: PackedFloat32Array) -> Image:
	var handle := api("warp")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	if coords.size() < image.get_width() * image.get_height() * 2:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("remap", image, coords, threads()) as Image


## wrap_mode：0 = transparent（越界透明）、1 = repeat、2 = clamp。
static func affine(image: Image, offset: Vector2, scale: Vector2, rotation_deg: float,
		anchor: Vector2, wrap_mode: int) -> Image:
	var handle := api("warp")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("affine", image, offset, scale, rotation_deg, anchor,
		wrap_mode, threads()) as Image


# ---------- 合成 ----------

## channel：1 = red、2 = green、3 = blue、4 = luma，其余按 alpha。
static func mask_image(image: Image, mask: Image, channel: int, invert: bool,
		softness: float, opacity: float) -> Image:
	var handle := api("blend")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("mask_image", image, mask, channel, invert, softness, opacity,
		threads()) as Image


## 原地合成：base 会被改写（调用方传进来的必须是副本，语义与 _blend_bytes 一致）。
static func blend(base: Image, top: Image, rect: Rect2i, at: Vector2i, mode_id: int,
		opacity: float) -> bool:
	var handle := api("blend")
	if handle == null or base == null or top == null:
		if _enabled:
			_misses += 1
		return false
	if rect.size.x <= 0 or rect.size.y <= 0:
		if _enabled:
			_misses += 1
		return false
	_calls += 1
	handle.call("blend", base, top, rect, at, mode_id, opacity, threads())
	return true


# ---------- 邻域 / 卷积 ----------

## 8 邻域 alpha 描边（inside = false 为外描边）。
static func outline_alpha(image: Image, thickness: int, inside: bool, threshold: float,
		color: Color) -> Image:
	var handle := api("edge")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("outline_alpha", image, thickness, inside, threshold, color,
		threads()) as Image


static func box_blur(image: Image, radius: int) -> Image:
	var handle := api("edge")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	if radius <= 0:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("box_blur", image, radius, threads()) as Image


# ---------- 点运算（查表族）----------

static func invert(image: Image) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("invert", image, threads()) as Image


## RGB 三通道横向错切（色差）。offset 为像素，正数把 R 右移、B 左移。
static func chromatic(image: Image, offset: int) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("chromatic", image, offset, threads()) as Image


## 「颜色缓冲 + 加性光缓冲」合成。color 是 RGBA8 字节，light 是 RGB 的 int32
## （加性光可以叠到 255 以上，所以不能用字节存）。
static func composite_add(color: PackedByteArray, light: PackedInt32Array, size: Vector2i,
		light_k: float) -> Image:
	var handle := api("blend")
	if handle == null or size.x <= 0 or size.y <= 0:
		if _enabled:
			_misses += 1
		return null
	if color.size() < size.x * size.y * 4 or light.size() < size.x * size.y * 3:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("composite_add", color, light, size, light_k, threads()) as Image


static func alpha_tint(image: Image, color: Color, opacity: float) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("alpha_tint", image, color, opacity, threads()) as Image


## 调色板重映射 + 染色 + 透明度。palette 少于 2 项时核里只做染色/透明度。
static func recolor(image: Image, palette: PackedColorArray, palette_amount: float,
		tint: Color, tint_amount: float, alpha: float) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("recolor", image, palette, palette_amount, tint, tint_amount, alpha,
		threads()) as Image


## 稀疏光点叠加：`data` 每 9 个 float 一个光点（x, y, radius, strength, core, r, g, b, a）。
static func paint_blobs(size: Vector2i, background: Color, data: PackedFloat32Array) -> Image:
	var handle := api("blend")
	if handle == null or size.x <= 0 or size.y <= 0 or data.is_empty():
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("paint_blobs", size, background, data) as Image

static func levels(image: Image, brightness: float, contrast: float, gamma: float) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("levels", image, brightness, contrast, gamma, threads()) as Image


static func threshold_map(image: Image, cutoff: float, softness: float, use_luma: bool,
		color: Color) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("threshold_map", image, cutoff, softness, use_luma, color,
		threads()) as Image


static func ramp_three(image: Image, shadow: Color, mid: Color, high: Color, midpoint: float,
		amount: float) -> Image:
	var handle := api("point")
	if handle == null or image == null:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("ramp_three", image, shadow, mid, high, midpoint, amount,
		threads()) as Image


# ---------- 程序化生成 ----------

## mode：0 = 线性、1 = 径向、2 = 角度。角度按**度**传，弧度换算在核里做。
static func gradient_fill(size: Vector2i, mode: int, a: Color, b: Color, angle_deg: float,
		center: Vector2, gradient_scale: float, softness: float) -> Image:
	var handle := api("gen")
	if handle == null or size.x <= 0 or size.y <= 0:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("gradient_fill", size, mode, a, b, angle_deg, center, gradient_scale,
		softness, threads()) as Image


static func radial_spokes(size: Vector2i, count: int, spin: float, width: float, length: float,
		intensity: float, center: Vector2, color: Color) -> Image:
	var handle := api("gen")
	if handle == null or size.x <= 0 or size.y <= 0:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("radial_spokes", size, count, spin, width, length, intensity, center,
		color, threads()) as Image


static func radial_ring(size: Vector2i, phase: float, max_radius: float, width: float,
		intensity: float, center: Vector2, ring_color: Color, core_color: Color) -> Image:
	var handle := api("gen")
	if handle == null or size.x <= 0 or size.y <= 0:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("radial_ring", size, phase, max_radius, width, intensity, center,
		ring_color, core_color, threads()) as Image


## kind：0 = 圆、1 = 环、2 = 矩形、3 = 菱形、4 = 三角、5 = 星形。
static func shape_field(size: Vector2i, kind: int, fill: Color, background: Color,
		radius: float, feather: float, sides: int, center: Vector2, rotation_deg: float,
		aspect: float) -> Image:
	var handle := api("gen")
	if handle == null or size.x <= 0 or size.y <= 0:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("shape_field", size, kind, fill, background, radius, feather, sides,
		center, rotation_deg, aspect, threads()) as Image


## 块状噪声：每 cell×cell 一格，按哈希在两种颜色间二选一。
static func noise_field(size: Vector2i, cell: int, density: float, a: Color, b: Color,
		seed_value: int) -> Image:
	var handle := api("gen")
	if handle == null or size.x <= 0 or size.y <= 0:
		if _enabled:
			_misses += 1
		return null
	_calls += 1
	return handle.call("noise_field", size, cell, density, a, b, seed_value,
		threads()) as Image


# ---------- 诊断 ----------

static func stats() -> Dictionary:
	var report := abi_report()
	var out := {
		"available": bool(report.get("available", false)),
		"complete": bool(report.get("complete", false)),
		"families": report.get("families", {}),
		"enabled": _enabled,
		"calls": _calls,
		"misses": _misses,
	}
	# C++ 侧的计数器是**全局**的（五个类共享一套 atomics），所以只读第一个可用族。
	# 五份相加会得到 5 倍数字 —— 这类「统计口径」错误在性能对比里最容易被当真。
	for family in FAMILY_CLASSES.keys():
		var handle := _instance(String(family))
		if handle == null:
			continue
		var raw: Variant = handle.call("stats")
		if raw is Dictionary:
			for key in (raw as Dictionary).keys():
				out[key] = (raw as Dictionary)[key]
		break
	return out


static func describe() -> String:
	var data := stats()
	var report := abi_report()
	var lines: Array[String] = []
	lines.append("== 像素内核 · 原生扩展 ==")
	lines.append("可用：%s（开关：%s）" % [
		"是" if bool(data.get("available", false)) else "否",
		"开" if _enabled else "关"])
	var families: Dictionary = report.get("families", {})
	var parts: Array[String] = []
	for family in FAMILY_CLASSES.keys():
		parts.append("%s=%s" % [String(family), "有" if bool(families.get(String(family), false)) else "无"])
	lines.append("族：%s" % " ".join(PackedStringArray(parts)))
	if not String(report.get("message", "")).is_empty():
		lines.append("说明：%s" % String(report.get("message", "")))
	lines.append("调用：%d 次 · 未命中（回落 GDScript）：%d 次" %
		[int(data.get("calls", 0)), int(data.get("misses", 0))])
	if bool(data.get("available", false)):
		lines.append("上次线程数：%d" % int(data.get("last_threads", 1)))
		lines.append("累计处理像素：%d" % int(data.get("pixels", 0)))
	else:
		lines.append("五个原生类都不在：库没编 / 没加载 / 被 FX_NATIVE=0 或插件停用关掉")
	return "\n".join(PackedStringArray(lines))


## 状态栏片段：只报「几族在用」，不参与任何领域判断。
static func fragment(_stats: Dictionary) -> Dictionary:
	var report := abi_report()
	if not bool(report.get("available", false)) or not bool(report.get("provided", false)):
		return {"text": "", "tone": ""}
	var families: Dictionary = report.get("families", {})
	var live := 0
	for family in FAMILY_CLASSES.keys():
		if bool(families.get(String(family), false)):
			live += 1
	if live == FAMILY_CLASSES.size():
		return {"text": " · 原生 %d/%d" % [live, FAMILY_CLASSES.size()], "tone": "ok"}
	return {"text": " · 原生 %d/%d" % [live, FAMILY_CLASSES.size()], "tone": "accent"}


## 装配诊断里的一行：让「这个扩展到底在不在」变成可查的事实，
## 而不是靠「跑得快不快」猜。
static func diagnostic(_service: Variant) -> String:
	var report := abi_report()
	var families: Dictionary = report.get("families", {})
	var live: Array[String] = []
	var dead: Array[String] = []
	for family in FAMILY_CLASSES.keys():
		if bool(families.get(String(family), false)):
			live.append(String(family))
		else:
			dead.append(String(family))
	if not bool(report.get("provided", false)):
		# 库在、但没用上：插件被停用或能力键没到。这条最容易被误读成"加速已生效"。
		return "原生像素内核 pixels.native：库在场（%d/5 族），插件未激活 → 当前回落 GDScript" % live.size()
	if dead.is_empty():
		return "原生像素内核 pixels.native：5/5 族在场（%s）" % ", ".join(PackedStringArray(live))
	if live.is_empty():
		return "原生像素内核 pixels.native：缺席（%s），全部回落 GDScript" % String(report.get("message", ""))
	return "原生像素内核 pixels.native：%d/5 族在场，缺 %s" % [
		live.size(), ", ".join(PackedStringArray(dead))]
