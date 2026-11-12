class_name FxShaderRuntime
extends RefCounted
## 离屏着色器：把 `.gdshader` 编译进一个隐藏的 SubViewport，渲染后读回 Image。
##
## 为什么放在插件里而不是内核：
##   · 着色器只是「一种算子实现」，节点 JSON 里写 `op: shader.image` 就够了；
##   · GPU 资源不能跨线程共享，所以节点定义声明 `gpu: true`，渲染服务会自动
##     把这一帧收回主线程 —— 内核不需要认识 Shader 这个类型。
##
## 约定（写进 README，供用户照着写着色器）：
##   · 输入图像绑到 `input_tex`（也认 `u_texture` / `source_texture`）；
##   · 引擎自动填 `u_time`（秒）、`u_frame`（帧号）、`u_resolution`（画布尺寸）；
##   · 其余 uniform 由节点参数 `uniforms` 按 「名称 = 值」逐行覆盖。
##
## 无头环境没有渲染器（dummy），这里直接回退：返回输入图，不让整条链断掉。

const DEFAULT_CODE := """shader_type canvas_item;

uniform sampler2D input_tex : hint_default_black;
uniform vec2 u_resolution;
uniform float u_time;

void fragment() {
	COLOR = texture(input_tex, UV);
}
"""

## 输入纹理的可能名字（按优先级）。用惯哪个都行，不必改我们的节点。
const INPUT_NAMES := ["input_tex", "u_texture", "source_texture", "tex"]

static var _viewport: SubViewport = null
static var _material: ShaderMaterial = null
static var _shader: Shader = null
static var _code_key: String = ""
static var _uniforms: Array = []
static var _warned: bool = false
## 预热标记：新建/改尺寸/换代码后的**第一次**绘制会拿到还没就绪的渲染目标，
## 必须多画一遍才准。这里记住「当前尺寸+代码已经预热过」。
static var _warm_key: String = ""


## 预热：插件启用时先把视口建出来。
##
## 实测（4.7）：**视口刚建出来的那一帧读回来是空的**，同帧再画一次也不行，
## 必须让引擎跑过一帧；之后改尺寸、换着色器代码都能同帧读到正确结果。
## 所以视口要在第一次真正求值之前建好 —— 启动时预热一次，运行期就不会有
## 「第一帧是灰的」这种事了。
static func prewarm() -> void:
	if not available() or not on_main_thread():
		return
	_ensure_material()
	_ensure_viewport(Vector2i(32, 32))
	# 先画一次，把渲染目标真正建出来（这一帧读回来还是空的，不用管）。
	# 之后无论怎么改尺寸、换代码，都能在同一帧里读到正确结果。
	RenderingServer.force_draw()


## 释放视口（插件停用时调用；不释放会留下一个常驻的全屏渲染目标）。
static func shutdown() -> void:
	close_bridge()
	if _viewport != null and is_instance_valid(_viewport):
		# 退出流程里没有下一帧可以等，queue_free 会留到进程结束（报 ObjectDB 泄漏）。
		if _viewport.get_parent() != null:
			_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_material = null
	_shader = null
	_code_key = ""
	_uniforms = []
	_warm_key = ""
static func available() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return RenderingServer.get_video_adapter_name() != ""


## 只能在主线程调用：GPU 资源不能跨线程碰。
## 渲染服务本来就会因为节点定义里的 gpu 标记回到主线程，这里是最后一道保险。
static func on_main_thread() -> bool:
	return OS.get_thread_caller_id() == OS.get_main_thread_id()


## 一段着色器里声明了哪些 uniform（给界面显示用；编译失败时返回空）。
static func uniform_names(code: String) -> Array:
	if not available() or not on_main_thread():
		return []
	_ensure_material()
	if _code_key != code:
		_apply_code(code)
	var out: Array = []
	for item in _uniforms:
		out.append(String((item as Dictionary).get("name", "")))
	return out


