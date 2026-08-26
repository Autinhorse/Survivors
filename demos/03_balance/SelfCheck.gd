extends SceneTree
## P1 验收 + 确定性验收。
##   godot --headless --script res://demos/03_balance/SelfCheck.gd

const Torus = preload("res://sim/core/Torus.gd")
const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")

var fails := 0

func ok(name: String, cond: bool, extra: String = "") -> void:
	if not cond:
		fails += 1
	print("%s  %s%s" % ["[PASS]" if cond else "[FAIL]", name, ("   " + extra) if extra != "" else ""])

func _initialize() -> void:
	var t = Torus.new(200.0, 100.0, true, true)

	ok("环形：跨接缝的最短向量", t.delta(Vector2(199, 50), Vector2(1, 50)) == Vector2(2, 0),
		str(t.delta(Vector2(199, 50), Vector2(1, 50))))
	ok("环形：跨接缝距离 = 2 而不是 198", is_equal_approx(t.dist(Vector2(199, 50), Vector2(1, 50)), 2.0),
		"%.1f" % t.dist(Vector2(199, 50), Vector2(1, 50)))
	ok("环形：上下也接", is_equal_approx(t.dist(Vector2(10, 99), Vector2(10, 1)), 2.0))
	ok("环形：wrap 回到地图内", t.wrap(Vector2(-3, 105)) == Vector2(197, 5), str(t.wrap(Vector2(-3, 105))))
	ok("环形：最远距离是半个地图", is_equal_approx(t.dist(Vector2(0, 0), Vector2(100, 50)),
		Vector2(100, 50).length()))
	ok("角度约定：0°=正上", Torus.angle_to_vec(0).is_equal_approx(Vector2(0, -1)))
	ok("角度约定：90°=正右", Torus.angle_to_vec(90).is_equal_approx(Vector2(1, 0)))

	# 一直朝一个方向走，应该绕回原点
	var cfg = SimConfig.new()
	cfg.seed_value = 3
	cfg.duration_sec = 200.0
	var w = SimWorld.new()
	w.setup(cfg, ScriptedAgent.new())
	var start: Vector2 = w.mech.pos
	var speed: float = w.mech.move_speed
	var steps := int(round(200.0 / speed / w.dt))     # 走满一圈宽度
	for i in steps:
		w.mech.pos = w.torus.wrap(w.mech.pos + Vector2.RIGHT * speed * w.dt)
	ok("机甲一直向右走 200 格后回到原位", w.torus.dist(start, w.mech.pos) < 0.01,
		"偏差 %.4f 格" % w.torus.dist(start, w.mech.pos))

	# 确定性：同 seed 两次跑，逐字段一致
	var a := _run(1234)
	var b := _run(1234)
	var c := _run(1235)
	ok("确定性：同 seed 两次结果相同", a == b)
	ok("确定性：不同 seed 结果不同", a != c)

	check_p3()
	check_targeting()
	check_shapes()
	check_map_eval()
	print("\n%d 项失败" % fails)
	quit(1 if fails > 0 else 0)

func _run(seed_value: int) -> String:
	var cfg = SimConfig.new()
	cfg.seed_value = seed_value
	cfg.duration_sec = 120.0
	cfg.move_policy = "kite"
	var ag = ScriptedAgent.new()
	ag.move_policy = "kite"
	ag.pick_policy = "dps"
	ag.rng = Rng.new(seed_value ^ 0x5f3759df)
	var w = SimWorld.new()
	w.setup(cfg, ag)
	var lg = w.run_to_end()
	return lg.csv_row()

