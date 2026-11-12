class_name FxDynamics
extends RefCounted
## 闭式动力学 —— 把 pixelfx 的「有状态物理粒子」改写成可任意求值的解析式。
##
## pixelfx 的 `sim.js` 用 dt 逐帧积分（重力、阻力、落地反弹、二次发射），代价是
## 只能从头顺序播放。本引擎要求「任意 t 直接求值」（可 scrub、可循环、可烘焙序列帧），
## 两者天然冲突。这里的解法不是折中，而是换一种建模方式：
##
## 1) 解析弹道：带地面反弹的抛体，第 k 次弹跳的时刻与位置有闭式解。
##    每次反弹速度按 e^k 几何衰减，各段滞空时间求和是几何级数，
##    于是可以反向解出「当前处于第几段」，O(1) 得到任意 t 的 (x, y, vx, vy)。
##    不需要保留任何历史状态 —— 跳跃播放、倒放、逐帧烘焙都成立。
##
## 2) 事件树：pixelfx 的 fire→smoke、brand→fire 是运行时二次发射。
##    这里在 compile() 阶段把发射树**展开成静态原子表**：每个原子都有确定的
##    birth / life，子粒子在父粒子死亡时刻、父粒子那一刻的位置出生。
##    视觉等价，但求值仍是纯函数，且同 seed 必得同一棵树。
##
## 3) 随机量全部来自 FxMath.h01(seed, i)：逐帧调用不会抖动，也不消耗全局 RNG。

const MAX_ATOMS: int = 720
const MAX_DEPTH: int = 2

## 把一层配方编译成原子表。ground_local 为地面在**局部坐标**的 y（0 = 不落地）。
## 可用字段：count / speed[lo,hi] / angle[lo,hi] / life / delay / size[lo,hi] /
## gravity / drag / bounce / kind / tint[lo,hi] / glow / child{...同一套字段}
static func compile(layer: Dictionary, seed: int, ground_local: float = 0.0) -> Array:
	var atoms: Array = []
	var count: int = clampi(int(layer.get("count", 24)), 1, 320)
	for i in range(count):
		if atoms.size() >= MAX_ATOMS:
			break
		_spawn(layer, seed, i, 0.0, 0.0, 0.0, ground_local, atoms, 0)
	return atoms

static func _spawn(node: Dictionary, seed: int, idx: int, birth: float,
		x0: float, y0: float, ground_y: float, out: Array, depth: int) -> void:
	var s: int = seed * 7919 + idx * 131 + depth * 977
	var ang: float = deg_to_rad(FxMath.rand_range(s, 1, _lo(node, "angle", 0.0), _hi(node, "angle", 0.0)))
	var spd: float = FxMath.rand_range(s, 2, _lo(node, "speed", 90.0), _hi(node, "speed", 90.0))
	var life: float = maxf(0.02, FxMath.rand_range(s, 3, _lo(node, "life", 0.6), _hi(node, "life", 0.6)))
	var gap: float = FxMath.rand_range(s, 4, _lo(node, "delay", 0.0), _hi(node, "delay", 0.0))
	var atom: Dictionary = {
		"birth": birth + gap,
		"life": life,
		"x0": x0, "y0": y0,
		"vx": cos(ang) * spd, "vy": sin(ang) * spd,
		"gravity": float(node.get("gravity", 0.0)),
		"drag": maxf(float(node.get("drag", 0.0)), 0.0),
		"ground": ground_y,
		"bounce": clampf(float(node.get("bounce", 0.0)), 0.0, 0.92),
		"size": FxMath.rand_range(s, 6, _lo(node, "size", 1.0), _hi(node, "size", 1.0)),
		"kind": String(node.get("kind", "spark")),
		"tint0": _lo(node, "tint", 0.65), "tint1": _hi(node, "tint", 1.0),
		"glow": float(node.get("glow", 0.45)),
		"spin": FxMath.rand_range(s, 8, -7.0, 7.0),
		"jitter": float(s % 360),
	}
	out.append(atom)
	if depth >= MAX_DEPTH:
		return
	var kids: Variant = node.get("child", null)
	if not kids is Dictionary:
		return
	var kcount: int = clampi(int((kids as Dictionary).get("count", 1)), 0, 8)
	if kcount <= 0:
		return
	# 子粒子在父粒子「存活到 at 比例」那一刻的位置出生 —— 闭式事件树的核心。
	var at: float = clampf(float((kids as Dictionary).get("at", 1.0)), 0.0, 1.0)
	var cb: float = float(atom["birth"]) + life * at
	var origin: Dictionary = state(atom, cb)
	if not bool(origin["alive"]):
		return
	for c in range(kcount):
		if out.size() >= MAX_ATOMS:
			return
		_spawn(kids, seed + 31, idx * 53 + c, cb, float(origin["x"]), float(origin["y"]),
			ground_y, out, depth + 1)