## 求值入口：输入图 → 着色器 → 新图。
static func render(code: String, input: Image, size: Vector2i,
		overrides: Dictionary, seconds: float, frame: int) -> Image:
	var canvas := Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	if not available() or not on_main_thread():
		if not _warned:
			_warned = true
			push_warning("FxShaderRuntime：当前环境不能离屏渲染着色器，节点按「原样输出」处理")
		return _fallback(input, canvas)
	_ensure_material()
	_ensure_viewport(canvas)
	if _code_key != code:
		_apply_code(code)
	_bind_input(input, canvas)

	# 先填引擎给的值，再让用户覆盖 —— 用户显式写了 u_time 就以用户的为准。
	_set_uniform("u_resolution", Vector2(canvas))
	_set_uniform("u_time", seconds)
	_set_uniform("u_frame", float(frame))
	for key in overrides.keys():
		_set_uniform(String(key), overrides[key])

	var key := "%dx%d|%d" % [canvas.x, canvas.y, code.hash()]
	RenderingServer.force_draw()
	var image := _viewport.get_texture().get_image()
	if _warm_key != key:
		# 刚建/刚改尺寸的那一帧，渲染目标里还没有内容。这一帧先如实交出去，
		# 同时请渲染服务补算一帧 —— 停顿状态下也能自动变正确。
		_warm_key = key
		FxRenderGate.request_reframe()
	if image == null or image.is_empty():
		return _fallback(input, canvas)
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


# ================= 跨线程 GPU 桥 =================
##
## 预渲染/求帧工作线程里遇到 shader.image 时不能碰 SubViewport（只能渲染线程用）。
## 旧做法是「发现图里有 GPU 节点就把整帧 600ms 的求值拉回主线程」，UI 因此卡死。
## 现在把 GPU 渲染请求排进队列，由主线程每帧 pump 一小批，结果写回表；
## 工作线程只等自己那一条结果（超时才回退）。GPU 节点依然拿到真正的着色器结果，
## 而整条求值链保持在工作线程并行。

const BRIDGE_TIMEOUT_MS := 1500
const MAX_PUMP_PER_FRAME := 4

static var _bridge_mutex := Mutex.new()
static var _bridge_pending: Array[Dictionary] = []
static var _bridge_results: Dictionary = {}
static var _bridge_next_id: int = 0
static var _bridge_open: bool = false


static func open_bridge() -> void:
	_bridge_open = true


## 停用/退出时唤醒所有还在等的线程：给一个空结果让它们立刻回退，不死锁。
static func close_bridge() -> void:
	_bridge_mutex.lock()
	_bridge_open = false
	for item in _bridge_pending:
		var job: Dictionary = item
		_bridge_results[int(job.get("id", -1))] = null
	_bridge_pending.clear()
	_bridge_mutex.unlock()


## 算子入口。主线程直接算；工作线程走桥等结果。
static func render_bridged(code: String, input: Image, size: Vector2i,
		overrides: Dictionary, seconds: float, frame: int) -> Image:
	if on_main_thread():
		return render(code, input, size, overrides, seconds, frame)
	if not available() or not _bridge_open:
		return _fallback(input, size)
	var id: int
	_bridge_mutex.lock()
	id = _bridge_next_id
	_bridge_next_id += 1
	_bridge_pending.append({
		"id": id, "code": code, "input": input, "size": size,
		"overrides": overrides.duplicate(true), "seconds": seconds, "frame": frame,
	})
	_bridge_mutex.unlock()
	var deadline := Time.get_ticks_msec() + BRIDGE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_bridge_mutex.lock()
		var has := _bridge_results.has(id)
		var value: Variant = _bridge_results.get(id)
		if has:
			_bridge_results.erase(id)
		_bridge_mutex.unlock()
		if has:
			return value as Image if value is Image else _fallback(input, size)
		OS.delay_usec(250)
	return _fallback(input, size)


## 主线程每个 process 调一次。限流避免 6 条预渲染线程把界面帧时间吃掉。
static func pump() -> void:
	if not on_main_thread() or not _bridge_open:
		return
	_bridge_mutex.lock()
	if _bridge_pending.is_empty():
		_bridge_mutex.unlock()
		return
	var batch: Array[Dictionary] = []
	while batch.size() < MAX_PUMP_PER_FRAME and not _bridge_pending.is_empty():
		var job: Dictionary = _bridge_pending.pop_front()
		batch.append(job)
	_bridge_mutex.unlock()
	for job in batch:
		var image := render(String(job.get("code", "")), job.get("input") as Image,
			job.get("size", Vector2i(1, 1)) as Vector2i,
			job.get("overrides", {}) as Dictionary,
			float(job.get("seconds", 0.0)), int(job.get("frame", 0)))
		_bridge_mutex.lock()
		_bridge_results[int(job.get("id", -1))] = image
		_bridge_mutex.unlock()


