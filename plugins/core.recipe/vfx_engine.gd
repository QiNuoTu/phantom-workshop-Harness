class_name VfxEngine
extends RefCounted
## Phase 2 内核 · 确定性像素特效引擎（纯计算，无节点、无全局状态、无 UI 依赖）。
## 移植 pixelfx 的三个核心思想：color/light 双缓冲、Bayer 有序抖动、位置是 age 闭式函数的粒子
## （因此任意帧可 scrub、循环无接缝、可逐帧烘焙成 sprite sheet）。
## 配方是纯数据 Dictionary；同一 seed + 同一 t 永远得到同一张 Image。

## 4x4 Bayer 阈值；(v + 0.5) / 16，用于把半透明硬像素抖动成不透明像素。
const BAYER: Array[float] = [
	0.03125, 0.53125, 0.15625, 0.65625,
	0.78125, 0.28125, 0.90625, 0.40625,
	0.21875, 0.71875, 0.09375, 0.59375,
	0.96875, 0.46875, 0.84375, 0.34375,
]

var _w: int = 96
var _h: int = 96
var _duration: float = 1.0
var _seed: int = 1
var _loop: bool = false
var _palette: Array[Color] = []
var _layers: Array[Dictionary] = []
var _compiled: Array = []
var _color: PackedByteArray = PackedByteArray()
var _light: PackedInt32Array = PackedInt32Array()
var _tx: float = 0.0
var _ty: float = 0.0
var _flip: float = 1.0
var _cs: float = 1.0
var _sn: float = 0.0
var _light_k: float = 1.0
## 光强原始值：可能是轨道 —— 每帧再采样一次，所以它是可动画的。
var _light_raw: Variant = 1.0
## 画布等比缩放：所有图层几何量都是按 96×96 设计空间写的，
## 画布改成别的尺寸时按「面积等价的几何均值」缩放内容，
## 否则 96 -> 192 只会得到一张内容不变、四周空一圈的图。
var _unit: float = 1.0
var _stretch: bool = true
## 配方里是否含关键帧轨道：含则每帧解析一次层参数（纯函数，仍然可 scrub/烘焙）。
var _has_tracks: bool = false
## 外部资源表：key -> Image（自定义素材/贴图）。由门面按需注入。
var _assets: Dictionary = {}
## 后处理表达式（自定义"着色器"）：逐像素求值，空则不启用。
var _post: Expression = null
var _post_amount: float = 1.0
## 后处理模式：expr（表达式着色）/ shake（屏幕震动）/ chromatic（RGB 色差）。
## 参数原始值存 _post_raw，每帧采样 —— 后处理参数同样可打帧。
var _post_mode: String = "expr"
var _post_raw: Dictionary = {}
## 当前图层的标准变换（FxTransform 提供的矩阵，已按 _unit 换算到帧像素）。
## 每个图层开始绘制前重设；所有绘制原语经过 _to_x/_to_y 时自动套用，
## 因此"给所有图层加变换"不需要改动任何一个 _draw_* 函数。
var _layer_xf: Transform2D = Transform2D.IDENTITY
## 当前图层的内容缩放（素材层要按它缩放自身尺寸；旋转要加到素材自转上）。
var _layer_content: Vector2 = Vector2.ONE
var _layer_rot: float = 0.0

const DESIGN_SIZE: float = 96.0
## 这些键是"像素量"，需要跟着画布缩放。ground 是高度百分比、bands/count 是计数，都不缩放。
const PIXEL_KEYS: Array = [
	"speed", "size", "radius", "width", "length", "y", "spawn_radius",
	"gravity", "amplitude", "x", "offset", "thickness", "distance",
]

## 载入配方。所有取值都做范围钳制，非法字段不会让引擎崩溃。
## 画布/时长/帧率/种子是**结构性**字段：即使配方里误存了轨道，也按首帧折叠成常量
## （走 FxTracks.static_of），绝不出现 float(Dictionary) 这类崩溃。
func configure(recipe: Dictionary, assets: Dictionary = {}) -> void:
	_w = clampi(FxTracks.integer(recipe.get("width"), int(DESIGN_SIZE)), 16, 512)
	_h = clampi(FxTracks.integer(recipe.get("height"), int(DESIGN_SIZE)), 16, 512)
	# stretch=true：内容按画布等比缩放（分辨率无关，适合导出 2x）；
	# stretch=false：内容保持 1:1 像素尺寸并居中（画布只是多给留白/裁切区）。
	_stretch = _as_bool(FxTracks.static_of(recipe.get("stretch"), true), true)
	_unit = clampf(sqrt(float(_w) * float(_h)) / DESIGN_SIZE, 0.15, 6.0) if _stretch else 1.0
	_duration = clampf(FxTracks.number(recipe.get("duration"), 1.0), 0.04, 30.0)
	_seed = FxTracks.integer(recipe.get("seed"), 1)
	_loop = bool(FxTracks.static_of(recipe.get("loop"), false))
	_light_raw = recipe.get("light", 1.0)
	_light_k = clampf(FxTracks.number(_light_raw, 1.0), 0.0, 4.0)
	_palette = []
	var raw: Array = recipe.get("palette", ["#101020", "#ffffff"])
	for i in range(raw.size()):
		_palette.append(hex_to_color(String(raw[i])))
	if _palette.is_empty():
		_palette.append(Color.WHITE)
	var ramp_size: int = FxTracks.integer(recipe.get("ramp_size"), 0)
	if ramp_size > 1 and ramp_size != _palette.size():
		var fitted: Array[Color] = []
		for i in range(ramp_size):
			var src: int = int(roundf(float(i) * float(_palette.size() - 1) / float(maxi(1, ramp_size - 1))))
			fitted.append(_palette[clampi(src, 0, _palette.size() - 1)])
		_palette = fitted
	_layers = []
	var source: Array = recipe.get("layers", [])
	for i in range(source.size()):
		if source[i] is Dictionary:
			# 深拷贝 + 缩放：绝不改写调用方传进来的配方
			_layers.append(_scale_layer(source[i], _unit))
	_assets = assets
	_has_tracks = false
	for i in range(_layers.size()):
		if FxTracks.has_track(_layers[i]):
			_has_tracks = true
			break
	_post = null
	_post_mode = "expr"
	_post_raw = {}
	var post: Variant = recipe.get("post", null)
	if post is Dictionary:
		_post_raw = (post as Dictionary).duplicate(true)
		_post_mode = String(post.get("mode", "expr"))
	if _post_mode == "expr" and post is Dictionary and String((post as Dictionary).get("expr", "")) != "":
		# 自定义"着色器"：用户写一个返回 Color 的表达式，逐像素（只处理非透明像素）执行。
		var parsed: Expression = Expression.new()
		if parsed.parse(String(post["expr"]), PackedStringArray(["x", "y", "r", "g", "b", "a", "t"])) == OK:
			_post = parsed
			_post_amount = clampf(float(post.get("amount", 1.0)), 0.0, 1.0)
	# 闭式动力学层在配置阶段就把事件树展开成原子表：之后任意 t 只需纯函数求值。
	_compiled = []
	for i in range(_layers.size()):
		var layer: Dictionary = _layers[i]
		if String(layer.get("type", "")) == "debris":
			if FxTracks.has_track(layer):
				# 参数在动，原子表必须按帧重建（编辑器里这样最直观，导出时也只多这点开销）
				_compiled.append(null)
			else:
				var ground: float = float(layer.get("ground", 0.0)) * float(_h)
				_compiled.append(FxDynamics.compile(layer, _seed + i * 101, ground))
		else:
			_compiled.append([])
	var origin: Array = recipe.get("origin", [0.5, 0.5])
	var ox: float = 0.5 if origin.is_empty() else clampf(float(origin[0]), -1.0, 2.0)
	var oy: float = 0.5 if origin.size() < 2 else clampf(float(origin[1]), -1.0, 2.0)
	_tx = _w * ox
	_ty = _h * oy
	_flip = -1.0 if bool(FxTracks.static_of(recipe.get("flip"), false)) else 1.0
	var angle: float = deg_to_rad(FxTracks.number(recipe.get("angle"), 0.0))
	_cs = cos(angle)
	_sn = sin(angle)
	_color.resize(_w * _h * 4)
	_light.resize(_w * _h * 3)

