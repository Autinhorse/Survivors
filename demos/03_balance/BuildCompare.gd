extends SceneTree
## 同样的 DPS，摊在几门炮塔上有多大差别？
## 每门只覆盖 180°（§6.4），所以"总 DPS"和"活多久"未必是一回事。
const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const Turret = preload("res://sim/entities/Turret.gd")

const CELLS := [Vector2i(1,0), Vector2i(2,1), Vector2i(1,2), Vector2i(0,1),
	Vector2i(0,0), Vector2i(2,0), Vector2i(2,2), Vector2i(0,2)]

func _initialize() -> void:
	print("%-34s %-8s %-9s %s" % ["build", "门数", "总DPS", "平均存活（5 局）"])
	_run("2 门 rifle@1（现在开局能造出来的）", [["rifle",1],["rifle",1]])
	_run("4 门 rifle@1", [["rifle",1],["rifle",1],["rifle",1],["rifle",1]])
	_run("8 门 gun@3（DPS 相近但满覆盖）", [["gun",3],["gun",3],["gun",3],["gun",3],
		["gun",3],["gun",3],["gun",3],["gun",3]])
	_run("8 门 rifle@1（索敌4 血量最高）", [["rifle",1],["rifle",1],["rifle",1],["rifle",1],
		["rifle",1],["rifle",1],["rifle",1],["rifle",1]])
	_run("8 门 机枪@1（索敌3 血量最低）", [["machine_gun",1],["machine_gun",1],["machine_gun",1],
		["machine_gun",1],["machine_gun",1],["machine_gun",1],["machine_gun",1],["machine_gun",1]])
	_run("8 门 Spread Gun@1（索敌1 最近+范围）", [["spread_gun",1],["spread_gun",1],
		["spread_gun",1],["spread_gun",1],["spread_gun",1],["spread_gun",1],
		["spread_gun",1],["spread_gun",1]])
	_run("8 门 rifle@1 但索敌改成 1", [["rifle",1],["rifle",1],["rifle",1],["rifle",1],
		["rifle",1],["rifle",1],["rifle",1],["rifle",1]], 1)
	quit()

func _run(name: String, spec: Array, force_targeting: int = 0) -> void:
	var total := 0.0
	var dps := 0.0
	for s in range(5):
		var cfg = SimConfig.new()
		cfg.seed_value = 100 + s
		cfg.duration_sec = 1800.0
		cfg.move_policy = "field"
		var ag = ScriptedAgent.new()
		ag.move_policy = "field"
		ag.pick_policy = "dps"
		ag.rng = Rng.new(200 + s)
		var w = SimWorld.new()
		w.setup(cfg, ag)
		if force_targeting > 0:
			for wid2 in w.db.weapons.keys():
				w.db.weapons[wid2]["targeting"] = force_targeting
		w.shop.leave(w)
		w.shop.next_spawn_t = 1.0e9          # 关掉商店，只比 build
		w.mech.turrets.clear()
		dps = 0.0
		for i in spec.size():
			var wid: String = spec[i][0]
			var lv: int = spec[i][1]
			w.mech.turrets.append(Turret.new(wid, CELLS[i], lv, 1))
			dps += w.db.weapon_damage(wid, lv) / w.db.weapon_interval(wid, lv)
		total += w.run_to_end().run_duration
	print("%-34s %-8d %-9.0f %.1fs" % [name, spec.size(), dps, total / 5.0])
