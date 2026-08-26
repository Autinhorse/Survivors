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
	check_armor()
	check_armor_v2()
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
	var Turret = load("res://sim/entities/Turret.gd")
	var m = Mech.new()
	m.base_size = 3
	m.rot = 0.0
	# §6.4 的角度表（0°=正上，顺时针）。1-8 号槽位 = 3×3 格盘上除中心外的 8 格。
	var CELLS := [Vector2i(0,0), Vector2i(1,0), Vector2i(2,0), Vector2i(0,1),
		Vector2i(2,1), Vector2i(0,2), Vector2i(1,2), Vector2i(2,2)]
	var want := {0: 315.0, 1: 0.0, 2: 45.0, 3: 270.0, 4: 90.0, 5: 225.0, 6: 180.0, 7: 135.0}
	var all_ok := true
	for slot in want.keys():
		var center_rad: float = m.slot_arc_center(Turret.new("gun", CELLS[slot], 1, 1))
		# sim 用的是数学角（atan2(y,x)，屏幕系 y 向下）；文档用的是"正上 0°、顺时针"。
		# 上=(0,-1) 数学角 -90° 对应文档 0°，所以 文档角 = 数学角 + 90°。
		var deg := fposmod(rad_to_deg(center_rad) + 90.0, 360.0)
		if absf(fposmod(deg - float(want[slot]) + 180.0, 360.0) - 180.0) > 0.5:
			all_ok = false
			print("      槽 %d 弧心 %.1f°，文档要 %.1f°" % [slot + 1, deg, want[slot]])
	ok("槽位攻击弧心与 §6.4 的角度表一致", all_ok)

	# 转 90° 后，角落槽的弧应该正好落到下一个角落槽原来的位置（对称性）
	var corner = Turret.new("gun", Vector2i(0, 0), 1, 1)
	var before: float = m.slot_arc_center(corner)
	m.rot = PI * 0.5
	ok("旋转 90° 后角落槽弧心 = 原来的下一个角落槽",
		absf(wrapf(m.slot_arc_center(corner) - before - PI * 0.5, -PI, PI)) < 0.001)

	# §6.3：3×3 中心 1 格禁放；4×4 中心 2×2 禁放 1×1，2×2 可以压住但不能整个进去
	var m3 = Mech.new(); m3.base_size = 3
	ok("3×3：中心格不能放 1×1", not m3.can_place(Vector2i(1, 1), 1))
	ok("3×3：外围 8 格都能放 1×1", m3.free_placements(1).size() == 8,
		"%d 格" % m3.free_placements(1).size())
	var m4 = Mech.new(); m4.base_size = 4
	ok("4×4：中心 4 格不能放 1×1", m4.free_placements(1).size() == 12,
		"%d 格" % m4.free_placements(1).size())
	ok("4×4：2×2 不能整个放进中心", not m4.can_place(Vector2i(1, 1), 2))
	ok("4×4：2×2 有 8 个合法位置", m4.free_placements(2).size() == 8,
		"%d 个" % m4.free_placements(2).size())
	# 四个角各放一个 2×2 正好铺满 —— 这就是终局的火力天花板
	var m5 = Mech.new(); m5.base_size = 4
	var placed := 0
	for c in [Vector2i(0,0), Vector2i(2,0), Vector2i(0,2), Vector2i(2,2)]:
		if m5.can_place(c, 2):
			m5.turrets.append(Turret.new("sniper_rifle", c, 1, 2))
			placed += 1
	ok("4×4：四角各一门 2×2 正好铺满（终局上限 4 门）",
		placed == 4 and m5.free_placements(1).is_empty(), "放下 %d 门" % placed)

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
	var t = Turret.new("gun", Vector2i(1, 0), 1, 1)

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
	for i in 45:                              # 1.5 秒，穿刺枪间隔 2.8 秒，只够打一发
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
	w.mech.turrets.append(Turret.new(weapon_id, Vector2i(1, 0), 1, 1))   # 车头正中，弧心 0°
	w.spawner._next_wave = 99999                          # 关掉刷怪，只测武器
	w.shop.leave(w)                                       # 跳过开局商店
	w.shop.next_spawn_t = 1.0e9
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
	var t2 = Turret.new("wall_of_lead", Vector2i(1, 0), 1, 2)
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
		w3.targeting.pick(6, Turret.new("gun", Vector2i(1, 0), 1, 1), [weak, nasty], c3) == nasty)

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