func frame_count(fps: int) -> int:
	return maxi(1, int(_duration * clampi(fps, 1, 120)))

## 当前配方时长（秒）。预览/导出要按它夹取时间，避免算出画布外的帧。
func duration() -> float:
	return _duration

## 渲染 t 秒时的画面。这是引擎唯一的输出口，纯函数式（除内部缓冲复用外无副作用）。
func render(t: float) -> Image:
	_color.fill(0)
	_light.fill(0)
	var time: float = fmod(t, _duration) if _loop else t
	if _light_raw is Dictionary:
		_light_k = clampf(FxTracks.number(FxTracks.sample(_light_raw, time), 1.0), 0.0, 4.0)
	for i in range(_layers.size()):
		var layer: Dictionary = _layers[i]
		if _has_tracks:
			layer = FxTracks.resolve_layer(layer, time)
		_draw_layer(layer, time, i)
	var image: Image = _composite()
	# 注意判据是 _post_raw 而不是 _post：_post 只在 expr 模式解析成功后才有值，
	# 以前用它当开关，等于"只有表达式模式的后处理会执行"——
	# 泛光/扫描线/像素化/热浪/染色/震动/色差七个模式全是空转，画面一点不变。
	if not _post_raw.is_empty():
		image = _apply_post(image, time)
	return image

## 把整段时间烘焙成一张网格 sprite sheet；列数由调用方控制。
func render_sheet(fps: int, columns: int) -> Image:
	var n: int = frame_count(fps)
	var cols: int = clampi(columns, 1, n)
	var rows: int = int(ceilf(float(n) / float(cols)))
	var sheet := Image.create(cols * _w, rows * _h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.0, 0.0, 0.0, 0.0))
	for f in range(n):
		var img: Image = render(float(f) / float(fps))
		sheet.blit_rect(img, Rect2i(0, 0, _w, _h), Vector2i((f % cols) * _w, (f / cols) * _h))
	return sheet

func frame_size() -> Vector2i:
	return Vector2i(_w, _h)

# ---------- 局部坐标 -> 帧坐标（place：镜像与旋转由画家承担，特效永远画在自己的原点周围） ----------
#
# 坐标链：图层局部 → **图层变换**（FxTransform）→ 画布 place（原点/镜像/画布角度）。
# 图层变换放在这里而不是各个 _draw_* 里：所有绘制原语都经过 _to_x/_to_y，
# 于是"给所有节点加 Transform 能力"是零侵入的 —— 没有一个绘制函数需要知道自己被变换了。

func _to_x(x: float, y: float) -> float:
	if _layer_xf == Transform2D.IDENTITY:
		return _tx + x * _flip * _cs - y * _sn
	var p: Vector2 = _layer_xf * Vector2(x, y)
	return _tx + p.x * _flip * _cs - p.y * _sn

func _to_y(x: float, y: float) -> float:
	if _layer_xf == Transform2D.IDENTITY:
		return _ty + x * _flip * _sn + y * _cs
	var p: Vector2 = _layer_xf * Vector2(x, y)
	return _ty + p.x * _flip * _sn + p.y * _cs

## 图层局部坐标 → 画布帧坐标（place 部分）。素材层这类"自己算屏幕坐标"的绘制用它。
func _place(v: Vector2) -> Vector2:
	var p: Vector2 = _layer_xf * v
	return Vector2(_tx + p.x * _flip * _cs - p.y * _sn, _ty + p.x * _flip * _sn + p.y * _cs)

func _cell(x: float, y: float) -> Vector2i:
	var lx: float = floorf(x) + 0.5
	var ly: float = floorf(y) + 0.5
	return Vector2i(int(_to_x(lx, ly)), int(_to_y(lx, ly)))

func _in_bounds(sx: int, sy: int) -> bool:
	return sx >= 0 and sy >= 0 and sx < _w and sy < _h

## 硬像素：alpha < 1 时用有序抖动决定是否落笔，绝不混色（像素画的规矩）。
func _put(sx: int, sy: int, c: Color, a: float) -> void:
	if not _in_bounds(sx, sy) or a <= 0.004:
		return
	if a < 1.0 and a <= BAYER[(sy & 3) * 4 + (sx & 3)]:
		return
	var i: int = (sy * _w + sx) * 4
	_color[i] = int(clampf(c.r, 0.0, 1.0) * 255.0)
	_color[i + 1] = int(clampf(c.g, 0.0, 1.0) * 255.0)
	_color[i + 2] = int(clampf(c.b, 0.0, 1.0) * 255.0)
	_color[i + 3] = 255

## 半透明体积：保留自身 alpha，用于烟、雾、光晕。
func _blend(sx: int, sy: int, c: Color, a: float) -> void:
	if not _in_bounds(sx, sy) or a <= 0.004:
		return
	var i: int = (sy * _w + sx) * 4
	var da: float = float(_color[i + 3]) / 255.0
	var oa: float = a + da * (1.0 - a)
	if oa <= 0.0:
		return
	var k: float = a / oa
	_color[i] = int(clampf(c.r * 255.0 * k + float(_color[i]) * (1.0 - k), 0.0, 255.0))
	_color[i + 1] = int(clampf(c.g * 255.0 * k + float(_color[i + 1]) * (1.0 - k), 0.0, 255.0))
	_color[i + 2] = int(clampf(c.b * 255.0 * k + float(_color[i + 2]) * (1.0 - k), 0.0, 255.0))
	_color[i + 3] = int(clampf(oa, 0.0, 1.0) * 255.0)

## 加性光缓冲：热的东西看起来热，是因为光叠在颜色之上。
func _add(sx: int, sy: int, c: Color, k: float) -> void:
	if not _in_bounds(sx, sy) or k <= 0.004:
		return
	var i: int = (sy * _w + sx) * 3
	_light[i] += int(c.r * 255.0 * k)
	_light[i + 1] += int(c.g * 255.0 * k)
	_light[i + 2] += int(c.b * 255.0 * k)

func _px(x: float, y: float, c: Color, a: float) -> void:
	var cell: Vector2i = _cell(x, y)
	_put(cell.x, cell.y, c, a)

func _glow(x: float, y: float, c: Color, k: float) -> void:
	var cell: Vector2i = _cell(x, y)
	_add(cell.x, cell.y, c, k)

func _line(x0: float, y0: float, x1: float, y1: float, c: Color, a: float) -> void:
	var steps: int = maxi(1, int(maxf(absf(x1 - x0), absf(y1 - y0))))
	for i in range(steps + 1):
		var u: float = float(i) / float(steps)
		_px(lerpf(x0, x1, u), lerpf(y0, y1, u), c, a)

