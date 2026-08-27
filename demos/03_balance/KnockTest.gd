extends SceneTree
## 击退到底有没有"把能伤害我的推开"的效果？
##
## 设计意图是防御：贴到车体上的那一圈被推走，争取喘息。
## 但霰弹枪推 0.75 格、每 2 秒一发，而敌人速度 1.5-3.75 格/秒——
## 推开的距离 0.2-0.5 秒就走回来了。这里量它实际值多少。
##
## 判据不是伤害也不是存活，而是**贴身敌人数**：击退如果有用，
## 带散弹的 build 车体周围的敌人应该明显更少。
## 机甲设成打不死、跑满固定时长，避免局长变成变量。

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const Turret = preload("res://sim/entities/Turret.gd")

const CELLS := [Vector2i(1, 0), Vector2i(2, 1), Vector2i(1, 2), Vector2i(0, 1),
	Vector2i(0, 0), Vector2i(2, 0), Vector2i(2, 2), Vector2i(0, 2)]

var runs: int = 6
var dur: float = 300.0

func _initialize() -> void:
	for s in OS.get_cmdline_user_args():
		var kv := String(s).split("=", true, 1)
		if kv.size() == 2 and kv[0] == "runs":
			runs = int(kv[1])
		elif kv.size() == 2 and kv[0] == "dur":
			dur = float(kv[1])
	print("机甲打不死、**站桩不动**，跑满 %.0f 秒 × %d 局" % [dur, runs])
	print("%-20s %-14s %-14s %-14s"
		% ["build", "贴身敌人(均)", "1格内敌人(均)", "杂兵伤害(管)"])
	_one("机枪 8", [["machine_gun", 8]])
	_one("机枪 6 + 散弹 2", [["machine_gun", 6], ["shotgun", 2]])
	_one("机枪 4 + 散弹 4", [["machine_gun", 4], ["shotgun", 4]])
	_one("散弹 8", [["shotgun", 8]])
	quit()

func _one(tag: String, spec: Array) -> void:
	var touch := 0.0
	var near := 0.0
	var dmg := 0.0
	var lo := INF
	var hi := 0.0
	for s in runs:
		var cfg = SimConfig.new()
		cfg.seed_value = 1100 + s
		cfg.duration_sec = dur
		# 站桩。field 走位把敌人甩得太干净，贴身敌人数四套 build 全是 0.0，
		# 击退根本没有对象可推——那是测试设定的问题，不是击退没用。
		# 被围住才是击退该发挥作用的场景，也是玩家手玩时的真实处境。
		cfg.move_policy = "stand"
		var ag = ScriptedAgent.new()
		ag.move_policy = "stand"
		ag.pick_policy = "dps"
		ag.rng = Rng.new(1150 + s)
		var w = SimWorld.new()
		w.setup(cfg, ag)
		w.shop.leave(w)
		w.shop.next_spawn_t = 1.0e9
		w.mech.max_hp = 1.0e12
		w.mech.hp = 1.0e12
		w.mech.turrets.clear()
		var slot := 0
		for item in spec:
			for i in int(item[1]):
				w.mech.turrets.append(Turret.new(String(item[0]), CELLS[slot], 1, 1))
				slot += 1

		var t_sum := 0.0
		var n_sum := 0.0
		var samples := 0.0
		while not w.over:
			w.tick()
			# 每秒采一次：车体上贴着几个、车体外 1 格内又有几个
			if absf(fposmod(w.time, 1.0)) >= w.dt:
				continue
			var nt := 0
			var nn := 0
			for e in w.combat.hash.query(w.mech.pos, w.mech.half_size + 2.5):
				if not e.alive:
					continue
				var rel: Vector2 = w.torus.delta(w.mech.pos, e.pos)
				if w.mech.overlaps(rel, e.radius):
					nt += 1
				elif w.mech.overlaps(rel, e.radius + 1.0):
					nn += 1
			t_sum += float(nt)
			n_sum += float(nn)
			samples += 1.0
		touch += t_sum / maxf(1.0, samples)
		near += n_sum / maxf(1.0, samples)
		var d: float = 0.0
		for i in 8:
			if i + 1 != 4:                     # 第 4 位是重甲炮台，不算杂兵
				d += float(w.log.damage_by_wave_pos[i])
		d /= maxf(1.0, float(w.db.cfg("mech/max_hp", 1000.0)))
		dmg += d
		lo = minf(lo, d)
		hi = maxf(hi, d)
	var n := float(runs)
	var avg: float = dmg / n
	print("%-20s %-14s %-14s %-14s" % [tag,
		"%.1f" % (touch / n),
		"%.1f" % (near / n),
		"%.1f (±%.0f%%)" % [avg, 100.0 * maxf(hi - avg, avg - lo) / maxf(0.01, avg)]])