## ---- P5 验收：四面装甲五级树（§6.2）----
func check_armor() -> void:
	var Enemy = load("res://sim/entities/Enemy.gd")
	var w = _world_with("gun")
	var db = w.db
	var tiers: Array = db.armor_tiers()
	var cap: float = float(db.armor.get("reduce_cap", 0.45))
	var m = w.mech

	# 3 张装甲卡 → 3 级，减伤 30%
	for i in 3:
		m.add_armor(0, 0, 3, tiers.size() - 1)
	m.refresh_armor(tiers, cap)
	ok("装甲 3 级 = 减伤 30%", is_equal_approx(m.armor[0], 0.30), "%.2f" % m.armor[0])

	# 再放一张装甲卡 → 晋升尖刺 1 级，减伤 35% + 反击 20
	m.add_armor(0, 0, 3, tiers.size() - 1)
	m.refresh_armor(tiers, cap)
	ok("第 4 张装甲卡晋升尖刺 1 级：减伤 35% + 反击 20",
		m.armor_tier[0] == 1 and is_equal_approx(m.armor[0], 0.35)
		and is_equal_approx(m.armor_reflect[0], 20.0),
		"tier%d 减伤%.2f 反击%.0f" % [m.armor_tier[0], m.armor[0], m.armor_reflect[0]])
	ok("装甲卡对已经升到尖刺的那面无效", not m.armor_accepts(0, 0))

	# 一路升到滚筒 3 级，核对文档写的三个数
	for tier in range(1, tiers.size()):
		while m.armor_tier[0] == tier and m.armor_level[0] < 3:
			m.add_armor(0, tier, 3, tiers.size() - 1)
		if tier < tiers.size() - 1:
			m.add_armor(0, tier, 3, tiers.size() - 1)
	m.refresh_armor(tiers, cap)
	ok("满级旋转滚筒：减伤 45% / 反击 60 / 光环 450 每秒 / 范围 1 格",
		m.armor_tier[0] == 4 and m.armor_level[0] == 3
		and is_equal_approx(m.armor[0], 0.45) and is_equal_approx(m.armor_reflect[0], 60.0)
		and is_equal_approx(m.armor_aura[0], 450.0) and is_equal_approx(m.armor_range[0], 1.0),
		"tier%d lv%d 减伤%.2f 反击%.0f 光环%.0f 范围%.1f" % [m.armor_tier[0], m.armor_level[0],
			m.armor[0], m.armor_reflect[0], m.armor_aura[0], m.armor_range[0]])

	# 减伤真的生效：同样一击，车头（45%）比车尾（0%）少掉 45%
	var before: float = m.hp
	var e1 = Enemy.new()
	e1.pos = m.pos + Vector2(0, -m.half_size - 0.2)
	e1.attack = 100.0; e1.attack_interval = 999.0; e1.attack_cd = 0.0
	e1.speed = 0.0; e1.max_hp = 1.0e9; e1.hp = e1.max_hp
	w.enemies = [e1]
	w.combat.rebuild_hash(w.enemies)
	w.combat.update_enemies(w.enemies, m, 0.03, w.enemy_bullets, w.log)
	var took: float = before - m.hp
	ok("车头 45% 减伤：100 点打进来只掉 55", is_equal_approx(took, 55.0), "%.1f" % took)
	ok("尖刺反击：攻击者自己掉 60", is_equal_approx(e1.max_hp - e1.hp, 60.0),
		"%.0f" % (e1.max_hp - e1.hp))

	# 光环：贴在车头 1 格内的敌人每秒掉 450
	var e2 = Enemy.new()
	e2.pos = m.pos + Vector2(0, -m.half_size - 0.5)
	e2.speed = 0.0; e2.attack = 0.0; e2.max_hp = 1.0e9; e2.hp = e2.max_hp
	w.enemies = [e2]
	w.combat.rebuild_hash(w.enemies)
	w.combat.hull_contact(m, 1.0, w.log)
	ok("滚筒光环：范围内每秒 450", is_equal_approx(e2.max_hp - e2.hp, 450.0),
		"%.0f" % (e2.max_hp - e2.hp))

	# 商店里买得到装甲卡，而且只出当前那一面吃得下的级别
	var w2 = _world_with("gun")
	var avail: Array = w2.shop.pool.available(w2.mech, w2.shop.unlocked)
	var kinds := {}
	for c in avail:
		if String(c.get("kind", "weapon")) == "armor":
			kinds[int(c["tier"])] = true
	ok("商店只出 0 级装甲卡（四面都还没装）", kinds.size() == 1 and kinds.has(0),
		"出现的级别 %s" % str(kinds.keys()))