func _disc(cx: float, cy: float, r: float, c: Color, a: float, glow: float) -> void:
	var rr: float = maxf(r, 0.5)
	var span: int = int(ceilf(rr * 2.0)) + 1
	for iy in range(span):
		for ix in range(span):
			var dx: float = float(ix) - rr
			var dy: float = float(iy) - rr
			var d: float = sqrt(dx * dx + dy * dy) / rr
			if d > 1.0:
				continue
			var x: float = cx - rr + float(ix)
			var y: float = cy - rr + float(iy)
			_blend(_cell(x, y).x, _cell(x, y).y, c, a * (1.0 - d * 0.55))
			if glow > 0.0:
				_glow(x, y, c, glow * (1.0 - d))

# ---------- 确定性随机与闭式粒子 ----------

## 无状态 hash：同一 (seed, 粒子序号, 用途) 永远返回同一个 0..1 值，因此任意帧可独立重算。
func _rand(a: int, b: int, salt: int) -> float:
	var x: int = (a * 374761393 + b * 668265263 + salt * 1442695041) & 0x7fffffff
	x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff
	return float(x ^ (x >> 16)) / 2147483647.0

func _range(value: Variant, index: int, fallback: float) -> float:
	if value == null:
		return fallback
	if value is Array:
		var arr: Array = value
		if arr.is_empty():
			return fallback
		return float(arr[mini(index, arr.size() - 1)])
	return float(value)

func _ramp(index: float) -> Color:
	return _palette[clampi(int(index), 0, _palette.size() - 1)]

## 闭式弹道：drag <= 0 为抛物线，否则为指数阻尼；不含历史状态，可直接求任意 age。
func _fly(vx: float, vy: float, age: float, g: float, drag: float) -> Vector2:
	if drag <= 0.0:
		return Vector2(vx * age, vy * age + 0.5 * g * age * age)
	var f: float = (1.0 - exp(-drag * age)) / drag
	var vt: float = g / drag
	return Vector2(vx * f, vt * age + (vy - vt) * f)

# ---------- 图层 ----------

func _draw_layer(layer: Dictionary, t: float, index: int) -> void:
	_apply_layer_transform(layer, t)
	match String(layer.get("type", "burst")):
		"burst":
			_draw_particles(layer, t, false)
		"cycle":
			_draw_particles(layer, t, true)
		"ring":
			_draw_ring(layer, t)
		"flash":
			_draw_flash(layer, t)
		"beam":
			_draw_beam(layer, t)
		"trail":
			_draw_trail(layer, t)
		"aura":
			_draw_aura(layer, t)
		"orbit":
			_draw_orbit(layer, t)
		"glitch":
			_draw_glitch(layer, t)
		"wipe":
			_draw_wipe(layer, t)
		"debris":
			_draw_debris(layer, t, index)
		"text":
			_draw_text(layer, t)
		"sprite":
			_draw_sprite_layer(layer, t)


## 把该层的 transform 解析成矩阵。恒等时走零成本路径：绝大多数预置没有变换，
## 不能让它们为了"支持新接口"而多算一次三角函数。
func _apply_layer_transform(layer: Dictionary, t: float) -> void:
	var raw: Variant = layer.get("transform", null)
	if raw == null or FxTransform.is_identity(raw):
		_layer_xf = Transform2D.IDENTITY
		_layer_content = Vector2.ONE
		_layer_rot = 0.0
		return
	_layer_xf = FxTransform.matrix(raw, t, _unit)
	_layer_content = FxTransform.content_scale_of(raw, t)
	_layer_rot = FxTransform.rotation_of(raw, t)
	
func _draw_particles(layer: Dictionary, t: float, looping: bool) -> void:
	var count: int = clampi(int(layer.get("count", 32)), 1, 512)
	var t0: float = float(layer.get("t0", 0.0))
	var period: float = maxf(_duration, 0.04) if looping else 0.0
	var birth: float = _range(layer.get("birth", 0.0), 1, 0.0)
	var speed0: float = _range(layer.get("speed", 100.0), 0, 100.0)
	var speed1: float = _range(layer.get("speed", 100.0), 1, 100.0)
	var angle0: float = _range(layer.get("angle", [0.0, 360.0]), 0, 0.0)
	var angle1: float = _range(layer.get("angle", [0.0, 360.0]), 1, 360.0)
	var life0: float = _range(layer.get("life", 0.6), 0, 0.6)
	var life1: float = _range(layer.get("life", 0.6), 1, 0.6)
	var size0: float = _range(layer.get("size", 2.0), 0, 2.0)
	var size1: float = _range(layer.get("size", 2.0), 1, 2.0)
	var gravity: float = float(layer.get("gravity", 0.0))
	var drag: float = maxf(float(layer.get("drag", 0.0)), 0.0)
	var glow: float = clampf(float(layer.get("glow", 0.6)), 0.0, 4.0)
	var c0: float = float(layer.get("color_from", 1.0))
	var c1: float = float(layer.get("color_to", _palette.size() - 1))
	var shape: String = String(layer.get("shape", "dot"))
	var y0: float = _range(layer.get("y", 0.0), 0, 0.0)
	var y1: float = _range(layer.get("y", 0.0), 1, 0.0)
	var spawn0: float = _range(layer.get("spawn_radius", 2.0), 0, 2.0)
	var spawn1: float = _range(layer.get("spawn_radius", 2.0), 1, 2.0)
	for i in range(count):
		var r0: float = _rand(_seed, i, 11)
		var r1: float = _rand(_seed, i, 23)
		var r2: float = _rand(_seed, i, 37)
		var r3: float = _rand(_seed, i, 53)
		var r4: float = _rand(_seed, i, 71)
		var r5: float = _rand(_seed, i, 97)
		var r6: float = _rand(_seed, i, 131)
		var r7: float = _rand(_seed, i, 173)
		var life: float = maxf(0.02, lerpf(life0, life1, r3))
		var born: float = t0 + (r0 * period if looping else r0 * birth)
		var ages: Array[float] = []
		if looping:
			var age: float = fmod(fmod(t - born, period) + period, period)
			var guard: int = 0
			while age < life and guard < 4:
				ages.append(age)
				age += period
				guard += 1
		else:
			var once: float = t - born
			if once >= 0.0 and once < life:
				ages.append(once)
		if ages.is_empty():
			continue
		var speed: float = lerpf(speed0, speed1, r1)
		var theta: float = deg_to_rad(lerpf(angle0, angle1, r2))
		var vx: float = cos(theta) * speed
		var vy: float = sin(theta) * speed
		var size: float = lerpf(size0, size1, r4)
		var sy: float = lerpf(y0, y1, r5)
		var asset_key: String = String(layer.get("asset", ""))
		var sprite: Image = _assets.get(asset_key, null) if asset_key != "" else null
		# 素材材质：旋转角 / 整体透明度 —— 都可打帧（与其他参数同一套轨道机制）
		var sprite_rot: float = deg_to_rad(FxTracks.number(layer.get("sprite_rot"), 0.0))
		var sprite_alpha: float = clampf(FxTracks.number(layer.get("sprite_alpha"), 1.0), 0.0, 1.0)
		for j in range(ages.size()):
			var k: float = 1.0 - ages[j] / life
			var p: Vector2 = _fly(vx, vy, ages[j], gravity, drag)
			p += Vector2(cos(theta), sin(theta)) * lerpf(spawn0, spawn1, r7)
			p.y += sy
			var c: Color = _ramp(lerpf(c0, c1, k))
			var a: float = clampf(k * (1.0 + r6 * 0.3), 0.0, 1.0)
			if sprite != null:
				_draw_sprite(p.x, p.y, size, sprite, c, a * sprite_alpha, sprite_rot)
			else:
				_draw_particle(p.x, p.y, size, shape, c, a, glow * k, vx, vy, r6)

