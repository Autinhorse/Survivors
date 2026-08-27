extends RefCounted
## 按 data/waves.json 的"形状 × 成长"模型生成敌人（§4.1 / §4.5）。
##
##   第 c 周期第 k 位的数值 = base × growth^(c-1) × shape[k]
##
## shape 是波型性格（重甲环少而硬、斜角快群多而脆…），跨周期不累积；
## growth 是唯一的成长旋钮，四项全部 >= 1，保证任何一项都不会跨周期下降。

const Enemy = preload("res://sim/entities/Enemy.gd")
const Torus = preload("res://sim/core/Torus.gd")

var _db = null
var _rng = null
var _torus = null

var cycle_waves: int = 8
var wave_gap: float = 10.0
var spawn_margin: float = 4.0
var spawn_radius: float = 31.5      # 视野外接圆 + margin

## 开场阶段：关卡内第一次走进商店之前。
## 这段时间敌人少一些（玩家手上只有 1-3 门枪），而且**从四面均匀来**——
## 让玩家自己看出"四个方向都得有炮塔"，比任何文字提示都管用。
## 由 SimWorld 每帧写入（shop.visits < 2，开局那次商店算第 1 次）。
var opening: bool = false
var opening_count_mult: float = 0.5
var opening_uniform: bool = true

var _next_wave: int = 1             # 下一个还没开始的波（从 1 数）
var _active: Array = []             # 正在逐个吐怪的波（random 型）
var _uniform_n: int = 0             # 开场四面轮流放的计数

func setup(db, rng, torus) -> void:
	_db = db
	_rng = rng
	_torus = torus
	var w: Dictionary = db.waves_cfg
	cycle_waves = int(w.get("cycle_waves", 8))
	wave_gap = float(w.get("wave_gap_sec", 10.0))
	spawn_margin = float(w.get("spawn_margin", 4.0))
	var op: Dictionary = w.get("opening", {})
	opening_count_mult = float(op.get("count_mult", 0.5))
	opening_uniform = bool(op.get("uniform_four_sides", true))
	var vw: float = db.cfg("map/view_width", 48.0)
	var vh: float = db.cfg("map/view_height", 27.0)
	# 原来是视野外接圆（√(48²+27²)/2 + 4 = 31.5 格）：敌人生成在屏幕四角
	# 之外，横向要走 8-21 秒才进画面，开局半天见不到人。改成按**长边半屏**
	# （24 + margin）：横向来的敌人一生成就在画面边缘，纵向来的仍在屏外。
	spawn_radius = maxf(vw, vh) * 0.5 + spawn_margin
	_next_wave = 1
	_active.clear()

## 已经开始的最后一波（从 1 数）
func current_wave() -> int:
	return maxi(0, _next_wave - 1)

## 第 n 波（从 1 数）的定义与实际数值
func wave_stats(n: int) -> Dictionary:
	var w: Dictionary = _db.waves_cfg
	var defs: Array = w.get("waves", [])
	var k := (n - 1) % cycle_waves
	var c := (n - 1) / cycle_waves          # 整数除法：第几个周期（从 0 数）
	var d: Dictionary = defs[k]
	var base: Dictionary = w.get("base", {})
	var growth: Dictionary = w.get("growth", {})
	var shape: Dictionary = d.get("shape", {})
	# 每波可以带自己的 base/growth，成为一条**独立威胁轨道**：
	# 不共享全局基准、也不参与其他波次的总量平衡（重甲环就是这么用的）。
	# 某个字段一旦自带 base，shape 对它就不再生效——base 本身就是该字段的值。
	var wbase: Dictionary = d.get("base", {})
	var wgrowth: Dictionary = d.get("growth", {})
	var out := d.duplicate(true)
	for f in ["hp", "count", "attack", "coin"]:
		var bv: float = float(wbase.get(f, base.get(f, 1.0)))
		var gv: float = float(wgrowth.get(f, growth.get(f, 1.0)))
		var sv: float = 1.0 if wbase.has(f) else float(shape.get(f, 1.0))
		out[f] = bv * pow(gv, c) * sv
	# 射程也随周期长（重甲炮台 9 → 11）。单独一条规则，不进上面那个循环——
	# 上面四个字段是"总量"，可以无上限地涨；射程涨到超出玩家视野就没意义了，
	# 必须封顶。谁需要谁在自己那一波写 attack_range_growth / attack_range_max。
	var rg: float = float(d.get("attack_range_growth", 1.0))
	if rg != 1.0:
		var r0: float = float(d.get("attack_range", 0.0))
		var rmax: float = float(d.get("attack_range_max", r0))
		out["attack_range"] = minf(rmax, r0 * pow(rg, c))

	out["wave_index"] = n
	out["cycle"] = c + 1
	out["start_t"] = wave_gap * float(n - 1)
	return out

func tick(now: float, _dt: float, out_enemies: Array, mech_pos: Vector2) -> void:
	# 开新波
	while wave_gap * float(_next_wave - 1) <= now:
		_begin(_next_wave, now, out_enemies, mech_pos)
		_next_wave += 1
	# 逐个吐怪的波
	var still: Array = []
	for a in _active:
		while int(a["spawned"]) < int(a["total"]) and float(a["next_t"]) <= now:
			out_enemies.append(_make(a["stats"], _point_random(mech_pos), mech_pos))
			a["spawned"] = int(a["spawned"]) + 1
			a["next_t"] = float(a["next_t"]) + float(a["interval"])
		if int(a["spawned"]) < int(a["total"]):
			still.append(a)
	_active = still

