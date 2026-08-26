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

var _next_wave: int = 1             # 下一个还没开始的波（从 1 数）
var _active: Array = []             # 正在逐个吐怪的波（random 型）

func setup(db, rng, torus) -> void:
	_db = db
	_rng = rng
	_torus = torus
	var w: Dictionary = db.waves_cfg
	cycle_waves = int(w.get("cycle_waves", 8))
	wave_gap = float(w.get("wave_gap_sec", 10.0))
	spawn_margin = float(w.get("spawn_margin", 4.0))
	var vw: float = db.cfg("map/view_width", 48.0)
	var vh: float = db.cfg("map/view_height", 27.0)
	spawn_radius = sqrt(vw * vw + vh * vh) * 0.5 + spawn_margin
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
	var deg: float = _rng.range_f(0.0, 360.0)
	return _torus.wrap(mech_pos + Torus.angle_to_vec(deg) * spawn_radius)

func _point_batch(st: Dictionary, base_deg: float, i: int, total: int, mech_pos: Vector2) -> Vector2:
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
