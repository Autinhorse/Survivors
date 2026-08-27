extends RefCounted
## 移动 / 索敌 / 弹丸 / 接触伤害。所有几何都在格坐标里算，**距离一律走 Torus**。

const Projectile = preload("res://sim/entities/Projectile.gd")
const EnemyBullet = preload("res://sim/entities/EnemyBullet.gd")
const SpatialHash = preload("res://sim/core/SpatialHash.gd")

var _db = null
var _rng = null
var _torus = null
var hash := SpatialHash.new()
var targeting = null

## 弹丸飞行速度：文档没给（§7.8 只有伤害/间隔/距离），先按 30 格/秒统一，
## 快到几乎是瞬时命中，避免弹道成为隐藏变量。真要做弹道差异是 P9 的事。
const PROJECTILE_SPEED := 30.0

func setup(db, rng, torus, p_targeting) -> void:
	_db = db
	_rng = rng
	_torus = torus
	targeting = p_targeting
	hash.setup(torus, 2.0)

func rebuild_hash(enemies: Array) -> void:
	hash.rebuild(enemies)

# ---------------------------------------------------------------- 敌人

var _tick_n: int = 0
var _sep_tick: bool = false

func update_enemies(enemies: Array, mech, dt: float, bullets: Array, log_ref) -> void:
	# 分离隔帧算：每敌人每帧一次哈希查询把模拟速度从 36 倍砍到 15 倍，
	# 而这是个软约束，隔一帧推双倍的距离，看起来完全一样。
	_tick_n += 1
	_sep_tick = (_tick_n & 1) == 0

	for e in enemies:
		if not e.alive:
			continue
		var rel: Vector2 = _torus.delta(mech.pos, e.pos)   # 机甲 -> 敌人
		var dist: float = rel.length()
		var touching: bool = mech.overlaps(rel, e.radius)

		# --- 移动 ---
		if e.move_kind == "straight":
			# 生成时锁定方向，之后不再转向（§4.2 第 5 种）
			e.pos = _torus.wrap(e.pos + e.straight_dir * e.speed * dt)
		elif e.attack_kind == "ranged" and dist <= e.attack_range:
			# §4.3 的两种远程行为：
			#   hold_position —— 进入射程就钉住，主角走了也不追（第六波远程弧）
			#   keep_distance —— 主角靠近就后撤，始终保持射程（重甲炮台）。
			#     这条让"射程差"成为硬约束：射程不够的武器永远够不着它。
			if e.keep_distance and dist < e.attack_range * 0.9:
				e.pos = _torus.wrap(e.pos + rel / dist * e.speed * dt)
			elif e.hold_position:
				e.holding = true
		elif not e.holding and not touching and dist > 0.001:
			var np: Vector2 = _torus.wrap(e.pos - rel / dist * e.speed * dt)
			var nrel: Vector2 = _torus.delta(mech.pos, np)
			# 链锯/齿轮/滚筒向外支出的那一圈，敌人挤不进来（v0.2 §6.2）。
			# 于是它们被卡在光环里持续掉血，血少的还没够到车体就死了。
			var nside: int = mech.hit_side(nrel)
			var stand: float = mech.armor_standoff[nside]
			# 支出的锯齿占住这一圈，敌人的**边缘**都挤不进来，所以是 stand + radius
			if stand <= 0.0 or not mech.overlaps(nrel, stand + e.radius):
				e.pos = np

		# 敌人之间也要互相挤开（手玩反馈：一堆敌人重在同一个点上，看起来只有一个）。
		# 只挤 x/y 位置，不动速度——它们的目标始终是机甲，挤开只是排队方式。
		if _sep_tick:
			_separate(e, dt * 2.0)

		# 敌人不能陷进车体：移动之后统一挤回边上。
		# 敌人自己会在边缘停下，但**机甲开过去时会把它压进来**——这一步同时吸收
		# 单 tick 的过冲和被机甲碾压两种情况。standoff（链锯支出）也算进边界。
		rel = _clamp_outside(mech, e)
		dist = rel.length()
		touching = mech.overlaps(rel, e.radius)

		# --- 攻击 ---
		e.attack_cd -= dt
		if e.attack_cd > 0.0:
			continue
		if e.attack_kind == "ranged":
			if dist <= e.attack_range:
				e.attack_cd = e.attack_interval
				var b = EnemyBullet.new()
				b.pos = e.pos
				b.vel = -rel / maxf(dist, 0.001) * e.bullet_speed
				b.damage = e.attack
				b.ttl = e.attack_range / maxf(0.1, e.bullet_speed) + 1.0
				bullets.append(b)
		elif touching:
			e.attack_cd = e.attack_interval
			_damage_mech(mech, rel, e.attack, log_ref)
			# 尖刺及以上：敌人每次攻击这一面，自己也要吃一份（§6.2）
			var side: int = mech.hit_side(rel)
			var back: float = mech.armor_reflect[side]
			if back > 0.0:
				e.hp -= back
				log_ref.hull_damage += back
				if e.hp <= 0.0 and e.alive:
					e.alive = false
					log_ref.hull_kills += 1
					_award(e, mech, log_ref)