## ---- P3 验收：槽位攻击弧 + 六种索敌 ----
func check_p3() -> void:
	var Mech = load("res://sim/entities/Mech.gd")
	var m = Mech.new()
	m.rot = 0.0
	# §6.4 的角度表（0°=正上，顺时针）。槽位编号 1-8 对应索引 0-7。
	var want := {0: 315.0, 1: 0.0, 2: 45.0, 3: 270.0, 4: 90.0, 5: 225.0, 6: 180.0, 7: 135.0}
	var all_ok := true
	for slot in want.keys():
		var center_rad: float = m.slot_arc_center(slot)
		# sim 用的是数学角（atan2(y,x)，屏幕系 y 向下）；文档用的是"正上 0°、顺时针"。
		# 上=(0,-1) 数学角 -90° 对应文档 0°，所以 文档角 = 数学角 + 90°。
		var deg := fposmod(rad_to_deg(center_rad) + 90.0, 360.0)
		if absf(fposmod(deg - float(want[slot]) + 180.0, 360.0) - 180.0) > 0.5:
			all_ok = false
			print("      槽 %d 弧心 %.1f°，文档要 %.1f°" % [slot + 1, deg, want[slot]])
	ok("槽位攻击弧心与 §6.4 的角度表一致", all_ok)

	# 转 90° 后，角落槽的弧应该正好落到下一个角落槽原来的位置（对称性）
	var before: float = m.slot_arc_center(0)
	m.rot = PI * 0.5
	ok("旋转 90° 后角落槽弧心 = 原来的下一个角落槽",
		absf(wrapf(m.slot_arc_center(0) - before - PI * 0.5, -PI, PI)) < 0.001)

## ---- P3 验收：六种索敌方式各自选中预期目标 ----
func check_targeting() -> void:
	var Enemy = load("res://sim/entities/Enemy.gd")
	var Turret = load("res://sim/entities/Turret.gd")
	var cfg = SimConfig.new()
	cfg.seed_value = 1
	var w = SimWorld.new()
	w.setup(cfg, ScriptedAgent.new())
	var c: Vector2 = w.mech.pos

	var near = Enemy.new(); near.pos = c + Vector2(0, -2); near.hp = 100.0; near.alive = true
	var far = Enemy.new();  far.pos  = c + Vector2(0, -8); far.hp  = 5000.0; far.alive = true
	var weak = Enemy.new(); weak.pos = c + Vector2(0, -5); weak.hp = 10.0;  weak.alive = true
	var pool := [near, far, weak]
	var t = Turret.new("gun", 1, 1)

	ok("索敌1 最近", w.targeting.pick(1, t, pool, c) == near)
	ok("索敌3 血量最低", w.targeting.pick(3, t, pool, c) == weak)
	ok("索敌4 血量最高", w.targeting.pick(4, t, pool, c) == far)
	var first = w.targeting.pick(2, t, pool, c)
	weak.pos = c + Vector2(0, -1)          # 更近的出现了
	ok("索敌2 锁定：目标没死就不换", w.targeting.pick(2, t, pool, c) == first)
	first.alive = false
	ok("索敌2 锁定：目标死了才换", w.targeting.pick(2, t, [far, weak], c) == weak)
	ok("索敌5/6 接上 P4 后不再退化", w.targeting.pick(5, t, [far, weak], c) != null)