func _draw_particle(x: float, y: float, size: float, shape: String, c: Color, a: float, glow: float, vx: float, vy: float, r: float) -> void:
	match shape:
		"spark":
			var dir: Vector2 = Vector2(vx, vy).normalized()
			_line(x, y, x - dir.x * size * 2.5, y - dir.y * size * 2.5, c, a)
		"shard":
			for oy in range(int(size)):
				for ox in range(int(size)):
					_px(x + ox, y + oy, c, a)
		"star":
			_line(x - size, y, x + size, y, c, a)
			_line(x, y - size, x, y + size, c, a)
		"smoke":
			_disc(x, y, size * (1.6 - a * 0.6), c, a * 0.32, glow * 0.25)
		_:
			_px(x, y, c, a)
	_glow(x, y, c, glow * (0.5 + r * 0.5))

## 用导入的图片当粒子：最近邻采样 + 调色板染色，尺寸由 size 决定（长边像素数）。
func _draw_sprite(x: float, y: float, size: float, image: Image, tint: Color, a: float,
		rot: float = 0.0) -> void:
	var sw: int = maxi(1, image.get_width())
	var sh: int = maxi(1, image.get_height())
	var scale: float = maxf(size, 0.5) / float(maxi(sw, sh))
	var tw: int = maxi(1, int(roundf(float(sw) * scale)))
	var th: int = maxi(1, int(roundf(float(sh) * scale)))
	var cos_r: float = cos(rot)
	var sin_r: float = sin(rot)
	for py in range(th):
		var sy: int = clampi(int(float(py) / scale), 0, sh - 1)
		for px in range(tw):
			var sx: int = clampi(int(float(px) / scale), 0, sw - 1)
			var c: Color = image.get_pixel(sx, sy)
			if c.a <= 0.004:
				continue
			# 像素绕素材中心旋转：硬像素风的贴图直接转坐标，不需要抗锯齿
			var dx: float = float(px) - float(tw) * 0.5
			var dy: float = float(py) - float(th) * 0.5
			var rx: float = dx * cos_r - dy * sin_r
			var ry: float = dx * sin_r + dy * cos_r
			var out_x: int = int(roundf(x + rx))
			var out_y: int = int(roundf(y + ry))
			_put(out_x, out_y, Color(tint.r * c.r, tint.g * c.g, tint.b * c.b), c.a * a)
			_add(out_x, out_y, tint, c.a * a * 0.5)

## 自定义"着色器"：逐像素执行用户表达式（透明像素跳过）。
## 只处理画面内非透明像素，96×96 满屏约 9000 次求值 —— 交互预览足够，导出会自动慢一些。
## 文字层：内嵌 5x7 像素字模逐点绘制。text/px/py/height 全部可打帧 ——
## 打字机效果就是给 text 做逐字符轨道，冲击标题就是 height 弹一下。
func _draw_text(layer: Dictionary, t: float) -> void:
	var text: String = String(FxTracks.sample(layer.get("text", ""), t))
	if text == "":
		return
	var height: int = clampi(int(roundf(FxTracks.number(
		FxTracks.sample(layer.get("height", 7.0), t), 7.0) * _unit)), 3, 96)
	var px: float = FxTracks.number(FxTracks.sample(layer.get("px", 0.0), t), 0.0)
	var py: float = FxTracks.number(FxTracks.sample(layer.get("py", 0.0), t), 0.0)
	var color: Color = _ramp(_range(layer.get("color_from", 3), 0, 3))
	var glow: float = FxTracks.number(FxTracks.sample(layer.get("glow", 0.0), t), 0.0)
	# 等比放大：字模 5x7 → height 像素高
	var step: float = float(height) / float(TextFont.GLYPH_H)
	var advance: float = (float(TextFont.GLYPH_W) + 1.0) * step
	var block_w: float = advance * float(text.length()) - step
	var block_h: float = float(TextFont.GLYPH_H) * step
	# 与其他层同一套坐标：锚在画布原点，px/py 是**相对原点**的像素偏移（y 向下为正）。
	# 以前这里把 px/py 当画布绝对坐标用，默认值 8,8 就等于"贴着左上角"，
	# 文字永远被裁在角落里 —— 这是"输出画面不对劲"里最扎眼的一条。
	var left: float = -block_w * 0.5 + px * _unit
	var top: float = -block_h * 0.5 + py * _unit
	var span: int = maxi(1, int(roundf(step)))
	# 字模第 0 行就在顶部、画布 y 也向下，**不需要翻转**；
	# 旧实现按 (GLYPH_H-1-row) 取行，H/I 这种上下对称的字看不出来，T/L 一类的字是倒的。
	for ci in range(text.length()):
		var ch: String = text[ci]
		for row in range(TextFont.GLYPH_H):
			for col in range(TextFont.GLYPH_W):
				if not TextFont.has_pixel(ch, col, row):
					continue
				var lx: float = left + float(ci) * advance + float(col) * step
				var ly: float = top + float(row) * step
				for oy in range(span):
					for ox in range(span):
						_px(lx + float(ox), ly + float(oy), color, 1.0)
						_glow(lx + float(ox), ly + float(oy), color, glow * 0.5)


## 素材层：整张贴图按 scale/rot/alpha/染色显示（背景、图章、全屏素材的载体）。
func _draw_sprite_layer(layer: Dictionary, t: float) -> void:
	var asset_key: String = String(layer.get("asset", ""))
	var image: Image = _assets.get(asset_key, null) if asset_key != "" else null
	if image == null:
		return   # 没绑素材就静默 —— 空层不该制造报错或占位垃圾
	var size: float = FxTracks.number(FxTracks.sample(layer.get("size", 64.0), t), 64.0)
	var px: float = FxTracks.number(FxTracks.sample(layer.get("px", 0.0), t), 0.0)
	var py: float = FxTracks.number(FxTracks.sample(layer.get("py", 0.0), t), 0.0)
	var rot: float = deg_to_rad(FxTracks.number(FxTracks.sample(layer.get("rot", 0.0), t), 0.0))
	var alpha: float = clampf(FxTracks.number(FxTracks.sample(layer.get("alpha", 1.0), t), 1.0), 0.0, 1.0)
	var tint: Color = _ramp(_range(layer.get("color_to", 7), 0, 7))
	# 素材层自己算屏幕坐标（不走 _to_*：它要的是"贴图中心 + 旋转"，不是逐点绘制），
	# 所以这里显式过一次图层变换：位置 → _place，尺寸 → 内容缩放，旋转 → 叠加。
	var center: Vector2 = _place(Vector2(px, py) * _unit)
	# size 已经在 _scale_layer 里乘过 _unit（它在 PIXEL_KEYS 里），这里不能再乘 unit；
	# 只叠图层的等比内容缩放（取两轴平均，非等比时以面积近似保持观感）。
	var layer_scale: float = (absf(_layer_content.x) + absf(_layer_content.y)) * 0.5
	_draw_sprite(center.x, center.y, size * layer_scale, image, tint, alpha,
		rot + deg_to_rad(_layer_rot))