## 把和别人重叠的敌人推开一点。
## 用的是重建于本 tick 开头的 hash，位置略有滞后——不要紧，这是个持续的软约束，
## 下一 tick 会接着推；换成精确的成对求解只会更慢，还容易抖。
## 推力上限锁在 e.speed 以内，否则密集时敌人会被弹飞，比重叠更难看。
func _separate(e, dt: float) -> void:
	var r2: float = e.radius * 2.0
	var push := Vector2.ZERO
	var n := 0
	for o in hash.query(e.pos, r2):
		if o == e or not o.alive:
			continue
		var d: Vector2 = _torus.delta(o.pos, e.pos)      # 别人 -> 自己
		var l: float = d.length()
		if l >= r2:
			continue
		if l < 0.001:
			# 完全重合时给一个确定的方向，不能用随机数（sim 必须可复现）
			d = Vector2(0.001 * float(1 + (n & 1)), 0.001)
			l = d.length()
		push += d / l * (r2 - l)
		n += 1
		if n >= 6:                                        # 挤够 6 个就够了，省时间
			break
	if n == 0:
		return
	var step: float = minf(push.length(), e.speed * dt * 1.5)
	e.pos = _torus.wrap(e.pos + push.normalized() * step)

## 把陷进车体的敌人沿最近的那条边挤出去，返回挤完之后的相对向量
func _clamp_outside(mech, e) -> Vector2:
	var rel: Vector2 = _torus.delta(mech.pos, e.pos)
	var side: int = mech.hit_side(rel)
	# 余量要往**内**留：挤到边界外侧会被 overlaps 判成"没接触"，敌人就再也打不到机甲；
	# 挤到内侧 0.001 格则稳定判定为贴住，肉眼也看不出差别。
	var edge: float = mech.half_size + e.radius + mech.armor_standoff[side] - 0.001
	var loc: Vector2 = rel.rotated(-mech.rot)
	if absf(loc.x) >= edge or absf(loc.y) >= edge:
		return rel
	if absf(loc.x) >= absf(loc.y):
		loc.x = edge * (signf(loc.x) if not is_zero_approx(loc.x) else 1.0)
	else:
		loc.y = edge * (signf(loc.y) if not is_zero_approx(loc.y) else 1.0)
	e.pos = _torus.wrap(mech.pos + loc.rotated(mech.rot))
	return _torus.delta(mech.pos, e.pos)

func update_enemy_bullets(bullets: Array, mech, dt: float, log_ref) -> void:
	for b in bullets:
		if not b.alive:
			continue
		b.ttl -= dt
		if b.ttl <= 0.0:
			b.alive = false
			continue
		b.pos = _torus.wrap(b.pos + b.vel * dt)
		var rel: Vector2 = _torus.delta(mech.pos, b.pos)
		if mech.overlaps(rel, 0.1):
			b.alive = false
			_damage_mech(mech, rel, b.damage, log_ref)

func _damage_mech(mech, rel: Vector2, amount: float, log_ref) -> void:
	var side: int = mech.hit_side(rel)
	var taken: float = amount * (1.0 - clampf(mech.armor[side], 0.0, 0.9))
	mech.hp -= taken
	log_ref.damage_taken += taken
	log_ref.damage_by_side[side] = float(log_ref.damage_by_side[side]) + taken
	log_ref.enemy_contact_count += 1