## ---- P3 验收：四种攻击形态 ----
func check_shapes() -> void:
	var Enemy = load("res://sim/entities/Enemy.gd")
	var Turret = load("res://sim/entities/Turret.gd")

	# 范围：Wall of Lead（aoe 3）一发应该打到一堆里的全部
	var w = _world_with("wall_of_lead")
	var c: Vector2 = w.mech.pos
	var cluster: Array = []
	for i in 5:
		var e = Enemy.new()
		e.pos = c + Vector2(float(i) * 0.6 - 1.2, -5.0)
		e.max_hp = 1.0e9; e.hp = e.max_hp; e.speed = 0.0; e.attack = 0.0
		cluster.append(e)
	w.enemies = cluster.duplicate()
	for i in 90:
		w.tick()
	var hurt := 0
	for e in cluster:
		if e.hp < e.max_hp:
			hurt += 1
	ok("范围形态：一发打到范围内全部 5 个", hurt == 5, "实际 %d 个" % hurt)

	# 线性：穿刺枪应该打到一条线上的每一个，且沿途只吃 20%
	var w2 = _world_with("pierce_rifle")
	var c2: Vector2 = w2.mech.pos
	var row: Array = []
	for i in 4:
		var e2 = Enemy.new()
		e2.pos = c2 + Vector2(0.0, -3.0 - float(i) * 1.5)
		e2.max_hp = 1.0e9; e2.hp = e2.max_hp; e2.speed = 0.0; e2.attack = 0.0
		row.append(e2)
	w2.enemies = row.duplicate()
	for i in 90:
		w2.tick()
	var hurt2 := 0
	for e2 in row:
		if e2.hp < e2.max_hp:
			hurt2 += 1
	var dmg: float = row[0].max_hp - row[0].hp
	ok("线性形态：一发打穿一列 4 个", hurt2 == 4, "实际 %d 个" % hurt2)
	ok("线性形态：沿途伤害是 20%", is_equal_approx(dmg, 40000.0 * 0.2), "实际 %.0f" % dmg)

	# 击退：Shotgun 命中后把敌人推开
	var w3 = _world_with("shotgun")
	var c3: Vector2 = w3.mech.pos
	var e3 = Enemy.new()
	e3.pos = c3 + Vector2(0, -5); e3.max_hp = 1.0e9; e3.hp = e3.max_hp
	e3.speed = 0.0; e3.attack = 0.0
	w3.enemies = [e3]
	var d0: float = w3.torus.dist(c3, e3.pos)
	for i in 90:
		w3.tick()
	ok("击退：命中后被推远 0.75 格", w3.torus.dist(c3, e3.pos) > d0 + 0.7,
		"推了 %.2f 格" % (w3.torus.dist(c3, e3.pos) - d0))

func _world_with(weapon_id: String):
	var Turret = load("res://sim/entities/Turret.gd")
	var cfg = SimConfig.new()
	cfg.seed_value = 5
	var w = SimWorld.new()
	w.setup(cfg, ScriptedAgent.new())
	w.mech.turrets.clear()
	w.mech.turrets.append(Turret.new(weapon_id, 1, 1))   # 槽 1 = 正北，弧心 0°
	w.spawner._next_wave = 99999                          # 关掉刷怪，只测武器
	return w

