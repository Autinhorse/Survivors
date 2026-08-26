extends SceneTree
## 到底是谁杀死了玩家？按伤害来源分。
const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const Turret = preload("res://sim/entities/Turret.gd")
const CELLS := [Vector2i(1,0), Vector2i(2,1), Vector2i(1,2), Vector2i(0,1),
	Vector2i(0,0), Vector2i(2,0), Vector2i(2,2), Vector2i(0,2)]

func _initialize() -> void:
	for spec in [["machine_gun", "纯机枪 8 门"], ["rifle", "纯单发 8 门"], ["spread_gun", "纯散弹 8 门"]]:
		_one(String(spec[0]), String(spec[1]))
	quit()

func _one(wid: String, tag: String) -> void:
	var cfg = SimConfig.new()
	cfg.seed_value = 101
	cfg.duration_sec = 1800.0
	cfg.move_policy = "field"
	var ag = ScriptedAgent.new()
	ag.move_policy = "field"
	ag.pick_policy = "dps"
	ag.rng = Rng.new(202)
	var w = SimWorld.new()
	w.setup(cfg, ag)
	w.shop.leave(w)
	w.shop.next_spawn_t = 1.0e9
	w.mech.turrets.clear()
	for i in 8:
		w.mech.turrets.append(Turret.new(wid, CELLS[i], 1, 1))

	# 按波型位置统计打到机甲身上的伤害
	var by_pos := PackedFloat32Array()
	by_pos.resize(9)
	var last_hp: float = w.mech.hp
	while not w.over:
		w.tick()
		if w.mech.hp < last_hp:
			# 找出这一 tick 里贴着机甲、或子弹刚命中的敌人属于哪一位
			var best := 0
			var best_d := INF
			for e in w.combat.hash.query(w.mech.pos, 10.0):
				if not e.alive:
					continue
				var d: float = w.torus.dist(w.mech.pos, e.pos)
				if d < best_d:
					best_d = d
					best = e.wave_pos
			by_pos[clampi(best, 0, 8)] += last_hp - w.mech.hp
			last_hp = w.mech.hp
	var names := ["?", "散兵", "散兵密", "正方向群", "重甲炮台", "冲锋群", "远程弧", "斜角快群", "直线冲撞"]
	var total := 0.0
	for x in by_pos:
		total += x
	var parts: Array = []
	for i in range(1, 9):
		if by_pos[i] > total * 0.03:
			parts.append("%s %.0f%%" % [names[i], 100.0 * by_pos[i] / maxf(1.0, total)])
	print("%-14s 存活 %6.1fs　推到第 %d 波　致死伤害来源：%s"
		% [tag, w.time, w.log.wave_reached, "  ".join(parts)])