func _apply_post(image: Image, t: float) -> Image:
	match _post_mode:
		"shake":
			return _post_shake(image, t)
		"chromatic":
			return _post_chromatic(image, t)
		"bloom":
			return _post_bloom(image, t)
		"scanline":
			return _post_scanline(image, t)
		"pixelate":
			return _post_pixelate(image, t)
		"wave":
			return _post_wave(image, t)
		"tint":
			return _post_tint(image, t)
		_:
			return _post_expr(image, t)


## 泛光：把亮部向四周摊开再叠回去。四向采样（十字）而不是全核卷积 ——
## 目标是"看起来发光"，不是物理正确的 bloom；512 画布上也只要 4 次采样/像素。
func _post_bloom(image: Image, t: float) -> Image:
	var amount: float = clampf(FxTracks.number(FxTracks.sample(
		_post_raw.get("amount", 0.6), t), 0.6), 0.0, 1.0)
	var radius: int = maxi(1, int(roundf(FxTracks.number(FxTracks.sample(
		_post_raw.get("radius", 4.0), t), 4.0))))
	var threshold: float = clampf(FxTracks.number(FxTracks.sample(
		_post_raw.get("threshold", 0.45), t), 0.45), 0.0, 1.0)
	if amount <= 0.001:
		return image
	var out: Image = image.duplicate()
	var w: int = image.get_width()
	var h: int = image.get_height()
	for y in range(h):
		for x in range(w):
			var c: Color = image.get_pixel(x, y)
			if c.a <= 0.004:
				continue
			var lit: float = maxf(c.r, maxf(c.g, c.b))
			if lit <= threshold:
				continue
			var halo: Color = Color(0, 0, 0, 0)
			for offset in [Vector2i(radius, 0), Vector2i(-radius, 0),
					Vector2i(0, radius), Vector2i(0, -radius)]:
				var sx: int = clampi(x + offset.x, 0, w - 1)
				var sy: int = clampi(y + offset.y, 0, h - 1)
				halo += image.get_pixel(sx, sy)
			halo /= 4.0
			out.set_pixel(x, y, c.lerp(Color(
				minf(1.0, c.r + halo.r * amount),
				minf(1.0, c.g + halo.g * amount),
				minf(1.0, c.b + halo.b * amount),
				c.a), 1.0))
	return out


## 扫描线（CRT）：隔行压暗 + R/B 横向错开。period 控制线距，越小的屏幕越"老"。
func _post_scanline(image: Image, t: float) -> Image:
	var amount: float = clampf(FxTracks.number(FxTracks.sample(
		_post_raw.get("amount", 0.45), t), 0.45), 0.0, 0.95)
	var period: int = maxi(1, int(roundf(FxTracks.number(FxTracks.sample(
		_post_raw.get("scan_period", 2.0), t), 2.0))))
	var shift: int = maxi(0, int(roundf(FxTracks.number(FxTracks.sample(
		_post_raw.get("chroma_px", 1.0), t), 1.0))))
	var out: Image = image.duplicate()
	var w: int = image.get_width()
	var h: int = image.get_height()
	for y in range(h):
		var dark: float = 1.0 if (y % period) != 0 else (1.0 - amount)
		for x in range(w):
			var c: Color = image.get_pixel(x, y)
			if c.a <= 0.004 and dark >= 1.0:
				continue
			var r: Color = image.get_pixel(clampi(x + shift, 0, w - 1), y)
			var b: Color = image.get_pixel(clampi(x - shift, 0, w - 1), y)
			out.set_pixel(x, y, Color(r.r * dark, c.g * dark, b.b * dark, c.a))
	return out


## 像素化：把画面按 block 像素分块取平均色。和"放大后最近邻"不同，
## 这里是真降采样，所以 128 画布也能做出 8bit 味。
func _post_pixelate(image: Image, t: float) -> Image:
	var block: int = maxi(1, int(roundf(FxTracks.number(FxTracks.sample(
		_post_raw.get("block", 4.0), t), 4.0))))
	if block <= 1:
		return image
	var out: Image = image.duplicate()
	var w: int = image.get_width()
	var h: int = image.get_height()
	var y: int = 0
	while y < h:
		var x: int = 0
		while x < w:
			var sum: Color = Color(0, 0, 0, 0)
			var count: int = 0
			for by in range(mini(block, h - y)):
				for bx in range(mini(block, w - x)):
					sum += image.get_pixel(x + bx, y + by)
					count += 1
			var avg: Color = sum / float(maxi(1, count))
			for by in range(mini(block, h - y)):
				for bx in range(mini(block, w - x)):
					out.set_pixel(x + bx, y + by, avg)
			x += block
		y += block
	return out


## 热浪：按 sin 横向位移采样。amp 像素、freq 条波，纵向相位错开才不会像整体平移。
func _post_wave(image: Image, t: float) -> Image:
	var amp: float = FxTracks.number(FxTracks.sample(
		_post_raw.get("wave_amp", 2.0), t), 2.0)
	var freq: float = FxTracks.number(FxTracks.sample(
		_post_raw.get("wave_freq", 6.0), t), 6.0)
	var amount: float = clampf(FxTracks.number(FxTracks.sample(
		_post_raw.get("amount", 1.0), t), 1.0), 0.0, 1.0)
	if absf(amp) <= 0.01:
		return image
	var out: Image = image.duplicate()
	var w: int = image.get_width()
	var h: int = image.get_height()
	for y in range(h):
		var phase: float = float(y) / float(maxi(1, h)) * TAU * freq + t * 6.283
		var dx: int = int(roundf(sin(phase) * amp * amount))
		for x in range(w):
			out.set_pixel(x, y, image.get_pixel(clampi(x + dx, 0, w - 1), y))
	return out


## 整体染色：按强度把画面往某个色号推。color_to 是调色板下标。
func _post_tint(image: Image, t: float) -> Image:
	var amount: float = clampf(FxTracks.number(FxTracks.sample(
		_post_raw.get("amount", 0.35), t), 0.35), 0.0, 1.0)
	var index: float = FxTracks.number(FxTracks.sample(
		_post_raw.get("color_to", 4.0), t), 4.0)
	if amount <= 0.001 or _palette.is_empty():
		return image
	var tint: Color = _ramp(index)
	var out: Image = image.duplicate()
	var w: int = image.get_width()
	var h: int = image.get_height()
	for y in range(h):
		for x in range(w):
			var c: Color = image.get_pixel(x, y)
			if c.a <= 0.004:
				continue
			out.set_pixel(x, y, Color(
				lerpf(c.r, tint.r, amount), lerpf(c.g, tint.g, amount),
				lerpf(c.b, tint.b, amount), c.a))
	return out


## 表达式着色（原 expr 模式）。
func _post_expr(image: Image, t: float) -> Image:
	if _post == null:
		return image
	var out: Image = image.duplicate()
	var w: int = image.get_width()
	var h: int = image.get_height()
	var amount: float = _post_amount
	for y in range(h):
		for x in range(w):
			var c: Color = image.get_pixel(x, y)
			if c.a <= 0.004:
				continue
			var res: Variant = _post.execute([x, y, c.r, c.g, c.b, c.a, t])
			if _post.has_execute_failed() or not res is Color:
				continue
			var n: Color = res
			out.set_pixel(x, y, Color(
				lerpf(c.r, n.r, amount), lerpf(c.g, n.g, amount),
				lerpf(c.b, n.b, amount), lerpf(c.a, n.a, amount)))
	return out


