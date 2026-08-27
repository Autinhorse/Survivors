extends SceneTree
## 带**真实经济**的一局到底死于什么？
##
## LadderTest / ThreatRate / ThreatCurve 一律开局直发 8 门炮塔，
## 于是"早期无压力"是个假象——真实开局只有 1 门枪，靠商店慢慢铺。
## 手玩 70.8 秒暴毙、Batch 平均 108 秒，信号一直在，是我没去看。
##
## 这里跑真实流程（商店开着、AI 自己买卡、从 1 门枪起步），死的时候
## 把现场拍下来：几门炮塔、什么级别、伤害来自哪一位、钱花掉没有。

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")

const NAMES := ["?", "散兵", "散兵密", "正方向群", "重甲炮台", "冲锋群",
	"远程弧", "斜角快群", "直线冲撞"]

var runs: int = 8
## pick_policy 不只是"挑哪张卡"，它还决定 prefer_new 和要不要合并：
##   dps  —— 有同名塔就升级、能合就合（往深里堆）
##   wide —— 先铺满空槽再考虑升级
## 早就量过宽度远优于高度，所以拿 dps 当基准会把游戏显得比实际更难。
var policies := ["dps", "wide"]

func _initialize() -> void:
	for s in OS.get_cmdline_user_args():
		var kv := String(s).split("=", true, 1)
		if kv.size() == 2 and kv[0] == "runs":
			runs = int(kv[1])

	for pol in policies:
		_one(String(pol))
	quit()

func _one(pol: String) -> void:
	var dur := 0.0
	var waves := 0
	var coins_left := 0.0
	var shop_visits := 0.0
	var turrets := 0.0
	var cards := 0.0
	var spawned_n := 0.0
	var expired_n := 0.0
	var on_field := 0.0
	var killed := 0.0
	var dmg := PackedFloat32Array(); dmg.resize(9)
	var builds: Array = []

	for s in runs:
		var cfg = SimConfig.new()
		cfg.seed_value = 1300 + s
		cfg.duration_sec = 1800.0
		cfg.move_policy = "field"
		var ag = ScriptedAgent.new()
		ag.move_policy = "field"
		ag.pick_policy = pol
		ag.rng = Rng.new(1350 + s)
		var w = SimWorld.new()
		w.setup(cfg, ag)          # 商店照常开，AI 自己买卡，从 1 门枪起步
		while not w.over:
			w.tick()
		dur += w.time
		waves += w.log.wave_reached
		coins_left += w.mech.coins
		shop_visits += float(w.log.shop_visits)
		turrets += float(w.mech.turrets.size())
		cards += float(w.shop.bought_count)
		spawned_n += float(w.shop.site_spawned)
		expired_n += float(w.shop.site_expired)
		killed += float(w.log.kills_total)
		var alive := 0
		for e in w.enemies:
			if e.alive:
				alive += 1
		on_field += float(alive)
		for i in 8:
			dmg[i + 1] += float(w.log.damage_by_wave_pos[i])
		if s < 3:
			var ids: Array = []
			for t in w.mech.turrets:
				ids.append("%s@%d" % [w.db.weapon_name(t.weapon_id), t.level])
			ids.sort()
			builds.append("%.0fs %s" % [w.time, " ".join(ids)])

	var n := float(runs)
	print("[%s] 真实经济 %d 局：平均存活 %.1fs　推到第 %d 波　击杀 %.0f　死时场上 %.0f 个敌人"
		% [pol, runs, dur / n, int(float(waves) / n), killed / n, on_field / n])
	print("死时：炮塔 %.1f 门　进过商店 %.1f 次　买了 %.1f 张卡　金币剩 %.0f（没花掉的）"
		% [turrets / n, shop_visits / n, cards / n, coins_left / n])
	print("商店点位：生成 %.1f 个，其中 %.1f 个没赶到作废"
		% [spawned_n / n, expired_n / n])
	var tot := 0.0
	for x in dmg:
		tot += x
	print("致死伤害来源：")
	for i in range(1, 9):
		if dmg[i] <= tot * 0.02:
			continue
		print("   %-10s %.0f%%" % [NAMES[i], 100.0 * dmg[i] / maxf(1.0, tot)])
	print("样例 build：")
	for b in builds:
		print("   " + String(b))
	print("")
