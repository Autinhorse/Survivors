extends SceneTree
## P2 验收：把实现里真实生成的敌人，和 tools/sim/wave_shape.py 的推演表对拍。
##   godot --headless --script res://demos/03_balance/WaveCheck.gd -- cycles=3

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const Agent = preload("res://sim/agent/Agent.gd")

func _initialize() -> void:
	var args := {}
	for s in OS.get_cmdline_user_args():
		var kv := String(s).split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var cycles := int(args.get("cycles", "3"))

	var cfg = SimConfig.new()
	cfg.seed_value = 7
	cfg.duration_sec = 10.0 * float(cycles * 8)
	var w = SimWorld.new()
	w.setup(cfg, Agent.new())          # 空 agent：不动、不选卡，只看刷怪
	# 对拍的是"生成了什么"，所以把战斗关掉：不开火、打不死，敌人数组只增不减
	w.mech.turrets.clear()
	w.mech.max_hp = 1.0e18
	w.mech.hp = w.mech.max_hp
	for e in w.db.errors:
		print("[data] ", e)

	# 记录每一波实际生成的敌人
	var seen := {}
	var last := 0
	while not w.over:
		var before: int = w.enemies.size()
		w.tick()
		for i in range(before, w.enemies.size()):
			var e = w.enemies[i]
			var k: int = e.wave_index
			if not seen.has(k):
				seen[k] = {"n": 0, "hp": e.max_hp, "atk": e.attack, "coin": e.coin,
					"pos": e.wave_pos, "name": e.type_name, "t": w.time,
					"speed": e.speed, "move": e.move_kind, "kind": e.attack_kind}
			seen[k]["n"] = int(seen[k]["n"]) + 1
		last = maxi(last, w.enemies.size())

	print("波   周期.位  首次生成  名称         移动/攻击        速度  数量     单只血量    攻击力  单只金币  波总血量")
	var keys := seen.keys()
	keys.sort()
	for k in keys:
		var r = seen[k]
		print("%-4d %d.%d    %6.1fs  %-12s %-16s %.1f  %-8s %-11s %-7s %-9s %s" % [
			k, (k - 1) / 8 + 1, r["pos"], r["t"], r["name"],
			"%s/%s" % [r["move"], r["kind"]], r["speed"],
			_f(float(r["n"])), _f(r["hp"]), _f(r["atk"]), _f(r["coin"]),
			_f(float(r["n"]) * float(r["hp"]))])
	print("\n同屏峰值敌人数：", last)
	quit()

func _f(x: float) -> String:
	if x >= 1000.0:
		return "%.0f" % x
	if x >= 10.0:
		return "%.0f" % x
	return "%.2f" % x
