class_name FxGpuCompute
extends RefCounted
## GPU 计算通道：用 RenderingDevice 的 compute shader 直接读写像素字节。
##
## 为什么不用 SubViewport：canvas 通道的 `get_texture().get_image()` 要等下一帧才拿到本次结果，
## `force_draw()` 也只提交不等待，读回来的是上一帧（还可能被 sRGB 转换动过颜色）。
## compute 走 `submit() + sync() + buffer_get_data()`，是**真同步**，且像素以 uint 原样进出，
## 与 CPU 的 RGBA8 字节语义完全一致。
##
## 一个着色器承载三个 op（0/1 = 可分离模糊的横/竖、2 = 混合、3 = 锐化），
## 靠 cfg 缓冲区传参，避免为每个算子编译一份 SPIR-V。

const COMPUTE_CODE := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SrcBuf { uint src_px[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer TopBuf { uint top_px[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer CfgBuf { uint cfg[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer DstBuf { uint dst_px[]; };

uint ch(uint p, uint s) { return (p >> s) & 255u; }
vec4 unpack_px(uint p) {
	return vec4(float(ch(p, 0u)), float(ch(p, 8u)), float(ch(p, 16u)), float(ch(p, 24u))) / 255.0;
}
uint pack_px(vec4 c) {
	uvec4 q = uvec4(round(clamp(c, 0.0, 1.0) * 255.0));
	return q.r | (q.g << 8u) | (q.b << 16u) | (q.a << 24u);
}

void main() {
	uint W = cfg[0], H = cfg[1], R = cfg[2], op = cfg[3];
	uint mix_mode = cfg[4], amount_m = cfg[5], dir_x = cfg[6], dir_y = cfg[7];
	uvec2 xy = gl_GlobalInvocationID.xy;
	if (xy.x >= W || xy.y >= H) return;
	uint idx = xy.y * W + xy.x;
	vec4 outc = vec4(0.0);
	if (op < 2u) {
		vec4 sum = vec4(0.0);
		float count = 0.0;
		for (int k = -128; k <= 128; k++) {
			if (float(k) > float(R)) break;
			if (float(k) < -float(R)) continue;
			int sx = clamp(int(xy.x) + k * int(dir_x), 0, int(W) - 1);
			int sy = clamp(int(xy.y) + k * int(dir_y), 0, int(H) - 1);
			sum += unpack_px(src_px[uint(sy) * W + uint(sx)]);
			count += 1.0;
		}
		outc = sum / max(count, 1.0);
	} else if (op == 2u) {
		vec4 base = unpack_px(src_px[idx]);
		vec4 top = unpack_px(top_px[idx]);
		float amount = float(amount_m) / 1000.0;
		float sa = top.a * amount;
		float da = base.a;
		float oa = sa + da * (1.0 - sa);
		if (oa <= 0.0001) {
			outc = vec4(0.0);
		} else {
			vec3 br = top.rgb;
			if (mix_mode == 1u) {
				br = min(base.rgb + top.rgb, vec3(1.0));
			} else if (mix_mode == 2u) {
				br = base.rgb * top.rgb;
			} else if (mix_mode == 3u) {
				br = vec3(1.0) - (vec3(1.0) - base.rgb) * (vec3(1.0) - top.rgb);
			} else if (mix_mode == 4u) {
				br = mix(2.0 * base.rgb * top.rgb,
					vec3(1.0) - 2.0 * (vec3(1.0) - base.rgb) * (vec3(1.0) - top.rgb),
					step(vec3(0.5), base.rgb));
			} else if (mix_mode == 5u) {
				br = max(base.rgb - top.rgb, vec3(0.0));
			}
			float k = sa / oa;
			float kb = da * (1.0 - sa) / oa;
			outc = vec4(clamp(br * k + base.rgb * kb, 0.0, 1.0), oa);
		}
	} else if (op == 4u) {
		// 描边：cfg[8]=厚度 cfg[9]=inside cfg[10]=阈值*1000 cfg[11..13]=颜色*1000
		const ivec2 DIRS[8] = ivec2[8](
			ivec2(1,0), ivec2(-1,0), ivec2(0,1), ivec2(0,-1),
			ivec2(1,1), ivec2(-1,1), ivec2(1,-1), ivec2(-1,-1));
		int thick = int(cfg[8]);
		bool inside = cfg[9] == 1u;
		float threshold = float(cfg[10]) / 1000.0;
		vec3 edgeColor = vec3(float(cfg[11]), float(cfg[12]), float(cfg[13])) / 1000.0;
		vec4 own = unpack_px(src_px[idx]);
		float own_a = own.a;
		float edge = 0.0;
		for (int k = 0; k < 8; k++) {
			ivec2 d = DIRS[k] * thick;
			int sx = clamp(int(xy.x) + d.x, 0, int(W) - 1);
			int sy = clamp(int(xy.y) + d.y, 0, int(H) - 1);
			float na = unpack_px(src_px[uint(sy) * W + uint(sx)]).a;
			edge = max(edge, inside ? own_a - na : na - own_a);
		}
		float st = clamp((edge - threshold) / 0.15, 0.0, 1.0);
		float strength = st * st * (3.0 - 2.0 * st);
		float out_a = max(own_a, inside ? strength * own_a : strength);
		outc = vec4(clamp(mix(own.rgb, edgeColor, strength), 0.0, 1.0), out_a);
	} else {
		vec4 center = unpack_px(src_px[idx]);
		uint xl = xy.x > 0u ? xy.x - 1u : 0u;
		uint xr = xy.x + 1u < W ? xy.x + 1u : W - 1u;
		uint yu = xy.y > 0u ? xy.y - 1u : 0u;
		uint yd = xy.y + 1u < H ? xy.y + 1u : H - 1u;
		vec4 blur = (unpack_px(src_px[yu * W + xl]) + unpack_px(src_px[yu * W + xr])
			+ unpack_px(src_px[yd * W + xl]) + unpack_px(src_px[yd * W + xr])) * 0.25;
		float amount = float(amount_m) / 1000.0;
		outc = vec4(clamp(center.rgb + (center.rgb - blur.rgb) * amount, 0.0, 1.0), center.a);
	}
	dst_px[idx] = pack_px(outc);
}
"""

static var _rd: RenderingDevice = null
static var _shader: RID = RID()
static var _pipeline: RID = RID()


static func available() -> bool:
	return FxGpuDevice.available()


## 跑一次 compute。src/top 是 RGBA8 Image；返回同尺寸 Image，失败返回 null（调用方回落 CPU）。
static func run(src: Image, top: Image, op: int, radius: int = 0,
		mode_id: int = 0, amount: float = 1.0, dir: Vector2i = Vector2i.ZERO,
		extra: PackedInt32Array = PackedInt32Array()) -> Image:
	if src == null or src.is_empty() or not available():
		return null
	var device := _device()
	if device == null:
		return null
	if not _ensure_pipeline(device):
		return null
	var source := _rgba(src)
	var upper := _rgba(top) if top != null else source
	if source.get_size() != upper.get_size():
		return null
	var size: Vector2i = source.get_size()
	var pixels: int = size.x * size.y
	var src_rid := device.storage_buffer_create(pixels * 4, source.get_data())
	var top_rid := device.storage_buffer_create(pixels * 4, upper.get_data())
	var cfg := PackedInt32Array([
		size.x, size.y, clampi(radius, 0, 128), op,
		mode_id, int(round(clampf(amount, 0.0, 1.0) * 1000.0)), dir.x, dir.y,
	])
	cfg.append_array(extra)
	var cfg_rid := device.storage_buffer_create(cfg.size() * 4, cfg.to_byte_array())
	var dst_rid := device.storage_buffer_create(pixels * 4)
	var set_rid := device.uniform_set_create([
		_uniform(0, src_rid), _uniform(1, top_rid),
		_uniform(2, cfg_rid), _uniform(3, dst_rid),
	], _shader, 0)
	if not set_rid.is_valid():
		_free(device, [src_rid, top_rid, cfg_rid, dst_rid])
		return null
	var list := device.compute_list_begin()
	device.compute_list_bind_compute_pipeline(list, _pipeline)
	device.compute_list_bind_uniform_set(list, set_rid, 0)
	device.compute_list_dispatch(list, ceili(float(size.x) / 8.0), ceili(float(size.y) / 8.0), 1)
	device.compute_list_end()
	# 引擎主 RenderingDevice 不是 local device，不能 submit()/sync()；
	# buffer_get_data() 自身就是同步栅栏，读回时计算必定已完成。
	var bytes := device.buffer_get_data(dst_rid)
	_free(device, [src_rid, top_rid, cfg_rid, dst_rid])
	if bytes.size() != pixels * 4:
		return null
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, bytes)


static func blur(image: Image, radius: int) -> Image:
	var horizontal := run(image, null, 0, radius, 0, 1.0, Vector2i(1, 0))
	if horizontal == null:
		return null
	return run(horizontal, null, 1, radius, 0, 1.0, Vector2i(0, 1))


static func mix(base: Image, top: Image, amount: float, mode_id: int) -> Image:
	return run(base, top, 2, 0, mode_id, amount)


static func sharpen(image: Image, amount: float) -> Image:
	return run(image, null, 3, 0, 0, amount)



# ================= 工作线程桥（批量化合流） =================
#
# `compute_list_begin` 只能在渲染线程调用，工作线程必须经
# `RenderingServer.call_on_render_thread(cb)` 提交。单次往返实测约 16ms：
# 6 条预渲染线程各等各的，60 帧 × 每帧若干算子就能把整段拖到十几秒。
#
# 改成**领导线程 + 批**：谁先把作业放进队列，谁负责发起**一次**渲染线程回调；
# 回调一次抽干队列（含等待期间别人新塞进来的），逐个执行后回写结果。
# N 条线程的 M 个请求于是合流成 ⌈M/批⌉ 次往返（实测约 1ms/请求）。
# 队列抽空时回调主动清掉领导标记，下一批由下一个请求重新发起。
#
# 主线程 / 渲染线程直接执行，不排队 —— 主线程排队会等自己的回调而死锁。

const BRIDGE_TIMEOUT_MS := 2000
## 等结果的轮询间隔：越小延迟越低，越大越省 CPU。
const BRIDGE_POLL_USEC := 50

static var _bridge_jobs: int = 0
static var _bridge_fallbacks: int = 0
static var _bridge_batches: int = 0
static var _bridge_mutex := Mutex.new()
static var _bridge_queue: Array[Dictionary] = []
static var _bridge_next_id: int = 0
static var _bridge_leader: bool = false


static func bridged_calls() -> int:
	return _bridge_jobs


static func bridge_fallbacks() -> int:
	return _bridge_fallbacks


## 合流效率诊断：批次数 / 请求数（比值越接近 1 合流越好）。
static func bridge_batches() -> int:
	return _bridge_batches


## job 是纯参数的 Dictionary，不含 Image 之外的对象；返回 null 表示回落 CPU。
static func bridged(job: Dictionary) -> Image:
	if not available():
		return null
	if RenderingServer.is_on_render_thread() \
			or int(OS.get_thread_caller_id()) == int(OS.get_main_thread_id()):
		return _exec(job)
	var slot := {"done": false, "result": null, "id": 0}
	var lead := false
	_bridge_mutex.lock()
	slot["id"] = _bridge_next_id
	_bridge_next_id += 1
	_bridge_jobs += 1
	_bridge_queue.append({"id": int(slot["id"]), "job": job, "slot": slot})
	if not _bridge_leader:
		_bridge_leader = true
		lead = true
	_bridge_mutex.unlock()
	if lead:
		RenderingServer.call_on_render_thread(func() -> void: _drain())
	var deadline := Time.get_ticks_msec() + BRIDGE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if bool(slot["done"]):
			return slot["result"] as Image
		OS.delay_usec(BRIDGE_POLL_USEC)
	_bridge_fallbacks += 1
	# 超时：把自己的作业从队列里摘掉，别让渲染线程算完写进没人等的槽。
	_bridge_mutex.lock()
	if not bool(slot["done"]):
		for i in range(_bridge_queue.size() - 1, -1, -1):
			if int((_bridge_queue[i] as Dictionary).get("id", -1)) == int(slot["id"]):
				_bridge_queue.remove_at(i)
				break
		# 回调可能根本没被调度（渲染线程停摆 / 退出中）：队列空了就把领导权放掉，
		# 否则后续每个请求都白等一次超时。
		if _bridge_queue.is_empty():
			_bridge_leader = false
	_bridge_mutex.unlock()
	return null


## 渲染线程侧：一次抽干队列。必须在这里清领导标记，否则后续批次没人发起。
static func _drain() -> void:
	_bridge_batches += 1
	while true:
		_bridge_mutex.lock()
		if _bridge_queue.is_empty():
			_bridge_leader = false
			_bridge_mutex.unlock()
			return
		var batch := _bridge_queue.duplicate()
		_bridge_queue.clear()
		_bridge_mutex.unlock()
		for item in batch:
			var entry: Dictionary = item
			var slot: Dictionary = entry.get("slot", {})
			var done: Image = _exec(entry.get("job", {}) as Dictionary)
			slot["result"] = done
			slot["done"] = true


static func _exec(job: Dictionary) -> Image:
	match String(job.get("kind", "")):
		"blur":
			var src: Image = job["src"]
			var r := int(job["radius"])
			var horizontal := run(src, null, 0, r, 0, 1.0, Vector2i(1, 0))
			if horizontal == null:
				return null
			return run(horizontal, null, 1, r, 0, 1.0, Vector2i(0, 1))
		"mix":
			return run(job["src"], job["top"], 2, 0, int(job["mode"]),
				float(job["amount"]))
		"outline":
			return run(job["src"], null, 4, 0, 0, 1.0, Vector2i.ZERO,
				job["extra"] as PackedInt32Array)
		"sharpen":
			return run(job["src"], null, 3, 0, 0, float(job["amount"]))
	return null


static func blur_bridged(image: Image, radius: int) -> Image:
	return bridged({"kind": "blur", "src": image, "radius": radius})


static func mix_bridged(base: Image, top: Image, amount: float, mode_id: int) -> Image:
	return bridged({"kind": "mix", "src": base, "top": top,
		"amount": amount, "mode": mode_id})


static func sharpen_bridged(image: Image, amount: float) -> Image:
	return bridged({"kind": "sharpen", "src": image, "amount": amount})


## 描边：与 FxOpsComposite.outline 的 8 邻域公式一致。
static func outline_bridged(image: Image, thickness: int, inside: bool,
		threshold: float, color: Color) -> Image:
	var extra := PackedInt32Array([
		thickness, 1 if inside else 0, int(round(clampf(threshold, 0.0, 1.0) * 1000.0)),
		int(round(clampf(color.r, 0.0, 1.0) * 1000.0)),
		int(round(clampf(color.g, 0.0, 1.0) * 1000.0)),
		int(round(clampf(color.b, 0.0, 1.0) * 1000.0)),
	])
	return bridged({"kind": "outline", "src": image, "extra": extra})


static func reset() -> void:
	# 停插件时把还在排队的作业全部作废：没人会再来取结果了。
	_bridge_mutex.lock()
	for item in _bridge_queue:
		var slot: Dictionary = (item as Dictionary).get("slot", {})
		slot["result"] = null
		slot["done"] = true
	_bridge_queue.clear()
	_bridge_leader = false
	_bridge_next_id = 0
	_bridge_mutex.unlock()
	if _rd != null:
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()


static func _device() -> RenderingDevice:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	return _rd


static func _ensure_pipeline(device: RenderingDevice) -> bool:
	if _pipeline.is_valid():
		return true
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = COMPUTE_CODE
	var spirv := device.shader_compile_spirv_from_source(source)
	if spirv == null:
		push_warning("FxGpuCompute：SPIR-V 编译返回空")
		return false
	var compile_error := String(spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE))
	if not compile_error.is_empty():
		push_warning("FxGpuCompute：着色器编译失败（%s）" % compile_error)
		return false
	_shader = device.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return false
	_pipeline = device.compute_pipeline_create(_shader)
	return _pipeline.is_valid()


static func _rgba(image: Image) -> Image:
	if image.get_format() == Image.FORMAT_RGBA8 and not image.is_compressed():
		return image
	var copy: Image = image.duplicate()
	if copy.is_compressed():
		copy.decompress()
	copy.convert(Image.FORMAT_RGBA8)
	return copy


static func _uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


static func _free(device: RenderingDevice, rids: Array) -> void:
	for item in rids:
		var rid := item as RID
		if rid.is_valid():
			device.free_rid(rid)