func _begin(n: int, now: float, out_enemies: Array, mech_pos: Vector2) -> void:
	var st := wave_stats(n)
	var total := int(round(maxf(1.0, float(st["count"]))))
	if opening:
		total = maxi(1, int(round(float(total) * opening_count_mult)))
	var interval := float(st.get("interval", 0.0))
	if interval > 0.0:
		_active.append({"stats": st, "total": total, "spawned": 0,
			"interval": interval, "next_t": now})
		return
	# 瞬发：Group / Circle 一次全出
	var pattern := String(st.get("pattern", "random"))
	var base_deg := 0.0
	if pattern == "group":
		var dirs: Array = st.get("dirs_deg", [0, 90, 180, 270])
		base_deg = float(dirs[_rng.range_i(0, dirs.size() - 1)])
	else:
		var a0 = st.get("angle_start", 0)
		base_deg = _rng.range_f(0.0, 360.0) if typeof(a0) == TYPE_STRING else float(a0)
	for i in total:
		out_enemies.append(_make(st, _point_batch(st, base_deg, i, total, mech_pos), mech_pos))

func _point_random(mech_pos: Vector2) -> Vector2:
	if opening and opening_uniform:
		_uniform_n += 1
		var d0: float = float(_uniform_n % 4) * 90.0 + _rng.range_f(-12.0, 12.0)
		return _torus.wrap(mech_pos + Torus.angle_to_vec(d0) * spawn_radius)
	var deg: float = _rng.range_f(0.0, 360.0)
	return _torus.wrap(mech_pos + Torus.angle_to_vec(deg) * spawn_radius)

func _point_batch(st: Dictionary, base_deg: float, i: int, total: int, mech_pos: Vector2) -> Vector2:
	# 开场阶段压掉原本的波型，一律按四面轮流放。玩家会看到东南西北同时来人，
	# 于是自然想到四面都要架炮——这是教学，不是配平。
	if opening and opening_uniform:
		var deg0: float = float(i % 4) * 90.0 + _rng.range_f(-12.0, 12.0)
		var ring: float = float(i / 4) * 1.5
		return _torus.wrap(mech_pos
			+ Torus.angle_to_vec(deg0) * (spawn_radius + ring))
	var pattern := String(st.get("pattern", "random"))
	var r := spawn_radius
	match pattern:
		"group":
			var arc := float(st.get("arc_deg", 40.0))
			var deg: float = base_deg + _rng.range_f(-arc * 0.5, arc * 0.5)
			return _torus.wrap(mech_pos + Torus.angle_to_vec(deg) * (r + _rng.range_f(0.0, 4.0)))
		"circle":
			# angle_end=angle_start（或都是 0）表示整圈；否则是 arc_deg 的弧
			var span := 360.0
			if st.has("arc_deg"):
				span = float(st["arc_deg"])
			elif st.has("angle_end"):
				var e := float(st["angle_end"]) - float(st.get("angle_start", 0))
				span = e if absf(e) > 0.01 else 360.0
			# 一圈放不下就多层（§4.1）
			var per_ring := maxi(1, int(TAU * r * (span / 360.0)))
			var ring := i / per_ring
			var idx := i % per_ring
			var deg := base_deg + span * (float(idx) / float(per_ring))
			return _torus.wrap(mech_pos + Torus.angle_to_vec(deg) * (r + float(ring) * 1.2))
		"line":
			var width := maxi(1, int(st.get("width", 10)))
			var row := i / width
			var col := float(i % width) - float(width - 1) * 0.5
			var fwd := Torus.angle_to_vec(base_deg)
			var side := Vector2(-fwd.y, fwd.x)
			return _torus.wrap(mech_pos + fwd * (r + float(row) * 1.2) + side * col)
	return _point_random(mech_pos)

func _make(st: Dictionary, p: Vector2, mech_pos: Vector2):
	var e = Enemy.new()
	e.wave_index = int(st.get("wave_index", 0))
	e.wave_pos = int(st.get("pos", 0))
	e.type_name = String(st.get("name", ""))
	e.pos = p
	e.max_hp = float(st.get("hp", 100.0))
	e.hp = e.max_hp
	e.speed = float(st.get("speed", 1.0))
	e.attack = float(st.get("attack", 10.0))
	e.attack_interval = float(st.get("attack_interval", 2.0))
	e.coin = float(st.get("coin", 50.0))
	e.move_kind = String(st.get("move", "chase"))
	e.attack_kind = String(st.get("attack_kind", "melee"))
	e.attack_range = float(st.get("attack_range", 0.0))
	e.bullet_speed = float(st.get("bullet_speed", 0.0))
	e.hold_position = bool(st.get("hold_position", false))
	e.keep_distance = bool(st.get("keep_distance", false))
	# 血量越高体型越大，方便肉眼分辨（纯表现，不参与规则判定以外的计算）
	e.radius = clampf(0.3 * pow(e.max_hp / 100.0, 0.25), 0.25, 1.6)
	if e.move_kind == "straight":
		e.straight_dir = _torus.dir(p, mech_pos)
	return e