## 屏幕震动：整图按噪声位移采样。amp/freq 都可打帧（撞击瞬间 amp 拉满然后衰减）。
func _post_shake(image: Image, t: float) -> Image:
	var amp: float = FxTracks.number(FxTracks.sample(_post_raw.get("shake_amp", 3.0), t), 3.0)
	var freq: float = FxTracks.number(FxTracks.sample(_post_raw.get("shake_freq", 30.0), t), 30.0)
	var amount: float = clampf(FxTracks.number(FxTracks.sample(
		_post_raw.get("amount", 1.0), t), 1.0), 0.0, 1.0)
	if amp <= 0.01 or amount <= 0.001:
		return image
	var out: Image = image.duplicate()
	out.fill(Color(0, 0, 0, 0))
	var w: int = image.get_width()
	var h: int = image.get_height()
	# 两组相位错开的正弦叠加 = 伪随机抖动轨迹（同 seed 同 t 结果一致，可 scrub）
	var phase: float = float(_seed % 1000) * 0.017
	var ox: float = sin(t * freq * 6.28 + phase) * amp * amount
	var oy: float = sin(t * freq * 4.71 + phase * 1.7) * amp * amount * 0.7
	for y in range(h):
		for x in range(w):
			var sx: int = clampi(x + int(roundf(ox)), 0, w - 1)
			var sy: int = clampi(y + int(roundf(oy)), 0, h - 1)
			out.set_pixel(x, y, image.get_pixel(sx, sy))
	return out


## RGB 色差：r/b 通道水平错位采样。chroma_px 可打帧（冲击瞬间色差炸开再合拢）。
func _post_chromatic(image: Image, t: float) -> Image:
	var shift: float = FxTracks.number(FxTracks.sample(_post_raw.get("chroma_px", 2.0), t), 2.0)
	var amount: float = clampf(FxTracks.number(FxTracks.sample(
		_post_raw.get("amount", 1.0), t), 1.0), 0.0, 1.0)
	if absf(shift) <= 0.05 or amount <= 0.001:
		return image
	var out: Image = image.duplicate()
	var w: int = image.get_width()
	var h: int = image.get_height()
	var off: int = int(roundf(shift * amount))
	for y in range(h):
		for x in range(w):
			var c: Color = image.get_pixel(x, y)
			var r: Color = image.get_pixel(clampi(x + off, 0, w - 1), y)
			var b: Color = image.get_pixel(clampi(x - off, 0, w - 1), y)
			out.set_pixel(x, y, Color(r.r, c.g, b.b, c.a))
	return out

func _draw_ring(layer: Dictionary, t: float) -> void:
	var t0: float = float(layer.get("t0", 0.0))
	var life: float = maxf(float(layer.get("life", 0.5)), 0.02)
	var age: float = t - t0
	if age < 0.0 or age > life:
		return
	var k: float = age / life
	var r: float = lerpf(
		_range(layer.get("radius", [4.0, 44.0]), 0, 4.0),
		_range(layer.get("radius", [4.0, 44.0]), 1, 44.0), k
	)
	var a: float = 1.0 - k
	var width: float = maxf(float(layer.get("width", 2.0)), 1.0)
	# 冲击波前沿应该"越扩越淡"而不是"越扩越黑"：亮色只回落到 60%，
	# 再由 alpha 完成消失。否则尾段会变成一个暗色圆环，看起来像气泡。
	var tail: float = maxf(float(layer.get("color_from", 2.0)),
		float(layer.get("color_to", _palette.size() - 1)) * 0.6)
	var c: Color = _ramp(lerpf(tail, float(layer.get("color_to", _palette.size() - 1)), a))
	var glow: float = clampf(float(layer.get("glow", 1.0)), 0.0, 4.0)
	for deg in range(0, 360, 4):
		var rad: float = deg_to_rad(float(deg))
		var x: float = cos(rad) * r
		var y: float = sin(rad) * r
		_disc(x, y, width * 0.5, c, a, glow * a)

func _draw_flash(layer: Dictionary, t: float) -> void:
	var t0: float = float(layer.get("t0", 0.0))
	var life: float = maxf(float(layer.get("life", 0.3)), 0.02)
	var age: float = t - t0
	if age < 0.0 or age > life:
		return
	var k: float = 1.0 - age / life
	var r0: float = _range(layer.get("radius", [1.0, 22.0]), 0, 1.0)
	var r1: float = _range(layer.get("radius", [1.0, 22.0]), 1, 22.0)
	var c: Color = _ramp(float(layer.get("color_to", _palette.size() - 1)))
	_disc(0.0, 0.0, lerpf(r1, r0, k), c, k * 0.8, 0.0)
	for iy in range(-int(r1) - 2, int(r1) + 3):
		for ix in range(-int(r1) - 2, int(r1) + 3):
			var d: float = sqrt(float(ix * ix + iy * iy)) / maxf(r1, 1.0)
			if d <= 1.0:
				_glow(float(ix), float(iy), c, k * (1.0 - d) * float(layer.get("glow", 1.6)))

# ---------- 扩展层：光束 / 拖尾 / 光环 / 环绕 / 故障 / 转场 ----------

func _draw_beam(layer: Dictionary, t: float) -> void:
	var age: float = t - float(layer.get("t0", 0.0))
	var life: float = maxf(float(layer.get("life", 0.4)), 0.02)
	if age < 0.0 or age > life:
		return
	var k: float = 1.0 - age / life
	var angle: float = deg_to_rad(_range(layer.get("angle", 0.0), 0, 0.0))
	var length: float = _range(layer.get("length", 44.0), 0, 44.0)
	var width: float = maxf(_range(layer.get("width", 3.0), 0, 3.0), 1.0)
	var glow: float = clampf(_range(layer.get("glow", 1.0), 0, 1.0), 0.0, 4.0)
	var hi: float = float(layer.get("color_to", _palette.size() - 1))
	var lo: float = float(layer.get("color_from", maxf(hi * 0.35, 0.0)))
	var steps: int = maxi(2, int(length))
	for i in range(steps):
		var u: float = float(i) / float(steps - 1)
		var x: float = cos(angle) * float(i)
		var y: float = sin(angle) * float(i)
		_disc(x, y, width * (1.0 - u * 0.55), _ramp(lerpf(lo, hi, 1.0 - u)),
			k * (1.0 - u * 0.7), glow * k * (1.0 - u))

func _draw_trail(layer: Dictionary, t: float) -> void:
	var age: float = t - float(layer.get("t0", 0.0))
	var life: float = maxf(float(layer.get("life", 0.6)), 0.02)
	if age < 0.0 or age > life:
		return
	var count: int = clampi(int(_range(layer.get("count", 48.0), 0, 48.0)), 1, 256)
	var angle: float = deg_to_rad(_range(layer.get("angle", 0.0), 0, 0.0))
	var speed: float = _range(layer.get("speed", 120.0), 0, 120.0)
	var gravity: float = _range(layer.get("gravity", 0.0), 0, 0.0)
	var drag: float = maxf(_range(layer.get("drag", 0.0), 0, 0.0), 0.0)
	var glow: float = clampf(_range(layer.get("glow", 0.8), 0, 0.8), 0.0, 4.0)
	var hi: float = float(layer.get("color_to", _palette.size() - 1))
	var lo: float = float(layer.get("color_from", maxf(hi * 0.4, 0.0)))
	for i in range(count):
		var head: float = age * _rand(_seed, i, 211)
		var p: Vector2 = _fly(cos(angle) * speed, sin(angle) * speed, head, gravity, drag)
		var k: float = (1.0 - head / life) * (1.0 - age / life)
		var c: Color = _ramp(lerpf(lo, hi, k))
		_px(p.x, p.y, c, clampf(k, 0.0, 1.0))
		_glow(p.x, p.y, c, glow * k)

