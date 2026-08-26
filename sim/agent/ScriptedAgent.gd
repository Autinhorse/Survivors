extends "res://sim/agent/Agent.gd"
## 自动模拟的策略。参数在 data/agents.json —— **AI 的参数本身也是被测对象**，
## 所以不能写死在这里。
##
## 移动分三层，各自的更新频率不同：
##   第 3 层 · 1 Hz  · 战略方向：直接读 §7.6 的四方向威胁，往最空的那边走
##   第 2 层 · 4 Hz  · 短程试探：四个方向各做 1 秒线性外推，算"会被多少威胁碰到"
##   第 1 层 · 每 tick · 势场微调：贴脸的敌人产生排斥力，防止在密集区里卡住
##
## 转向是**要付 1 秒零输出的离散决策**（§3.3），所以用效用比较而不是"敌人在哪边转哪边"：
## 只有 (转后火力增益 × 威胁持续时间) 大于 (停火 1 秒的损失 × (1+滞回)) 才转。
## 对称 build 下增益恒为 0，AI 自然不转 —— 这正好把"转向到底有没有用"变成可观测的数据。

const Torus = preload("res://sim/core/Torus.gd")

## 世界四方向：0=上 1=右 2=下 3=左，和 MapEval 的 dir_* 索引一致
const DIR_VEC := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]

var move_policy: String = "field"
var pick_policy: String = "dps"
var rng = null

var _p: Dictionary = {}          # 从 data/agents.json 读进来的参数
var _loaded: bool = false
var _probe_dir: int = 0
var _next_probe: float = -1.0
var _line_dir: int = 1
var _last_turn_t: float = -999.0

func _load(world) -> void:
	_loaded = true
	var cfgs: Dictionary = world.db.agents
	_p = cfgs.get(move_policy, cfgs.get("field", {}))
	if move_policy == "line":
		_line_dir = rng.range_i(0, 3) if rng != null else 1

# ---------------------------------------------------------------- 移动

func get_input(world) -> Dictionary:
	if not _loaded:
		_load(world)
	var mode := String(_p.get("move", "field"))
	var move := Vector2.ZERO
	match mode:
		"none":
			move = Vector2.ZERO
		"line":
			move = DIR_VEC[_line_dir]
		_:
			move = DIR_VEC[_field_dir(world)]
	return {"move": move, "turn": _decide_turn(world, move)}

func _field_dir(world) -> int:
	var mech = world.mech
	var torus = world.torus
	var panic: float = float(_p.get("panic_radius", 3.0))

	# 第 1 层：贴脸的敌人直接产生排斥力，压过缓存的试探结果
	var push := Vector2.ZERO
	var close := 0
	for e in world.combat.hash.query(mech.pos, mech.half_size + panic):
		if not e.alive:
			continue
		var rel: Vector2 = torus.delta(mech.pos, e.pos)
		var d: float = rel.length()
		if d > mech.half_size + panic or d < 0.001:
			continue
		push -= rel / d / maxf(0.5, d)
		close += 1
	if close > 0 and push.length() > 0.001:
		return _to_dir(push)

	# 第 2 层：按 probe_hz 重新试探
	if world.time >= _next_probe:
		_next_probe = world.time + 1.0 / maxf(0.5, float(_p.get("probe_hz", 4.0)))
		_probe_dir = _probe(world)
	return _probe_dir

