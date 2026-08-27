extends SceneTree
## 分工到底成不成立？——用速率量，不用存活时间量。
##
## 存活时间在 8 局采样下波动 ±69%（137-700 秒），而 build 之间的差距只有
## 9%，结论全被噪声吃掉。根因是它是一连串复利失效的**终点**：杂兵清理、
## 重甲累积、装甲、走位运气全揉在一起。加采样填不满这个方差。
##
## 这里把机甲血量拉到打不死、固定跑满 600 秒，于是局长不再是变量，
## 量出来的是干净的速率：
##   杂兵漏掉率 —— 匀出槽位去打重甲，杂兵这边塌不塌
##   重甲漏掉率 —— 打不到它的 build 到底漏成什么样
##   每分钟受伤（按来源分）—— "忽略重甲"的代价具体是多少
## 这三个都是比率，方差比"撑到第几秒"小一个量级。

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const Turret = preload("res://sim/entities/Turret.gd")

const CELLS := [Vector2i(1,0), Vector2i(2,1), Vector2i(1,2), Vector2i(0,1),
	Vector2i(0,0), Vector2i(2,0), Vector2i(2,2), Vector2i(0,2)]
const HEAVY_POS := 4

var runs: int = 4
## 600 秒时敌人堆积到模拟跑不动（4 套 build 只跑完 1 套），而且堆积本身
## 扭曲了伤害构成——本该杀死机甲的杂兵会一直打下去。收到 300 秒：
## 这是实测局长的量级，场面还像真的在玩。
var dur: float = 300.0

func _initialize() -> void:
	for s in OS.get_cmdline_user_args():
		var kv := String(s).split("=", true, 1)
		if kv.size() == 2 and kv[0] == "runs":
			runs = int(kv[1])
		elif kv.size() == 2 and kv[0] == "dur":
			dur = float(kv[1])
	print("机甲设成打不死，固定跑满 %.0f 秒 × %d 局，量速率而不是存活时间" % [dur, runs])
	print("%-22s %-12s %-12s %-16s %-14s"
		% ["build", "杂兵漏掉", "重甲漏掉", "总受伤", "其中来自重甲"])
	# 机枪的边际收益曲线。8/6/4 门杂兵漏掉率都是 20%，怀疑 20% 是测量地板
	# （300 秒截断时还在路上的敌人，任何 build 都算漏掉）。往下削到 1 门：
	# 漏掉率一直不动 = 指标是瞎的；某一档开始上翘 = 那里才是真的拐点。
	_one("机枪 8 门", [["machine_gun", 8]])
	_one("机枪 6 门", [["machine_gun", 6]])
	_one("机枪 4 门", [["machine_gun", 4]])
	_one("机枪 2 门", [["machine_gun", 2]])
	_one("机枪 1 门", [["machine_gun", 1]])
	quit()

func _one(tag: String, spec: Array) -> void:
	var swarm_leak := 0.0
	var heavy_leak := 0.0
	var dmg_min := 0.0
	var heavy_share := 0.0
	var lo := INF
	var hi := 0.0
	for s in runs:
		var cfg = SimConfig.new()
		cfg.seed_value = 700 + s
		cfg.duration_sec = dur
		cfg.move_policy = "field"
		var ag = ScriptedAgent.new()
		ag.move_policy = "field"
		ag.pick_policy = "dps"
		ag.rng = Rng.new(800 + s)
		var w = SimWorld.new()
		w.setup(cfg, ag)
		w.shop.leave(w)
		w.shop.next_spawn_t = 1.0e9          # 关经济，只测这套炮塔本身
		# 打不死：局长不再是变量，速率才量得准
		w.mech.max_hp = 1.0e12
		w.mech.hp = 1.0e12
		w.mech.turrets.clear()
		var slot := 0
		for item in spec:
			for i in int(item[1]):
				w.mech.turrets.append(Turret.new(String(item[0]), CELLS[slot], 1, 1))
				slot += 1

		var spawned := PackedInt32Array(); spawned.resize(9)
		var seen: Dictionary = {}
		while not w.over:
			w.tick()
			for e in w.enemies:
				if not seen.has(e):
					seen[e] = true
					spawned[clampi(e.wave_pos, 0, 8)] += 1

		var sw_s := 0; var sw_k := 0
		var hv_s := 0; var hv_k := 0
		for i in range(1, 9):
			var k: int = int(w.log.kills_by_wave_pos[i - 1])
			if i == HEAVY_POS:
				hv_s += spawned[i]; hv_k += k
			else:
				sw_s += spawned[i]; sw_k += k
		swarm_leak += 100.0 * float(maxi(0, sw_s - sw_k)) / maxf(1.0, float(sw_s))
		heavy_leak += 100.0 * float(maxi(0, hv_s - hv_k)) / maxf(1.0, float(hv_s))
		var tot: float = w.log.damage_taken
		var hv_d: float = float(w.log.damage_by_wave_pos[HEAVY_POS - 1])
		# 局长已经固定，不用再按分钟归一化——直接比同一窗口内的总量
		var per_min: float = tot
		dmg_min += per_min
		heavy_share += 100.0 * hv_d / maxf(1.0, tot)
		lo = minf(lo, per_min)
		hi = maxf(hi, per_min)
	var n := float(runs)
	var avg: float = dmg_min / n
	print("%-22s %-12s %-12s %-14s %-14s" % [tag,
		"%.0f%%" % (swarm_leak / n),
		"%.0f%%" % (heavy_leak / n),
		"%.0f (±%.0f%%)" % [avg, 100.0 * maxf(hi - avg, avg - lo) / maxf(1.0, avg)],
		"%.0f%%" % (heavy_share / n)])
