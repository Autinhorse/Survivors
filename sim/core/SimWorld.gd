extends RefCounted
## 一局的全部状态与规则。**这里不许出现 Node、get_tree()、randf()、engine delta。**
## 只有固定步长 tick(dt)：手玩用累加器按 30Hz 喂，批量模拟用 while 死循环喂，
## 同一个 seed 两边必须跑出一模一样的结果。

const Rng = preload("res://sim/core/Rng.gd")
const Torus = preload("res://sim/core/Torus.gd")
const DataDB = preload("res://sim/data/DataDB.gd")
const Mech = preload("res://sim/entities/Mech.gd")
const Turret = preload("res://sim/entities/Turret.gd")
const SpawnDirector = preload("res://sim/systems/SpawnDirector.gd")
const CombatSystem = preload("res://sim/systems/CombatSystem.gd")
const ShopSystem = preload("res://sim/systems/ShopSystem.gd")
const Targeting = preload("res://sim/systems/Targeting.gd")
const MapEval = preload("res://sim/systems/MapEval.gd")
const RunLog = preload("res://sim/telemetry/RunLog.gd")

var cfg = null
var db = null
var rng = null
var agent = null
var torus = null

var mech = null
var enemies: Array = []
var projectiles: Array = []
var enemy_bullets: Array = []

var spawner = null
var combat = null
var targeting = null
var map_eval = null
var shop = null
var log = null

var time: float = 0.0
var dt: float = 1.0 / 30.0
var over: bool = false

var view_w: float = 48.0
var view_h: float = 27.0

## 商店开着时世界暂停（§8：进入商店不占游戏时间）
var pending_options: Array = []      # 兼容旧接口，恒空

func setup(p_cfg, p_agent, p_db = null) -> void:
	cfg = p_cfg
	agent = p_agent
	db = p_db if p_db != null else DataDB.load_from(cfg.data_dir)
	rng = Rng.new(cfg.seed_value)
	dt = 1.0 / float(cfg.tick_hz)

	torus = Torus.new(db.cfg("map/width", 200.0), db.cfg("map/height", 100.0),
		bool(db.balance.get("map", {}).get("wrap_x", true)),
		bool(db.balance.get("map", {}).get("wrap_y", true)))
	view_w = db.cfg("map/view_width", 48.0)
	view_h = db.cfg("map/view_height", 27.0)

	mech = Mech.new()
	mech.pos = Vector2(torus.w, torus.h) * 0.5
	mech.max_hp = db.cfg("mech/max_hp", 1000.0)
	mech.hp = mech.max_hp
	mech.move_speed = db.cfg("mech/move_speed", 2.0)
	mech.turn_seconds = db.cfg("mech/turn_seconds", 1.0)
	mech.base_size = 3
	mech.turrets.append(Turret.new(
		String(db.balance.get("mech", {}).get("start_weapon", "gun")),
		Vector2i(1, 0), 1, 1))          # 车头正中
	mech.refresh_armor(db.armor_tiers(), float(db.armor.get("reduce_cap", 0.45)))

	spawner = SpawnDirector.new()
	spawner.setup(db, rng, torus)
	map_eval = MapEval.new()
	map_eval.setup(db, torus)
	targeting = Targeting.new()
	targeting.setup(torus)
	targeting.map_eval = map_eval
	combat = CombatSystem.new()
	shop = ShopSystem.new()
	shop.setup(db, rng, torus)
	combat.setup(db, rng, torus, targeting)
	combat.shop = shop

	log = RunLog.new()
	log.seed_value = cfg.seed_value
	log.label = cfg.label
	log.move_policy = cfg.move_policy
	log.pick_policy = cfg.pick_policy
	log.pick(0.0, "start+" + mech.turrets[0].weapon_id)
	shop.open_initial(self)          # §8.6：开局就在商店保护罩里，买够再出发

func tick(step: float = -1.0) -> void:
	if over:
		return
	var d := dt if step < 0.0 else step
	if shop.open:
		_run_shop()
		if shop.open:
			return   # 商店界面开着，游戏时间不走（§8）
	time += d

	var input: Dictionary = agent.get_input(self)
	_move_mech(input, d)

	combat.rebuild_hash(enemies)
	map_eval.maybe_evaluate(self)      # 1 Hz，索敌 5/6 和 AI 都读它（§7.6）
	spawner.tick(time, d, enemies, mech.pos)
	combat.update_enemies(enemies, mech, d, enemy_bullets, log)
	combat.update_enemy_bullets(enemy_bullets, mech, d, log)
	combat.hull_contact(mech, d, log)
	combat.update_turrets(mech, projectiles, d)
	combat.update_projectiles(projectiles, mech, d, log)
	shop.collect(mech, d, log)
	shop.tick(self, d)
	_cull()

	_sample_behavior(d)
	log.peak_enemies = maxi(log.peak_enemies, enemies.size())
	log.wave_reached = maxi(log.wave_reached, spawner.current_wave())
	if mech.hp <= 0.0:
		_finish("died")
	elif time >= cfg.duration_sec:
		_finish("survived")