## ---- P4 验收：地图状态评估（§7.6）----
func check_map_eval() -> void:
	var Enemy = load("res://sim/entities/Enemy.gd")
	var Turret = load("res://sim/entities/Turret.gd")
	var w = _world_with("gun")
	var c: Vector2 = w.mech.pos

	# 上方放 3 只近战、右方放 1 只，检查分区和四方向汇总
	var es: Array = []
	for i in 3:
		var e = Enemy.new()
		e.pos = c + Vector2(float(i) - 1.0, -6.0)
		e.max_hp = 500.0; e.hp = 500.0; e.attack = 20.0; e.attack_interval = 2.0
		e.speed = 0.0; e.attack_kind = "melee"
		es.append(e)
	var r = Enemy.new()
	r.pos = c + Vector2(8.0, 0.0)
	r.max_hp = 9000.0; r.hp = 9000.0; r.attack = 40.0; r.attack_interval = 2.0
	r.speed = 0.0; r.attack_kind = "melee"
	es.append(r)
	w.enemies = es
	w.map_eval.evaluate(w)
	var me = w.map_eval

	ok("九宫格：上方区域数到 3 只", me.region_count[1] == 3, "实际 %d" % me.region_count[1])
	ok("九宫格：右方区域数到 1 只", me.region_count[5] == 1, "实际 %d" % me.region_count[5])
	ok("四方向：上方血量 1500", is_equal_approx(me.dir_hp[0], 1500.0), "%.0f" % me.dir_hp[0])
	ok("四方向：右方血量 9000", is_equal_approx(me.dir_hp[1], 9000.0), "%.0f" % me.dir_hp[1])
	# 近战衰减：离边缘 6-1.5=4.5 → 第 5 圈 → 100% - 4*10% = 60%
	var want: float = 3.0 * (20.0 / 2.0) * 0.6
	ok("近战威胁按圈衰减（第5圈=60%）", absf(me.dir_threat[0] - want) < 0.5,
		"%.1f，期望 %.1f" % [me.dir_threat[0], want])
	ok("高血量列表：阈值 4500，只留下那只 9000 的",
		me.top_hp.size() == 1 and me.top_hp[0] == r, "%d 个" % me.top_hp.size())
	# 槽 1 在正北，弧 270°-90°，所以只覆盖"上"，不覆盖"下"
	ok("分方向己方 DPS：北槽只算在上方", me.dir_dps[0] > 0.0 and me.dir_dps[2] == 0.0,
		"上 %.0f / 下 %.0f" % [me.dir_dps[0], me.dir_dps[2]])
	ok("清场秒数 = 该方向敌人血量 / 己方 DPS",
		absf(me.dir_clear_sec[0] - me.dir_hp[0] / me.dir_dps[0]) < 0.01)

	# 索敌 5：范围杀伤最大 —— 一堆里的应该胜过孤零零的
	var w2 = _world_with("wall_of_lead")
	var c2: Vector2 = w2.mech.pos
	var lone = Enemy.new(); lone.pos = c2 + Vector2(0, -4); lone.hp = 100.0
	var pack: Array = [lone]
	for i in 6:
		var e2 = Enemy.new()
		e2.pos = c2 + Vector2(float(i % 3) - 1.0, -7.0 - float(i / 3))
		e2.hp = 100.0
		pack.append(e2)
	w2.enemies = pack
	w2.map_eval.evaluate(w2)
	var t2 = Turret.new("wall_of_lead", 1, 1)
	var picked = w2.targeting.pick(5, t2, pack, c2)
	ok("索敌5 范围杀伤最大：选中扎堆的而不是落单的", picked != lone)

	# 索敌 6：对自己 DPS 最高
	var w3 = _world_with("gun")
	var c3: Vector2 = w3.mech.pos
	var weak = Enemy.new(); weak.pos = c3 + Vector2(0, -3); weak.hp = 100.0
	weak.attack = 5.0; weak.attack_interval = 2.0
	var nasty = Enemy.new(); nasty.pos = c3 + Vector2(0, -4); nasty.hp = 100.0
	nasty.attack = 200.0; nasty.attack_interval = 2.0
	w3.enemies = [weak, nasty]
	w3.map_eval.evaluate(w3)
	ok("索敌6 对自己DPS最高：选中打得疼的那个",
		w3.targeting.pick(6, Turret.new("gun", 1, 1), [weak, nasty], c3) == nasty)

	# 性能预算：1000 只敌人一次评估要在 1ms 以内
	var w4 = _world_with("gun")
	var c4: Vector2 = w4.mech.pos
	var many: Array = []
	for i in 1000:
		var e4 = Enemy.new()
		e4.pos = c4 + Vector2(float(i % 25) - 12.0, float(i / 25) * 0.5 - 12.0)
		e4.hp = 100.0; e4.max_hp = 100.0; e4.attack = 10.0; e4.attack_interval = 2.0
		many.append(e4)
	w4.enemies = many
	w4.map_eval.evaluate(w4)                       # 预热
	var t0 := Time.get_ticks_usec()
	for i in 10:
		w4.map_eval.evaluate(w4)
	var us := float(Time.get_ticks_usec() - t0) / 10.0
	# 1000 只全在盘内是压力值（实战峰值约 100-300）。1 Hz × 批量 36 倍速 ≈ 4% 开销，
	# 所以判据定在 1.5ms；超过这个数就得回去量哪一段又变慢了。
	ok("1000 敌人单次评估 < 1.5ms（压力值）", us < 1500.0, "%.0f µs" % us)
	print("\n--- 评估快照（上方 3 只近战 + 右方 1 只重甲）---")
	print(me.snapshot())