## ---- 补回 v0.2 §6.2 的两条装甲机制 ----
func check_armor_v2() -> void:
	var Enemy = load("res://sim/entities/Enemy.gd")

	# standoff：链锯起向外支出，敌人挤不进那一圈，也就够不着车体
	var w = _world_with("gun")
	var m = w.mech
	m.armor_tier[0] = 2                       # 链锯
	m.armor_level[0] = 3
	m.refresh_armor(w.db.armor_tiers(), 0.45)
	var e = Enemy.new()
	e.pos = m.pos + Vector2(0, -m.half_size - 1.2)
	e.speed = 3.0; e.attack = 100.0; e.attack_interval = 0.1
	e.max_hp = 1.0e9; e.hp = e.max_hp; e.radius = 0.3
	w.enemies = [e]
	var hp0: float = m.hp
	for i in 60:
		w.combat.rebuild_hash(w.enemies)
		w.combat.update_enemies(w.enemies, m, 1.0 / 30.0, w.enemy_bullets, w.log)
	var gap: float = w.torus.dist(m.pos, e.pos) - m.half_size
	ok("链锯 standoff：敌人被挡在支出范围外", gap > 0.45 and gap < 1.1, "%.2f 格" % gap)
	ok("standoff：够不着车体就打不到", is_equal_approx(m.hp, hp0), "掉了 %.0f" % (hp0 - m.hp))

	# 没有 standoff 的尖刺装甲，敌人能贴上来打
	var w2 = _world_with("gun")
	var m2 = w2.mech
	m2.armor_tier[0] = 1                      # 尖刺
	m2.armor_level[0] = 3
	m2.refresh_armor(w2.db.armor_tiers(), 0.45)
	var e2 = Enemy.new()
	e2.pos = m2.pos + Vector2(0, -m2.half_size - 1.2)
	e2.speed = 3.0; e2.attack = 100.0; e2.attack_interval = 0.1
	e2.max_hp = 1.0e9; e2.hp = e2.max_hp; e2.radius = 0.3
	w2.enemies = [e2]
	var hp2: float = m2.hp
	for i in 60:
		w2.combat.rebuild_hash(w2.enemies)
		w2.combat.update_enemies(w2.enemies, m2, 1.0 / 30.0, w2.enemy_bullets, w2.log)
	ok("尖刺没有 standoff：敌人贴上来能打到", m2.hp < hp2, "掉了 %.0f" % (hp2 - m2.hp))

	# 定时飞出齿轮：滚筒每 2.5 秒朝外扔一发，沿途碾过去
	var w3 = _world_with("gun")
	var m3 = w3.mech
	m3.turrets.clear()                        # 只测滚轮，别让炮塔的伤害混进来
	m3.armor_tier[0] = 4                      # 滚筒
	m3.armor_level[0] = 3
	m3.refresh_armor(w3.db.armor_tiers(), 0.45)
	var row: Array = []
	for i in 3:
		var e3 = Enemy.new()
		e3.pos = m3.pos + Vector2(0, -4.0 - float(i) * 1.5)
		e3.speed = 0.0; e3.attack = 0.0
		e3.max_hp = 1.0e9; e3.hp = e3.max_hp
		row.append(e3)
	w3.enemies = row.duplicate()
	for i in 45:                              # 1.5 秒，只够放出一发滚轮（间隔 2.5 秒）
		w3.tick()
	var hurt := 0
	for e3 in row:
		if e3.hp < e3.max_hp:
			hurt += 1
	ok("滚筒定时放出滚轮：一路碾过 3 个", hurt == 3, "碾到 %d 个" % hurt)
	ok("滚轮伤害 = 光环 450 × 3.0", is_equal_approx(row[0].max_hp - row[0].hp, 1350.0),
		"%.0f" % (row[0].max_hp - row[0].hp))
	ok("滚轮伤害记在车体那一栏", w3.log.hull_damage > 0.0)