## AI 是不是像人，靠这两个量和手玩对拍（见 docs/Demo3_数值验证_工程说明.md）
func _sample_behavior(d: float) -> void:
	var nearest := INF
	var touched := false
	for e in combat.hash.query(mech.pos, 6.0):
		if not e.alive:
			continue
		var rel: Vector2 = torus.delta(mech.pos, e.pos)
		nearest = minf(nearest, maxf(0.0, rel.length() - e.radius - mech.half_size))
		if not touched and mech.overlaps(rel, e.radius):
			touched = true
	if touched:
		log.time_contacted += d
	if nearest < INF:
		log.nearest_sum += nearest
		log.nearest_n += 1

## 商店里的一步一步交给 agent 决定；手玩时 agent 返回 wait，等 UI 点
func _run_shop() -> void:
	var guard := int(db.shop.get("ai", {}).get("max_actions_per_visit", 40))
	while shop.open and guard > 0:
		guard -= 1
		var act: Dictionary = agent.shop_step(self, shop)
		if act.is_empty() or String(act.get("type", "")) == "wait":
			return
		_apply_shop(act)
	if guard <= 0 and shop.open:
		shop.leave(self)      # 兜底：别让 AI 在店里死循环

func _apply_shop(act: Dictionary) -> void:
	match String(act.get("type", "")):
		"buy":     shop.buy(mech, int(act.get("index", 0)))
		"place":
			if shop.place(mech, int(act.get("index", 0)), int(act.get("side", -1))):
				log.pick(time, "place+" + String(act.get("id", "")))
		"merge":
			if shop.merge(mech, int(act.get("a", 0)), int(act.get("b", 0)), String(act.get("choice", ""))):
				log.pick(time, "merge+" + String(act.get("choice", "")))
				log.merge_count += 1
		"line":
			if shop.resolve_line_choice(mech, String(act.get("choice", ""))):
				log.pick(time, "merge+" + String(act.get("choice", "")))
				log.merge_count += 1
		"sell_card":   shop.sell_card(mech, int(act.get("index", 0)))
		"sell_turret": shop.sell_turret(mech, int(act.get("index", 0)))
		"refresh":     shop.do_refresh(mech)
		"leave":       shop.leave(self)

func _move_mech(input: Dictionary, d: float) -> void:
	var mv: Vector2 = input.get("move", Vector2.ZERO)
	if mv.length() > 0.01:
		var before: Vector2 = mech.pos
		mech.pos = torus.wrap(mech.pos + mv.normalized() * mech.move_speed * d)
		log.distance_moved += torus.dist(before, mech.pos)
	else:
		log.time_stationary += d
	var turn: int = int(input.get("turn", 0))
	if turn != 0 and mech.request_turn(turn):
		log.rotation_count += 1
	if mech.turning:
		log.time_turning += d
	mech.advance_turn(d)

func _cull() -> void:
	var alive_e: Array = []
	for e in enemies:
		if e.alive:
			alive_e.append(e)
	enemies = alive_e
	var alive_p: Array = []
	for p in projectiles:
		if p.alive:
			alive_p.append(p)
	projectiles = alive_p
	var alive_b: Array = []
	for b in enemy_bullets:
		if b.alive:
			alive_b.append(b)
	enemy_bullets = alive_b

func _finish(result: String) -> void:
	over = true
	log.result = result
	log.run_duration = time
	log.player_level = mech.level
	log.coins_left = mech.coins
	log.shop_visits = shop.visits
	log.best_column = _best_column()
	var ids: Array = []
	for t in mech.turrets:
		ids.append("%s@%d" % [t.weapon_id, t.level])
	ids.sort()
	log.final_build = " ".join(ids)

func _best_column() -> int:
	var best := 0
	for t in mech.turrets:
		best = maxi(best, db.weapon_column(t.weapon_id))
	return best

## 批量模拟：一口气跑到结束，返回 RunLog
func run_to_end(max_ticks: int = 400000):
	var n := 0
	while not over and n < max_ticks:
		tick()
		n += 1
	if not over:
		_finish("timeout")
	return log