## 齿轮/滚筒：定时朝外飞出齿轮 / 放出滚轮（v0.2 §6.2）
func armor_projectiles(mech, projectiles: Array, dt: float) -> void:
	for side in 4:
		var cfg = mech.armor_proj[side]
		if cfg == null or mech.armor_aura[side] <= 0.0:
			continue
		mech.armor_proj_cd[side] -= dt
		if mech.armor_proj_cd[side] > 0.0:
			continue
		mech.armor_proj_cd[side] = float(cfg.get("interval", 3.0))
		var n: Vector2 = mech.side_normal(side)
		var p = Projectile.new()
		p.pos = _torus.wrap(mech.pos + n * (mech.half_size + 0.2))
		p.vel = n * float(cfg.get("speed", 8.0))
		p.damage = mech.armor_aura[side] * float(cfg.get("damage_mult", 2.0))
		p.shape = "line"                       # 一路碾过去，沿途都判定
		p.line_falloff = 1.0                   # 齿轮/滚轮不衰减
		p.hit_radius = float(cfg.get("width", 0.6))
		p.ttl = float(cfg.get("range", 8.0)) / maxf(1.0, float(cfg.get("speed", 8.0)))
		p.owner_turret = null
		p.from_armor = true
		projectiles.append(p)

## 链锯/齿轮/滚筒：向外支出的那一圈里，敌人持续掉血（§6.2）
func hull_contact(mech, dt: float, log_ref) -> void:
	var reach := 0.0
	for i in 4:
		if mech.armor_aura[i] > 0.0:
			reach = maxf(reach, mech.armor_range[i])
	if reach <= 0.0:
		return
	for e in hash.query(mech.pos, mech.half_size + reach + 2.0):
		var rel: Vector2 = _torus.delta(mech.pos, e.pos)
		if not e.alive:
			continue
		var side: int = mech.hit_side(rel)
		if mech.armor_aura[side] <= 0.0:
			continue
		if not mech.overlaps(rel, e.radius + mech.armor_range[side]):
			continue
		var dmg: float = mech.armor_aura[side] * dt
		if dmg <= 0.0:
			continue
		e.hp -= dmg
		log_ref.hull_damage += dmg
		if e.hp <= 0.0 and e.alive:
			e.alive = false
			log_ref.hull_kills += 1
			_award(e, mech, log_ref)

# ---------------------------------------------------------------- 炮塔

## 有效弧 = min(槽位弧 180°, 武器弧)，弧心朝槽位外侧（§6.4）。
## 攻击距离以**机甲中心**为准（§7.6），不按每个炮塔自己的位置算。
func candidates_for(mech, t, rng_range: float) -> Array:
	var arc_center: float = mech.slot_arc_center(t)
	var half_arc := deg_to_rad(mech.SLOT_ARC_DEG) * 0.5
	var r2 := rng_range * rng_range
	var out: Array = []
	for e in hash.query(mech.pos, rng_range):
		if not e.alive:
			continue
		var rel: Vector2 = _torus.delta(mech.pos, e.pos)
		if rel.length_squared() > r2:
			continue
		if absf(wrapf(rel.angle() - arc_center, -PI, PI)) > half_arc:
			continue
		out.append(e)
	return out

func update_turrets(mech, projectiles: Array, dt: float) -> void:
	if not mech.can_fire():
		return                          # 转向中不开火（§3.3）
	for t in mech.turrets:
		# 连射中（Fragment Cannon / Wall of Lead：一次射 N 发，可以切换目标）
		if t.burst_left > 0:
			t.burst_cd -= dt
			if t.burst_cd <= 0.0:
				_shoot_once(mech, t, projectiles)
				t.burst_left -= 1
				t.burst_cd = _db.weapon_mech(t.weapon_id, "burst_gap", 0.12)
			continue
		t.cooldown -= dt
		if t.cooldown > 0.0:
			continue
		var burst: int = maxi(1, _db.weapon_burst(t.weapon_id, t.level))
		if not _shoot_once(mech, t, projectiles):
			continue                    # 没有合法目标就不进 CD，下一 tick 再找
		t.cooldown = _db.weapon_interval(t.weapon_id, t.level)
		t.burst_left = burst - 1
		t.burst_cd = _db.weapon_mech(t.weapon_id, "burst_gap", 0.12)