func _draw_aura(layer: Dictionary, t: float) -> void:
	var period: float = maxf(float(layer.get("period", 0.8)), 0.05)
	var phase: float = fmod(t, period) / period
	var radius: float = _range(layer.get("radius", 22.0), 0, 22.0)
	var width: float = maxf(float(layer.get("width", 1.5)), 1.0)
	var glow: float = clampf(float(layer.get("glow", 0.8)), 0.0, 4.0)
	var hi: float = float(layer.get("color_to", _palette.size() - 1))
	var lo: float = float(layer.get("color_from", maxf(hi * 0.4, 0.0)))
	var pulses: int = clampi(int(layer.get("pulses", 2)), 1, 6)
	for p in range(pulses):
		var pp: float = fmod(phase + float(p) / float(pulses), 1.0)
		var r: float = radius * (0.55 + 0.45 * pp)
		var a: float = (1.0 - pp) * 0.85
		var c: Color = _ramp(lerpf(lo, hi, 1.0 - pp))
		for deg in range(0, 360, 6):
			var rad: float = deg_to_rad(float(deg))
			_disc(cos(rad) * r, sin(rad) * r, width, c, a, glow * a)

func _draw_orbit(layer: Dictionary, t: float) -> void:
	var count: int = clampi(int(_range(layer.get("count", 24.0), 0, 24.0)), 1, 256)
	var r0: float = _range(layer.get("radius", [8.0, 28.0]), 0, 8.0)
	var r1: float = _range(layer.get("radius", [8.0, 28.0]), 1, 28.0)
	var w0: float = _range(layer.get("omega", [60.0, 180.0]), 0, 60.0)
	var w1: float = _range(layer.get("omega", [60.0, 180.0]), 1, 180.0)
	var flatten: float = clampf(float(layer.get("flatten", 1.0)), 0.1, 2.0)
	var glow: float = clampf(float(layer.get("glow", 0.7)), 0.0, 4.0)
	var hi: float = float(layer.get("color_to", _palette.size() - 1))
	var lo: float = float(layer.get("color_from", maxf(hi * 0.4, 0.0)))
	for i in range(count):
		var a0: float = _rand(_seed, i, 223) * TAU
		var r: float = lerpf(r0, r1, _rand(_seed, i, 227))
		var w: float = deg_to_rad(lerpf(w0, w1, _rand(_seed, i, 229)))
		var angle: float = a0 + w * t
		var c: Color = _ramp(lerpf(lo, hi, _rand(_seed, i, 233)))
		var x: float = cos(angle) * r
		var y: float = sin(angle) * r * flatten
		_px(x, y, c, 0.9)
		_glow(x, y, c, glow)

func _draw_glitch(layer: Dictionary, t: float) -> void:
	var age: float = t - float(layer.get("t0", 0.0))
	var life: float = maxf(float(layer.get("life", 0.5)), 0.02)
	if age < 0.0 or age > life:
		return
	var k: float = 1.0 - age / life
	var bands: int = clampi(int(layer.get("bands", 14)), 1, 48)
	var amp: float = _range(layer.get("amplitude", 16.0), 0, 16.0)
	var glow: float = clampf(float(layer.get("glow", 0.5)), 0.0, 4.0)
	var frame: int = int(t * 30.0)
	var band_h: float = float(_h) / float(bands)
	var half_w: float = _w * 0.5
	var half_h: float = _h * 0.5
	var hi: float = float(layer.get("color_to", _palette.size() - 1))
	for b in range(bands):
		if _rand(_seed + frame, b, 241) < 0.35:
			continue
		var shift: float = (_rand(_seed + frame, b, 251) - 0.5) * amp
		# 条带只占画面的一小段、横向位置随机：整幅等长的横线会被读成"扫描线"，
		# 谁也不会觉得那是故障。随机起点的短横段才是"信号错位"。
		var length: float = _w * (0.16 + _rand(_seed + frame, b, 257) * 0.36)
		var y: float = -half_h + band_h * float(b)
		var x0: float = _rand(_seed + frame, b, 263) * maxf(_w - length, 1.0) - half_w + shift
		var c: Color = _ramp(float(layer.get("color_from", maxf(hi * 0.5, 0.0))))
		var c2: Color = _ramp(hi)
		_line(x0, y, x0 + length, y, c, k)
		_line(x0 + 2.0, y + 1.0, x0 + length + 2.0, y + 1.0, c2, k * 0.55)
		_glow(x0 + length * 0.5, y, c2, glow * k)

func _draw_wipe(layer: Dictionary, t: float) -> void:
	var age: float = t - float(layer.get("t0", 0.0))
	var life: float = maxf(float(layer.get("life", 0.7)), 0.02)
	if age < 0.0 or age > life:
		return
	var k: float = age / life
	var mode: String = String(layer.get("mode", "iris"))
	var max_r: float = sqrt(float(_w * _w + _h * _h)) * 0.5
	var r: float = k * max_r * 1.1
	var c: Color = _ramp(float(layer.get("color_to", _palette.size() - 1)))
	var glow: float = clampf(float(layer.get("glow", 1.0)), 0.0, 4.0)
	# wipe 按屏幕像素逐点求距离，所以走**逆变换**把屏幕坐标拉回图层局部空间：
	# 变换后的擦除形状（旋转/缩放/位移）才对得上其他层，而不是一张永远水平的圆。
	var inverse: Transform2D = _layer_xf.affine_inverse()
	for sy in range(_h):
		for sx in range(_w):
			var local: Vector2 = inverse * Vector2(float(sx) - _tx, float(sy) - _ty)
			var lx: float = local.x
			var ly: float = local.y
			var d: float = 0.0
			match mode:
				"diamond":
					d = absf(lx) + absf(ly)
				"horizontal":
					d = lx + _w * 0.5
				"star":
					# 星形收拢：半径按 5 瓣调制。以前"星形收拢"写的是 mode=iris，
					# 于是和"圆形收拢"逐像素相同 —— 库里有名字没实现的形态，这里补上。
					var ang: float = atan2(ly, lx)
					d = sqrt(lx * lx + ly * ly) * (1.0 + 0.42 * sin(ang * 5.0))
				_:
					d = sqrt(lx * lx + ly * ly)
			if absf(d - r) <= 1.2:
				_put(sx, sy, c, 1.0)
				_add(sx, sy, c, glow * (1.0 - k))

# ---------- 闭式动力学层 ----------

## 碎片/火花/余烬/火焰/烟。所有位置来自 FxDynamics.state()，是 t 的纯函数，
## 因此这一层同样支持逐帧 scrub 与烘焙，但带有重力、地面反弹与二次发射。
func _draw_debris(layer: Dictionary, t: float, index: int) -> void:
	# _compiled 槽位可能是 null（该层带轨道 = 原子表按帧重建），不能用 typed Array 接
	var cached: Variant = _compiled[index] if index < _compiled.size() else null
	var atoms: Array = cached if cached is Array else []
	if not (cached is Array):
		var ground: float = float(layer.get("ground", 0.0)) * float(_h)
		atoms = FxDynamics.compile(layer, _seed + index * 101, ground)
	if atoms.is_empty():
		return
	for atom in atoms:
		# 循环特效：同一个原子按周期重播，因此可能同时存在多个副本。
		var ages: Array = []
		if _loop:
			var born: float = fmod(float(atom["birth"]), _duration)
			var a: float = fmod(t - born + _duration, _duration)
			while a < float(atom["life"]) and ages.size() < 3:
				ages.append(a)
				a += _duration
		else:
			var once: float = t - float(atom["birth"])
			if once >= 0.0 and once < float(atom["life"]):
				ages.append(once)
		for age in ages:
			_draw_debris_atom(atom, float(age))