## 原子在 t 时刻的状态。alive 为假时其余字段无意义。
## k 为剩余寿命比例（1 = 刚出生，0 = 即将消失），供着色与透明度使用。
static func state(atom: Dictionary, t: float) -> Dictionary:
	return state_age(atom, t - float(atom["birth"]))

## 按「年龄」直接求值，供循环特效按周期重播同一个原子（一个原子可同时存在多个副本）。
static func state_age(atom: Dictionary, u: float) -> Dictionary:
	var life: float = float(atom["life"])
	var dead: Dictionary = {"alive": false, "x": 0.0, "y": 0.0, "vx": 0.0, "vy": 0.0, "k": 0.0, "bounces": 0.0}
	if u < 0.0 or u >= life:
		return dead
	var vx0: float = float(atom["vx"])
	var vy0: float = float(atom["vy"])
	var g: float = float(atom["gravity"])
	var drag: float = float(atom["drag"])
	var x: float = float(atom["x0"])
	var vx_now: float = vx0
	if drag > 0.001:
		var decay: float = exp(-drag * u)
		x += vx0 * (1.0 - decay) / drag
		vx_now = vx0 * decay
	else:
		x += vx0 * u
	var y: float = float(atom["y0"]) + vy0 * u + 0.5 * g * u * u
	var vy_now: float = vy0 + g * u
	var bounces: float = 0.0
	var ground_y: float = float(atom["ground"])
	var e: float = float(atom["bounce"])
	if ground_y > 0.0 and e > 0.01 and g > 0.001:
		var hit: Dictionary = _bounce(float(atom["y0"]), vy0, g, ground_y, e, u)
		y = float(hit["y"])
		vy_now = float(hit["vy"])
		bounces = float(hit["n"])
	return {"alive": true, "x": x, "y": y, "vx": vx_now, "vy": vy_now,
		"k": 1.0 - u / life, "bounces": bounces}

## 带反弹的落地解析解。
## 首次落地 τ1 由二次方程解出；之后每次上抛速度 v1·e^k，滞空 2·v1·e^k/g。
## 全部后续滞空之和收敛到 t_inf，超过即静止在地面。
static func _bounce(y0: float, vy0: float, g: float, ground_y: float, e: float, u: float) -> Dictionary:
	var disc: float = vy0 * vy0 - 2.0 * g * (y0 - ground_y)
	if disc < 0.0:
		return {"y": y0 + vy0 * u + 0.5 * g * u * u, "vy": vy0 + g * u, "n": 0.0}
	var t1: float = (-vy0 + sqrt(disc)) / g
	if t1 <= 0.0:
		return {"y": y0 + vy0 * u + 0.5 * g * u * u, "vy": vy0 + g * u, "n": 0.0}
	if u <= t1:
		return {"y": y0 + vy0 * u + 0.5 * g * u * u, "vy": vy0 + g * u, "n": 0.0}
	var v1: float = vy0 + g * t1                 # 落地速度（向下为正）
	if v1 <= 0.0:
		return {"y": ground_y, "vy": 0.0, "n": 0.0}
	var span: float = 2.0 * v1 / g               # 后续每段的基准滞空时长
	var geo: float = e / (1.0 - e)               # 几何级数和系数
	var t_inf: float = t1 + span * geo
	if u >= t_inf:
		return {"y": ground_y, "vy": 0.0, "n": 92.0}   # 92 = 已静止
	# 反向解出当前处于第 k 段：e^k = 1 - (u - t1) / (span · geo)
	var ek: float = clampf(1.0 - (u - t1) / (span * geo), 1e-9, 1.0)
	var k: float = floorf(log(ek) / log(e))
	var t_k: float = t1 + span * geo * (1.0 - pow(e, k))
	var du: float = u - t_k
	var vk: float = v1 * pow(e, k)
	return {"y": ground_y - vk * du + 0.5 * g * du * du, "vy": -vk + g * du, "n": k + 1.0}

static func _lo(node: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = node.get(key, null)
	if value is Array:
		var arr: Array = value
		return float(arr[0]) if arr.size() > 0 else fallback
	return fallback if value == null else float(value)

static func _hi(node: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = node.get(key, null)
	if value is Array:
		var arr: Array = value
		return float(arr[arr.size() - 1]) if arr.size() > 0 else fallback
	return fallback if value == null else float(value)