## 四个方向各做一次线性外推，选"未来会被最少威胁碰到"的那个
func _probe(world) -> int:
	var mech = world.mech
	var torus = world.torus
	var T: float = float(_p.get("lookahead_sec", 1.0))
	var predict: bool = bool(_p.get("predict_enemies", true))
	var vision: float = float(_p.get("vision", 14.0))
	var sw: float = float(_p.get("strategic_weight", 0.35))

	var pool: Array = world.enemies if vision > 500.0 else world.combat.hash.query(mech.pos, vision)

	# 第 3 层：把 §7.6 的四方向威胁折进代价里，往最空的那边偏
	var me = world.map_eval
	var max_threat := 0.001
	for i in 4:
		max_threat = maxf(max_threat, me.dir_threat[i])

	var best := 0
	var best_cost := INF
	for i in 4:
		var fut: Vector2 = torus.wrap(mech.pos + DIR_VEC[i] * mech.move_speed * T)
		var cost := 0.0
		for e in pool:
			if not e.alive:
				continue
			var epos: Vector2 = e.pos
			if predict:
				if e.move_kind == "straight":
					epos = torus.wrap(e.pos + e.straight_dir * e.speed * T)
				elif not e.holding:
					epos = torus.wrap(e.pos + torus.dir(e.pos, fut) * e.speed * T)
			var dist: float = torus.dist(fut, epos)
			var reach: float = mech.half_size + e.radius + 0.2
			if e.attack_kind == "ranged":
				reach = maxf(reach, e.attack_range)
			var threat: float = e.attack / maxf(0.01, e.attack_interval)
			if dist <= reach:
				cost += threat
			else:
				var gap: float = dist - reach
				cost += threat / (1.0 + gap * gap)
		cost += sw * (me.dir_threat[i] / max_threat) * 10.0
		if cost < best_cost:
			best_cost = cost
			best = i
	return best

## 合成向量 → 最接近的 4 方向。平局按 上>右>下>左 的固定顺序打破，保证可复现
func _to_dir(v: Vector2) -> int:
	var best := 0
	var best_dot := -INF
	for i in 4:
		var d: float = v.dot(DIR_VEC[i])
		if d > best_dot + 0.000001:
			best_dot = d
			best = i
	return best

# ---------------------------------------------------------------- 转向

func _decide_turn(world, move: Vector2) -> int:
	var mode = _p.get("turn", false)
	if mode is bool and not mode:
		return 0
	var mech = world.mech
	if mech.turning:
		return 0
	if String(mode) == "follow_move":
		if move == Vector2.ZERO:
			return 0
		return _step_toward(mech.facing_dir, _to_dir(move))

	# 效用比较：转 90° 后火力覆盖变好多少，值不值 1 秒停火
	if world.time - _last_turn_t < float(_p.get("turn_min_gap", 2.0)):
		return 0
	var me = world.map_eval
	var T: float = float(_p.get("turn_expect_sec", 3.0))
	var cur := _coverage(me, 0, T)
	var cw := _coverage(me, 1, T)     # 顺时针 90°
	var ccw := _coverage(me, -1, T)
	var gain: float = maxf(cw, ccw) - cur
	if gain <= 0.0:
		return 0
	var cost: float = 0.0 if bool(_p.get("turn_cost_free", false)) \
		else cur * mech.turn_seconds
	if gain * T <= cost * (1.0 + float(_p.get("turn_hysteresis", 0.25))):
		return 0
	_last_turn_t = world.time
	return 1 if cw >= ccw else -1

## 机甲顺时针转 90°，所有槽位的弧也跟着转 90°，
## 所以"转后各方向的己方 DPS"就是把 dir_dps 循环移一位——不用重算几何。
## 超出"T 秒内清空该方向"所需的火力算浪费，不计入收益。
func _coverage(me, steps: int, T: float) -> float:
	var total := 0.0
	for i in 4:
		var dps: float = me.dir_dps[posmod(i - steps, 4)]
		var need: float = me.dir_hp[i] / maxf(0.01, T)
		total += minf(dps, need)
	return total

func _step_toward(cur_dir: int, want: int) -> int:
	var diff := posmod(want - cur_dir, 4)
	if diff == 1:
		return 1
	if diff == 3:
		return -1
	if diff == 2:
		return 1
	return 0

# ---------------------------------------------------------------- 选卡（P6 会换成商店）

func choose_upgrade(_world, options: Array) -> int:
	if options.is_empty():
		return -1
	match pick_policy:
		"random":
			return rng.range_i(0, options.size() - 1) if rng != null else 0
		"armor":
			for i in options.size():
				if String(options[i].get("type", "")) == "hull":
					return i
			return 0
		_:
			for i in options.size():
				if String(options[i].get("type", "")) == "new_turret":
					return i
			for i in options.size():
				if String(options[i].get("type", "")) == "turret_level":
					return i
			return 0
