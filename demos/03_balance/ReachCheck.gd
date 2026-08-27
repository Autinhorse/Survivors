extends SceneTree
## 玩家实测那局（298s / 第 30 波 / 13550 金币没花完）暴露的问题：
## 有效 DPS 是刷怪压力的 9 倍，却被 163 个敌人堆死了。
## 那死因就不是"打不动"，而是"够不着"——这个工具把两件事量出来：
##   1. 每一位敌人：刷了多少、死了多少、打了机甲多少伤害
##   2. 活着的敌人里有多大比例待在所有炮塔射程之外
const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const Turret = preload("res://sim/entities/Turret.gd")

const CELLS := [Vector2i(1,0), Vector2i(2,1), Vector2i(1,2), Vector2i(0,1),
	Vector2i(0,0), Vector2i(2,0), Vector2i(2,2), Vector2i(0,2)]
const NAMES := ["?", "散兵", "散兵密", "正方向群", "重甲炮台", "冲锋群", "远程弧", "斜角快群", "直线冲撞"]

## 玩家那局死时的 build（截图 HUD 原样）
const PLAYER := [["machine_gun",3], ["machine_gun",1], ["rifle",3], ["shotgun",1],
	["rifle",2], ["heavy_machine_gun",1], ["rifle",1], ["gun",3]]

func _initialize() -> void:
	_one("玩家实测 build", PLAYER)
	_one("纯机枪 8 门@3", [["machine_gun",3],["machine_gun",3],["machine_gun",3],["machine_gun",3],
		["machine_gun",3],["machine_gun",3],["machine_gun",3],["machine_gun",3]])
	_one("纯单发 8 门@3", [["rifle",3],["rifle",3],["rifle",3],["rifle",3],
		["rifle",3],["rifle",3],["rifle",3],["rifle",3]])
	quit()

func _one(tag: String, spec: Array) -> void:
	var cfg = SimConfig.new()
	cfg.seed_value = 101
	cfg.duration_sec = 600.0
	cfg.move_policy = "field"
	var ag = ScriptedAgent.new()
	ag.move_policy = "field"
	ag.pick_policy = "dps"
	ag.rng = Rng.new(202)
	var w = SimWorld.new()
	w.setup(cfg, ag)
	w.shop.leave(w)
	w.shop.next_spawn_t = 1.0e9        # 关经济，只看够不够得着
	w.mech.turrets.clear()
	var reach := 0.0
	for i in spec.size():
		var t = Turret.new(String(spec[i][0]), CELLS[i], 1, 1)
		t.level = int(spec[i][1])
		w.mech.turrets.append(t)
		reach = maxf(reach, float(w.db.weapons[t.weapon_id].get("range", 0.0)))

	var spawned := PackedInt32Array(); spawned.resize(9)
	var dmg := PackedFloat32Array(); dmg.resize(9)
	var seen: Dictionary = {}          # 敌人实例 → wave_pos，用来数"刷了多少"
	var standoff := 0.0        # 重甲炮台平均离机甲多远
	var standoff_n := 0.0
	var last_hp: float = w.mech.hp

	while not w.over:
		w.tick()
		for e in w.enemies:
			if not seen.has(e):
				seen[e] = e.wave_pos
				spawned[clampi(e.wave_pos, 0, 8)] += 1
		if w.mech.hp < last_hp:
			var best := 0
			var best_d := INF
			for e in w.combat.hash.query(w.mech.pos, 12.0):
				if not e.alive:
					continue
				var d: float = w.torus.dist(w.mech.pos, e.pos)
				if d < best_d:
					best_d = d
					best = e.wave_pos
			dmg[clampi(best, 0, 8)] += last_hp - w.mech.hp
			last_hp = w.mech.hp
		# 每秒采一次重甲炮台（第 4 位，keep_distance）实际停在多远——
		# 它要是稳定停在射程外，这条枪线就是永远打不到它，不是"打得慢"
		if absf(fposmod(w.time, 1.0)) < w.dt:
			for e in w.enemies:
				if e.alive and e.wave_pos == 4:
					standoff += w.torus.dist(w.mech.pos, e.pos)
					standoff_n += 1.0

	var tot := 0.0
	for x in dmg:
		tot += x
	print("── %s　存活 %.1fs　推到第 %d 波　最远射程 %.0f 格" % [tag, w.time, w.log.wave_reached, reach])
	print("   %-10s %-8s %-8s %-8s %s" % ["敌人", "刷出", "杀掉", "漏掉", "对机甲伤害"])
	for i in range(1, 9):
		if spawned[i] == 0:
			continue
		var k: int = int(w.log.kills_by_wave_pos[i - 1])
		print("   %-10s %-8d %-8d %-8s %s" % [NAMES[i], spawned[i], k,
			"%.0f%%" % (100.0 * float(maxi(0, spawned[i] - k)) / float(spawned[i])),
			"%.0f%%" % (100.0 * dmg[i] / maxf(1.0, tot))])
	if standoff_n > 0.0:
		var d: float = standoff / standoff_n
		print("   重甲炮台平均停在 %.1f 格外，最远射程 %.0f 格 → %s\n"
			% [d, reach, "够得着" if d <= reach + w.mech.half_size else "**永远够不着**"])
	else:
		print("")