func _draw_debris_atom(atom: Dictionary, age: float) -> void:
	var st: Dictionary = FxDynamics.state_age(atom, age)
	if not bool(st["alive"]):
		return
	var k: float = float(st["k"])
	var x: float = float(st["x"])
	var y: float = float(st["y"])
	var vx: float = float(st["vx"])
	var vy: float = float(st["vy"])
	var size: float = float(atom["size"])
	var glow: float = float(atom["glow"])
	var col: Color = _ramp(lerpf(float(atom["tint0"]), float(atom["tint1"]), k))
	match String(atom["kind"]):
		"smoke":
			var r: float = size * (0.8 + (1.0 - k) * 2.4)
			_disc(x, y, r, col, k * 0.42, 0.0)
		"fire":
			# 三层叠出火苗：暗色外缘、亮色核心、顶部火舌。单层圆点会读成"沙子"。
			var fr: float = size * (0.6 + (1.0 - k) * 0.9)
			var core_tint: float = minf(float(atom["tint1"]), 64.0)
			var rim: Color = _ramp(lerpf(float(atom["tint0"]), core_tint, k * 0.6))
			var core: Color = _ramp(minf(core_tint + 1.0, float(_palette.size() - 1)))
			_disc(x, y, fr, rim, minf(1.0, k * 2.0) * 0.5, 0.0)
			_disc(x - fr * 0.16, y - fr * 0.2, fr * 0.72, core, minf(1.0, k * 2.2) * 0.78, glow * 0.5)
			if fr > 1.5:
				_disc(x, y - fr * 0.95, fr * 0.38, core, minf(1.0, k * 1.5) * 0.55, 0.0)
			_glow(x, y, core, glow * 0.22 * k)
		"ember":
			if sin(age * 34.0 + float(atom["jitter"])) > -0.35:
				_px(x, y, col, minf(1.0, k * 2.2))
				# a=0 的圆盘只留下加性光，形成柔和外发光
				_disc(x, y, 1.4 + size * 0.6, col, 0.0, glow * 0.4 * k)
		"shard":
			# 小方块随自转翻面：用两个方向的短线段模拟硬边碎片
			var a: float = float(atom["spin"]) * age
			var ca: float = cos(a)
			var sa: float = sin(a)
			var half: float = maxf(0.6, size * 0.5)
			_line(x - ca * half, y - sa * half, x + ca * half, y + sa * half, col, minf(1.0, k * 3.0))
			_line(x + sa * half * 0.6, y - ca * half * 0.6,
				x - sa * half * 0.6, y + ca * half * 0.6, _ramp(float(atom["tint0"])), minf(1.0, k * 3.0) * 0.7)
		_:
			# spark：沿速度方向拖出尾迹，速度越快尾越长
			var sp: float = sqrt(vx * vx + vy * vy)
			var alpha: float = minf(1.0, k * 2.4)
			if sp > 0.5:
				var len: float = minf(9.0, 1.2 + sp * 0.022)
				_line(x - vx / sp * len, y - vy / sp * len, x, y, col, alpha)
			else:
				_px(x, y, col, alpha)
			_disc(x, y, 1.6 + size * 0.5, col, 0.0, glow * 0.45 * k)



## 宽松布尔读取：JSON / 手写配方里可能是 true / "true" / 1。
static func _as_bool(value: Variant, fallback: bool) -> bool:
	if value is bool:
		return value
	if value is String:
		return String(value).to_lower() == "true"
	if value is int or value is float:
		return float(value) != 0.0
	return fallback

## 把一层的像素量按 unit 缩放（递归处理 [min,max] 区间与 child 子事件）。
## 数值统一转 float：区间参数本来就走 _range()，不会因为 int 丢失小数。
static func _scale_layer(layer: Dictionary, unit: float) -> Dictionary:
	var out: Dictionary = layer.duplicate(true)
	if is_equal_approx(unit, 1.0):
		return out
	for key in PIXEL_KEYS:
		if out.has(key):
			out[key] = _scale_value(out[key], unit)
	if out.get("child") is Dictionary:
		out["child"] = _scale_layer(out["child"], unit)
	return out

static func _scale_value(value: Variant, unit: float) -> Variant:
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_scale_value(item, unit))
		return arr
	if value is Dictionary:
		# 关键帧轨道：只缩放每一帧的数值，不动时间轴
		var dict: Dictionary = (value as Dictionary).duplicate(true)
		if dict.has("track") and dict["track"] is Array:
			var keys: Array = []
			for entry in dict["track"]:
				if entry is Array and (entry as Array).size() >= 2:
					keys.append([entry[0], _scale_value(entry[1], unit)])
				else:
					keys.append(entry)
			dict["track"] = keys
		return dict
	if value is int or value is float:
		return float(value) * unit
	return value

## 当前画布尺寸（UI 用来显示与校验）。
func canvas_size() -> Vector2i:
	return Vector2i(_w, _h)

## 设计空间 -> 渲染空间的换算系数，工具与自检用它验证缩放是否正确。
func unit_scale() -> float:
	return _unit

## 当前是否按画布拉伸内容（false = 1:1 居中）。
func is_stretch() -> bool:
	return _stretch

# ---------- 合成：颜色覆盖 + 加性光，透明背景上光转成带 alpha 的颜色 ----------

func _composite() -> Image:
	var out: PackedByteArray = PackedByteArray()
	out.resize(_w * _h * 4)
	for i in range(_w * _h):
		var ci: int = i * 4
		var li: int = i * 3
		var ca: float = float(_color[ci + 3]) / 255.0
		var lr: float = minf(float(_light[li]) * _light_k, 255.0)
		var lg: float = minf(float(_light[li + 1]) * _light_k, 255.0)
		var lb: float = minf(float(_light[li + 2]) * _light_k, 255.0)
		var peak: float = maxf(lr, maxf(lg, lb))
		var oa: float = maxf(ca, peak / 255.0)
		if oa <= 0.0:
			continue
		out[ci] = int(clampf((float(_color[ci]) * ca + lr) / oa, 0.0, 255.0))
		out[ci + 1] = int(clampf((float(_color[ci + 1]) * ca + lg) / oa, 0.0, 255.0))
		out[ci + 2] = int(clampf((float(_color[ci + 2]) * ca + lb) / oa, 0.0, 255.0))
		out[ci + 3] = int(clampf(oa, 0.0, 1.0) * 255.0)
	return Image.create_from_data(_w, _h, false, Image.FORMAT_RGBA8, out)

## 公开的 "#rgb" / "#rrggbb" 解析，界面层的调色板控件也复用它，避免两份实现漂移。
static func hex_to_color(value: String) -> Color:
	var s: String = value.trim_prefix("#")
	if s.length() == 3:
		s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2]
	if s.length() < 6:
		return Color.WHITE
	var n: int = ("0x" + s.substr(0, 6)).hex_to_int()
	return Color(
		float((n >> 16) & 255) / 255.0,
		float((n >> 8) & 255) / 255.0,
		float(n & 255) / 255.0
	)