## 打一发。返回是否真的开火了。
func _shoot_once(mech, t, projectiles: Array) -> bool:
	var rng_range: float = _db.weapon_range(t.weapon_id, t.level)
	var cands := candidates_for(mech, t, rng_range)
	if cands.is_empty():
		return false
	var shape: String = _db.weapon_shape(t.weapon_id)
	var mode: int = _db.weapon_targeting(t.weapon_id)
	var dmg: float = _db.weapon_damage(t.weapon_id, t.level)

	if shape == "multi":
		# 多点：同时打 N 个不同目标（冰霜喷射那一类，枪系暂时没有）
		var n: int = int(_db.weapon_mech(t.weapon_id, "targets", 2.0))
		var picked: Array = []
		for i in n:
			var pool: Array = []
			for e in cands:
				if not picked.has(e):
					pool.append(e)
			var tgt = targeting.pick(mode, t, pool, mech.pos)
			if tgt == null:
				break
			picked.append(tgt)
			_spawn_projectile(mech, t, tgt, dmg, projectiles)
		return not picked.is_empty()

	var target = targeting.pick(mode, t, cands, mech.pos)
	if target == null:
		return false
	_spawn_projectile(mech, t, target, dmg, projectiles)
	return true

func _spawn_projectile(mech, t, target, dmg: float, projectiles: Array) -> void:
	var origin: Vector2 = mech.turret_world_pos(t)
	var a: float = _torus.delta(origin, target.pos).angle()
	var rng_range: float = _db.weapon_range(t.weapon_id, t.level)
	var p = Projectile.new()
	p.pos = _torus.wrap(origin)
	p.vel = Vector2(cos(a), sin(a)) * PROJECTILE_SPEED
	p.damage = dmg
	p.shape = _db.weapon_shape(t.weapon_id)
	p.aoe_radius = _db.weapon_aoe(t.weapon_id, t.level)
	p.knockback = _db.weapon_mech(t.weapon_id, "knockback", 0.0)
	p.line_falloff = _db.weapon_mech(t.weapon_id, "line_falloff", 0.2)
	p.ttl = (rng_range + 2.0) / PROJECTILE_SPEED
	p.owner_turret = t
	projectiles.append(p)

# ---------------------------------------------------------------- 弹丸

func update_projectiles(projectiles: Array, mech, dt: float, log_ref) -> void:
	for p in projectiles:
		if not p.alive:
			continue
		p.ttl -= dt
		if p.ttl <= 0.0:
			p.alive = false
			continue
		var prev: Vector2 = p.pos
		p.pos = _torus.wrap(p.pos + p.vel * dt)
		match p.shape:
			"line":
				# 线性：一路飞过去，沿途每个敌人吃 line_falloff 比例的伤害，
				# 最后撞上的那个吃满额（§7.8 穿刺枪）。飞出射程才消失。
				for e in hash.query(p.pos, p.hit_radius + 1.0):
					if not e.alive or p.hit_set.has(e):
						continue
					if _torus.dist(p.pos, e.pos) <= e.radius + p.hit_radius:
						p.hit_set.append(e)
						_hit(e, p, p.damage * p.line_falloff, mech, log_ref)
			"area":
				var target = _first_hit(p)
				if target != null:
					for e2 in hash.query(p.pos, p.aoe_radius):
						if e2.alive and _torus.dist(p.pos, e2.pos) <= p.aoe_radius:
							_hit(e2, p, p.damage, mech, log_ref)
					p.alive = false
			_:
				var target2 = _first_hit(p)
				if target2 != null:
					_hit(target2, p, p.damage, mech, log_ref)
					p.alive = false

func _first_hit(p):
	for e in hash.query(p.pos, 1.0):
		if e.alive and _torus.dist(p.pos, e.pos) <= e.radius + 0.15:
			return e
	return null

func _hit(e, p, amount: float, mech, log_ref) -> void:
	e.hp -= amount
	if p.knockback > 0.0:
		# 沿弹道方向推开（§7.8 Spread Gun 系列）
		e.pos = _torus.wrap(e.pos + p.vel.normalized() * p.knockback)
	var t = p.owner_turret
	if t != null:
		t.damage_done += amount
		log_ref.add_damage(t.weapon_id, amount)
	elif p.from_armor:
		log_ref.hull_damage += amount
	if e.hp <= 0.0 and e.alive:
		e.alive = false
		if t != null:
			t.kills += 1
			log_ref.add_kill(t.weapon_id)
		elif p.from_armor:
			log_ref.hull_kills += 1
		_award(e, mech, log_ref)

var shop = null      # 掉金币要用

func _award(e, mech, log_ref) -> void:
	if shop != null:
		shop.drop_coin(e.pos, e.coin)      # §4：死亡掉落金币，掉在地上要走过去捡
	log_ref.kills_total += 1
	var i: int = clampi(e.wave_pos - 1, 0, 7)
	log_ref.kills_by_wave_pos[i] = int(log_ref.kills_by_wave_pos[i]) + 1
