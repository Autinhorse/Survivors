extends SceneTree
## 想要的曲线是「早期机枪够用，后期不带单发就顶不住」——一个**时间上的交叉**。
##
## ThreatRate 把整局揉成一个数，看不出交叉：它只能回答"平均下来谁强"。
## 这里按周期分段，武器按设计的换代表升级，机甲设成打不死跑满全程，
## 于是能直接看出纯机枪线是从第几个周期开始塌的。
##
## 交叉存在的判据：
##   前几个周期  纯机枪的杂兵漏掉率 **低于** 混合（机枪优势）
##   后几个周期  纯机枪的重甲漏掉率拖垮它，混合反超
## 如果纯机枪从第 1 个周期就不占优，那"早期机枪优势"这个设计意图还没实现。

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const Turret = preload("res://sim/entities/Turret.gd")

const CELLS := [Vector2i(1, 0), Vector2i(2, 1), Vector2i(1, 2), Vector2i(0, 1),
	Vector2i(0, 0), Vector2i(2, 0), Vector2i(2, 2), Vector2i(0, 2)]
const RAPID := ["machine_gun", "heavy_machine_gun", "gatling", "gatling_array"]
const SINGLE := ["rifle", "marksman_rifle", "sniper_rifle", "pierce_rifle"]
const HEAVY_POS := 4
const NBUCKETS := 16

var runs: int = 3
var dur: float = 900.0
var tier_cycles: float = 5.1

func _initialize() -> void:
	for s in OS.get_cmdline_user_args():
		var kv := String(s).split("=", true, 1)
		if kv.size() == 2 and kv[0] == "runs":
			runs = int(kv[1])
		elif kv.size() == 2 and kv[0] == "dur":
			dur = float(kv[1])
	print("机甲打不死，跑满 %.0f 秒 × %d 局，武器按换代表升级；按周期分段看漏掉率"
		% [dur, runs])
	_one("纯机枪 8", [[RAPID, 8]])
	_one("6机枪+2单发", [[RAPID, 6], [SINGLE, 2]])
	_one("4机枪+4单发", [[RAPID, 4], [SINGLE, 4]])
	quit()

## 第 t 秒该有的代数（0-3）与级别（1-3），和 LadderTest 用同一张表
func _schedule(t: float, cyc: float) -> Vector2i:
	var c: float = t / cyc + 1.0
	var x: float = maxf(0.0, (c - 2.0) / tier_cycles)
	var tier: int = mini(3, int(x))
	var lv: int = mini(3, 1 + int((x - float(tier)) * 3.0))
	return Vector2i(tier, lv)

func _one(tag: String, spec: Array) -> void:
	var sw_s := PackedFloat32Array(); sw_s.resize(NBUCKETS)
	var sw_k := PackedFloat32Array(); sw_k.resize(NBUCKETS)
	var hv_s := PackedFloat32Array(); hv_s.resize(NBUCKETS)
	var hv_k := PackedFloat32Array(); hv_k.resize(NBUCKETS)
	# 重甲漏掉率是平的（纯机枪全程 100%），所以"威胁越来越厉害"体现不在
	# 漏掉**比例**上，而在漏掉的**代价**上。这一行量每个周期重甲打出多少
	# 伤害，换算成几管满血——>1 就表示这个周期光靠挨打就会死一次。
	var hv_d := PackedFloat32Array(); hv_d.resize(NBUCKETS)
	var max_hp: float = 1000.0

	for s in runs:
		var cfg = SimConfig.new()
		cfg.seed_value = 900 + s
		cfg.duration_sec = dur
		cfg.move_policy = "field"
		var ag = ScriptedAgent.new()
		ag.move_policy = "field"
		ag.pick_policy = "dps"
		ag.rng = Rng.new(950 + s)
		var w = SimWorld.new()
		w.setup(cfg, ag)
		w.shop.leave(w)
		w.shop.next_spawn_t = 1.0e9              # 关经济，只测这套炮塔本身
		w.mech.max_hp = 1.0e12                   # 打不死：局长不再是变量
		w.mech.hp = 1.0e12
		var cyc: float = w.spawner.wave_gap * float(w.spawner.cycle_waves)
		w.mech.turrets.clear()
		var slot := 0
		var groups: Array = []
		for item in spec:
			var chain: Array = item[0]
			for i in int(item[1]):
				var t = Turret.new(String(chain[0]), CELLS[slot], 1, 1)
				w.mech.turrets.append(t)
				groups.append([t, chain])
				slot += 1

		var seen: Dictionary = {}
		var applied := Vector2i(-1, -1)
		var last_k: Array = [0, 0, 0, 0, 0, 0, 0, 0]
		var last_d: float = 0.0
		max_hp = float(w.db.cfg("mech/max_hp", 1000.0))
		while not w.over:
			var sch := _schedule(w.time, cyc)
			if sch != applied:
				applied = sch
				for g in groups:
					var chain2: Array = g[1]
					g[0].weapon_id = String(chain2[sch.x])
					g[0].level = sch.y
			w.tick()
			var b: int = clampi(int(w.time / cyc), 0, NBUCKETS - 1)
			for e in w.enemies:
				if seen.has(e):
					continue
				seen[e] = true
				if e.wave_pos == HEAVY_POS:
					hv_s[b] += 1.0
				else:
					sw_s[b] += 1.0
			var dd: float = float(w.log.damage_by_wave_pos[HEAVY_POS - 1])
			hv_d[b] += dd - last_d
			last_d = dd
			# kills_by_wave_pos 是累计值，取差分才是"这个周期杀了多少"
			for i in 8:
				var k: int = int(w.log.kills_by_wave_pos[i])
				var d: int = k - int(last_k[i])
				if d <= 0:
					continue
				if i + 1 == HEAVY_POS:
					hv_k[b] += float(d)
				else:
					sw_k[b] += float(d)
				last_k[i] = k

	var head := "%-14s%-9s" % ["", "周期"]
	var l1 := "%-14s%-9s" % [tag, "杂兵漏掉"]
	var l2 := "%-14s%-9s" % ["", "重甲漏掉"]
	var l3 := "%-14s%-9s" % ["", "重甲伤害"]
	for b in NBUCKETS:
		if sw_s[b] <= 0.0:
			continue
		head += "%-6d" % (b + 1)
		l1 += "%-6s" % ("%.0f%%" % (100.0 * maxf(0.0, sw_s[b] - sw_k[b]) / sw_s[b]))
		l2 += "%-6s" % ("%.0f%%" % (100.0 * maxf(0.0, hv_s[b] - hv_k[b]) / maxf(1.0, hv_s[b])))
		l3 += "%-6s" % ("%.1f" % (hv_d[b] / float(runs) / maxf(1.0, max_hp)))
	print(head)
	print(l1)
	print(l2)
	print(l3 + "  （单位：满血管数／周期，>1 = 光挨这一种就够死一次）")