static func _fallback(input: Image, canvas: Vector2i) -> Image:
	if input != null and not input.is_empty():
		return input.duplicate()
	return FxImageUtil.new_canvas(canvas)


static func _ensure_material() -> void:
	if _material != null and is_instance_valid(_material):
		return
	_material = ShaderMaterial.new()
	_shader = Shader.new()
	_shader.code = DEFAULT_CODE
	_material.shader = _shader
	_code_key = DEFAULT_CODE


static func _ensure_viewport(size: Vector2i) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	if _viewport == null or not is_instance_valid(_viewport):
		_viewport = SubViewport.new()
		_warm_key = ""
		_viewport.name = "FxShaderViewport"
		_viewport.disable_3d = true
		_viewport.transparent_bg = false
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
		tree.root.add_child(_viewport)
		var rect := ColorRect.new()
		rect.name = "Surface"
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.material = _material
		_viewport.add_child(rect)
	else:
		var surface := _viewport.get_node_or_null("Surface") as ColorRect
		if surface != null and surface.material != _material:
			surface.material = _material
	if _viewport.size != size:
		_viewport.size = size
	var rect2 := _viewport.get_node_or_null("Surface") as Control
	if rect2 != null:
		rect2.position = Vector2.ZERO
		rect2.size = Vector2(size)


static func _apply_code(code: String) -> void:
	_code_key = code
	_shader.code = code
	_material.shader = _shader
	# 编译是惰性的：get_shader_uniform_list() 会顺手触发解析。
	_uniforms = _shader.get_shader_uniform_list()


static func _bind_input(input: Image, canvas: Vector2i) -> void:
	var target := _input_name()
	if target.is_empty():
		return
	if input == null or input.is_empty():
		_material.set_shader_parameter(target, null)
		return
	var image := input
	if image.get_width() != canvas.x or image.get_height() != canvas.y:
		image = input.duplicate()
		image.resize(canvas.x, canvas.y, Image.INTERPOLATE_BILINEAR)
	_material.set_shader_parameter(target, ImageTexture.create_from_image(image))


## 着色器里第一个 sampler2D 类型的 uniform 名（就是输入图该绑的位置）。
## 先按约定名字找；没有约定的，就退而用第一个纹理型 uniform ——
## 用户只声明了一个 sampler2D 时，那个显然就是输入图。
static func _input_name() -> String:
	var first := ""
	for item in _uniforms:
		var uniform: Dictionary = item
		if int(uniform.get("type", -1)) != TYPE_OBJECT:
			continue
		var name := String(uniform.get("name", ""))
		if INPUT_NAMES.has(name):
			return name
		if first.is_empty():
			first = name
	return first


## 按 uniform 声明的类型做一次转换；类型不明就原样塞进去。
static func _set_uniform(name: String, value: Variant) -> void:
	var type := -1
	for item in _uniforms:
		var uniform: Dictionary = item
		if String(uniform.get("name", "")) == name:
			type = int(uniform.get("type", -1))
			break
	if type == -1:
		return
	_material.set_shader_parameter(name, _coerce(value, type))


static func _coerce(value: Variant, type: int) -> Variant:
	match type:
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_VECTOR2:
			return _to_vector2(value)
		TYPE_VECTOR3:
			return _to_vector3(value)
		TYPE_VECTOR4:
			return _to_vector4(value)
		TYPE_COLOR:
			return value if value is Color else Color(String(value))
	return value


static func _to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value)
	if value is Array and (value as Array).size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2(float(value), float(value))


static func _to_vector3(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3(float(value), float(value), float(value))


static func _to_vector4(value: Variant) -> Vector4:
	if value is Vector4:
		return value
	if value is Color:
		return Vector4(value.r, value.g, value.b, value.a)
	if value is Array and (value as Array).size() >= 4:
		return Vector4(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	return Vector4(float(value), float(value), float(value), float(value))
