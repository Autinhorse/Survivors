extends SceneTree
## 一局的商店/金币事件流水。P6 的经济闭环到底卡在哪一环，靠这个看。
const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")

func _initialize() -> void:
	var cfg = SimConfig.new()
	cfg.seed_value = 11
	cfg.duration_sec = 600.0
	cfg.move_policy = "field"
	var ag = ScriptedAgent.new()
	ag.move_policy = "field"
	ag.pick_policy = "spread"
	ag.rng = Rng.new(7)
	var w = SimWorld.new()
	w.setup(cfg, ag)
	print("开局商店结束：金币 %d，炮塔 %d，保险箱 %d，下次商店 %.1fs"
		% [int(w.mech.coins), w.mech.turrets.size(), w.shop.safe_box.size(), w.shop.next_spawn_t])

	var last_site := false
	var in_shop := true
	var closest := 1.0e9
	var last_visits := 1
	var t_next := 0.0
	while not w.over:
		w.tick()
		var has_site: bool = w.shop.site != null
		if has_site != last_site:
			if has_site:
				closest = 1.0e9
				print("%6.1fs  商店出现，距离 %.1f 格，金币 %d"
					% [w.time, w.torus.dist(w.mech.pos, w.shop.site.pos), int(w.mech.coins)])
			else:
				print("        （商店消失/进入，此前最近接近到 %.1f 格）" % closest)
			last_site = has_site
		if w.shop.visits != last_visits:
			print("%6.1fs  进店第 %d 次，进店时金币 %d" % [w.time, w.shop.visits, int(w.mech.coins)])
			last_visits = w.shop.visits
		if w.shop.open != in_shop:
			in_shop = w.shop.open
			if not in_shop:
				var ids: Array = []
				for t in w.mech.turrets:
					ids.append("%s@%d" % [t.weapon_id, t.level])
				ids.sort()
				print("        出店：金币 %d  保险箱 %d  炮塔 %s"
					% [int(w.mech.coins), w.shop.safe_box.size(),
						"（空）" if ids.is_empty() else " ".join(ids)])
		if has_site:
			closest = minf(closest, w.torus.dist(w.mech.pos, w.shop.site.pos))
		if w.time >= t_next:
			t_next += 30.0
			print("%6.1fs  金币 %-6d 炮塔 %d  敌人 %-4d HP %-5d 商店%s  最近距离 %s"
				% [w.time, int(w.mech.coins), w.mech.turrets.size(), w.enemies.size(),
					int(w.mech.hp), "在场" if has_site else "未出现",
					"-" if closest > 9000.0 else "%.1f 格" % closest])
	print("结束 %.1fs  %s  商店 %d 次  合并 %d 次  金币总产出 %d  最终 %s"
		% [w.time, w.log.result, w.shop.visits, w.log.merge_count, int(w.log.coins_earned), w.log.final_build])
	quit()
