extends SceneTree
## 按时间表升级的 build 测试。
##
## BuildCompare 把炮塔冻结在 1 级，测不出"升级与合并的节奏"这套设计——
## 8 门机枪@1 死在第 8 周期，是死于"该合并了但不能合并"，不是死于配平。
## 这个工具让炮塔按设计的时间表自动换代升级：
##   一代 = log(2k)/log(血量成长) ≈ 5.1 个周期，代内匀速升到 3 级。
## 于是测出来的才是"这套数值曲线本身站不站得住"，而不是"某个快照强不强"。
##
##   godot --headless --script res://demos/03_balance/LadderTest.gd -- runs=5

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const Turret = preload("res://sim/entities/Turret.gd")

const CELLS := [Vector2i(1, 0), Vector2i(2, 1), Vector2i(1, 2), Vector2i(0, 1),
	Vector2i(0, 0), Vector2i(2, 0), Vector2i(2, 2), Vector2i(0, 2)]
const RAPID := ["machine_gun", "heavy_machine_gun", "gatling", "gatling_array"]
const SINGLE := ["rifle", "marksman_rifle", "sniper_rifle", "pierce_rifle"]
const SPREAD := ["spread_gun", "shotgun", "fragment_cannon", "wall_of_lead"]

var runs: int = 5
var tier_cycles: float = 5.1
## 一个周期多少秒。**从数据里读**，不能写死——波间隔从 10 改到 7 秒那次，
## 这里还停在 80，升级表比敌人慢了 30%，跑出来的数字全是错的。
var cycle_sec: float = 80.0
var only: String = ""
var cap: float = 1800.0

func _initialize() -> void:
	for s in OS.get_cmdline_user_args():
		var kv := String(s).split("=", true, 1)
		if kv.size() == 2 and kv[0] == "runs":
			runs = int(kv[1])
		elif kv.size() == 2 and kv[0] == "only":
			only = String(kv[1])
		elif kv.size() == 2 and kv[0] == "cap":
			cap = float(kv[1])

	var probe = SimWorld.new()
	probe.setup(SimConfig.new(), ScriptedAgent.new())
	cycle_sec = probe.spawner.wave_gap * float(probe.spawner.cycle_waves)
	print("周期 %.0f 秒（%d 波 × %.0f 秒）；一代 %.1f 个周期（%.1f 分钟），代内匀速升到 3 级"
		% [cycle_sec, probe.spawner.cycle_waves, probe.spawner.wave_gap,
			tier_cycles, tier_cycles * cycle_sec / 60.0])
	print("%-26s %-9s %-13s %-9s %s"
		% ["build", "平均存活", "波动(最短-最长)", "推到第几波", "终局武器"])
	_run("纯机枪线", [[RAPID, 8]])
	_run("纯单发线", [[SINGLE, 8]])
	_run("纯散弹线", [[SPREAD, 8]])
	_run("混合 4机枪+4单发", [[RAPID, 4], [SINGLE, 4]])
	_run("混合 3机枪+3散弹+2单发", [[RAPID, 3], [SPREAD, 3], [SINGLE, 2]])
	_run("混合 4机枪+2散弹+2单发", [[RAPID, 4], [SPREAD, 2], [SINGLE, 2]])
	quit()

## 第 t 秒时该有的代数（0-3）与级别（1-3）
func _schedule(t: float) -> Vector2i:
	var c: float = t / cycle_sec + 1.0            # 当前周期（从 1 数）
	var x: float = maxf(0.0, (c - 2.0) / tier_cycles)
	var tier: int = mini(3, int(x))
	var lv: int = mini(3, 1 + int((x - float(tier)) * 3.0))
	return Vector2i(tier, lv)

func _run(name: String, spec: Array) -> void:
	if only != "" and not name.contains(only):
		return
	var total := 0.0
	var waves := 0
	var last := ""
	# 光报平均值会骗人：一次 4 档扫描里 80→120 两个 build 都"活得更久"，
	# 而经济是关掉的、敌人更疼不可能延长存活——那一行纯粹是噪声。
	# 不报离散度就分不出信号和噪声，所以每行都带上最短/最长。
	var lo := INF
	var hi := 0.0
	for s in runs:
		var cfg = SimConfig.new()
		cfg.seed_value = 300 + s
		cfg.duration_sec = cap
		cfg.move_policy = "field"
		var ag = ScriptedAgent.new()
		ag.move_policy = "field"
		ag.pick_policy = "dps"
		ag.rng = Rng.new(400 + s)
		var w = SimWorld.new()
		w.setup(cfg, ag)
		w.shop.leave(w)
		w.shop.next_spawn_t = 1.0e9          # 关掉经济，只测数值曲线
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

		var applied := Vector2i(-1, -1)
		while not w.over:
			var sch := _schedule(w.time)
			if sch != applied:
				applied = sch
				for gitem in groups:
					var t = gitem[0]
					var chain: Array = gitem[1]
					t.weapon_id = String(chain[sch.x])
					t.level = sch.y
			w.tick()
		total += w.log.run_duration
		lo = minf(lo, w.log.run_duration)
		hi = maxf(hi, w.log.run_duration)
		waves = maxi(waves, w.log.wave_reached)
		var ids: Array = []
		for t in w.mech.turrets:
			ids.append(w.db.weapon_name(t.weapon_id) + "@" + str(t.level))
		ids.sort()
		last = " ".join(ids)
	var avg: float = total / float(runs)
	print("%-26s %-9.1f %-13s %-9d %s" % [name, avg,
		"%.0f-%.0f (±%.0f%%)" % [lo, hi, 100.0 * maxf(hi - avg, avg - lo) / maxf(1.0, avg)],
		waves, last.substr(0, 40)])
