extends RefCounted
## 局内商店（§8）：金币掉落与拾取、商店在地图上生成、抽奖、买卡、放卡、合并、出售。
##
## 这一套取代了 P0 留下的"经验升级三选一"占位——局内成长只有金币这一条线（§5.2 / §8）。
## 商店里游戏时间不走（§8），所以 SimWorld 在 shop.open 时直接不 tick 世界。
##
## 还没做：装甲卡（§6.2 的五级树属于 P5）、拖拽 UI（§8.3，等数值验证完再说）。

const Coin = preload("res://sim/entities/Coin.gd")
const ShopSite = preload("res://sim/entities/ShopSite.gd")
const Turret = preload("res://sim/entities/Turret.gd")
const CardPool = preload("res://sim/systems/CardPool.gd")

var _db = null
var _rng = null
var _torus = null
var pool = null

var cfg: Dictionary = {}
var coins: Array = []              # 地上的金币
var site = null                    # 当前地图上的商店，没有就是 null
var open: bool = false             # 商店界面开着（世界暂停）

var cards: Array = []              # 商店卡槽，元素是卡或 null
var safe_box: Array = []           # 保险箱
var unlocked: Dictionary = {}      # 已解锁的武器 id（§7.2）
var pending_line_choice: Array = []  # 合并第 1 列时要选线路，元素是候选武器 id
var _pending_merge: Array = []

var next_spawn_t: float = 0.0
var shield_until: float = -1.0     # 出店后保护罩还能撑到什么时候
var visits: int = 0
var refresh_count: int = 0

func setup(db, rng, torus) -> void:
	_db = db
	_rng = rng
	_torus = torus
	cfg = db.shop
	pool = CardPool.new()
	pool.setup(db, rng)
	safe_box.clear()
	cards.resize(int(cfg.get("slots", {}).get("cards", 4)))
	for wid in db.weapons.keys():
		if int(db.weapons[wid].get("column", 1)) == 1:
			unlocked[wid] = true

func spawn_cfg(key: String, def_value: float) -> float:
	return float(cfg.get("spawn", {}).get(key, def_value))

# ---------------------------------------------------------------- 金币

func drop_coin(p: Vector2, amount: float) -> void:
	var c = Coin.new()
	c.pos = p
	c.amount = amount
	coins.append(c)

func collect(mech, dt: float, log_ref) -> void:
	var r: float = float(cfg.get("coin_pickup_radius", 2.0)) + mech.half_size
	var left: Array = []
	for c in coins:
		if _torus.dist(mech.pos, c.pos) <= r:
			mech.coins += c.amount
			log_ref.coins_earned += c.amount
		else:
			left.append(c)
	coins = left

# ---------------------------------------------------------------- 商店生成

func tick(world, dt: float) -> void:
	var mech = world.mech
	if site == null and not open:
		# §8：间隔到了、而且金币够买最少 2 张卡，才会出现
		if world.time >= next_spawn_t and mech.coins >= _cheapest_two(mech):
			_spawn_site(world)
	elif site != null and not open:
		if _torus.dist(mech.pos, site.pos) <= site.size * 0.5 + mech.half_size:
			_enter(world)

func in_shield(mech, now: float) -> bool:
	if now <= shield_until:
		return true
	if site == null:
		return false
	return _torus.dist(mech.pos, site.pos) <= site.shield_radius

## §8："金币足够购买最少 2 张卡牌"——2 张可以是同一种，所以是最便宜那张 ×2，
## 不是两种最便宜的卡之和。按后者算门槛会高出好几倍，商店几乎不出现。
func _cheapest_two(mech) -> float:
	var avail: Array = pool.available(mech, unlocked)
	if avail.is_empty():
		return INF
	var lo := INF
	for c in avail:
		lo = minf(lo, float(c["price"]))
	return lo * 2.0

func _spawn_site(world) -> void:
	var vw: float = world.view_w
	var vh: float = world.view_h
	var screens: float = _rng.range_f(spawn_cfg("min_screens", 1.0), spawn_cfg("max_screens", 2.0))
	var deg: float = _rng.range_f(0.0, 360.0)
	var dir := Vector2(sin(deg_to_rad(deg)), -cos(deg_to_rad(deg)))
	var dist: float = sqrt(vw * vw + vh * vh) * 0.5 * screens
	site = ShopSite.new()
	site.pos = _torus.wrap(world.mech.pos + dir * dist)
	site.size = spawn_cfg("site_size", 2.0)
	site.shield_radius = spawn_cfg("shield_radius", 5.0)

## 开局：玩家出现在商店保护罩里，必须买够再出发（§8.6）
func open_initial(world) -> void:
	site = ShopSite.new()
	site.pos = world.mech.pos
	site.size = spawn_cfg("site_size", 2.0)
	site.shield_radius = spawn_cfg("shield_radius", 5.0)
	world.mech.coins = float(cfg.get("start_coins", 200))
	_enter(world)

func _enter(world) -> void:
	open = true
	visits += 1
	refresh_count = 0
	_slot_machine(world.mech)
	_refill(world.mech, true)

func leave(world) -> void:
	open = false
	site = null
	shield_until = world.time + spawn_cfg("shield_grace_sec", 5.0)
	next_spawn_t = world.time + _rng.range_f(
		spawn_cfg("min_gap_sec", 30.0), spawn_cfg("max_gap_sec", 90.0))
	# §8.2：退出时保险箱超容量的部分自动出售
	var cap := int(cfg.get("slots", {}).get("safe_box", 8))
	while safe_box.size() > cap:
		var c = safe_box.pop_back()
		world.mech.coins += float(c["price"]) * float(cfg.get("sell_card_rate", 0.25))

# ---------------------------------------------------------------- 抽奖 / 卡槽

## §8.1：三格老虎机。三个都不同各得一张；两个相同得该种 3 张 + 另一张；三个相同得 9 张
func _slot_machine(mech) -> void:
	var avail: Array = pool.available(mech, unlocked)
	if avail.is_empty():
		return
	var w: PackedFloat32Array = pool.weights(avail, mech)
	var reels: Array = []
	for i in int(cfg.get("slots", {}).get("slot_machine", 3)):
		reels.append(pool.draw(avail, w))
	var counts := {}
	for r in reels:
		counts[r["id"]] = int(counts.get(r["id"], 0)) + 1
	for r in reels:
		var n := int(counts[r["id"]])
		var give := 1
		if n == 3:
			give = 3          # 三个格子各给 3 张 = 该种 9 张
		elif n == 2:
			give = 2          # 两个格子各给 2 张 ≈ 该种 3 张（余下那张由第三格给）
		for i in give:
			safe_box.append(r.duplicate())

func _refill(mech, all: bool = false) -> void:
	var avail: Array = pool.available(mech, unlocked)
	var w: PackedFloat32Array = pool.weights(avail, mech)
	for i in cards.size():
		if all or cards[i] == null:
			cards[i] = pool.draw(avail, w)

func refresh_cost() -> float:
	var total := 0.0
	for c in cards:
		if c != null:
			total += float(c["price"])
	return total * float(cfg.get("refresh_cost_rate", 0.2))

func do_refresh(mech) -> bool:
	var cost := refresh_cost()
	if mech.coins < cost:
		return false
	mech.coins -= cost
	refresh_count += 1
	_refill(mech, true)
	return true

func buy(mech, index: int) -> bool:
	if index < 0 or index >= cards.size() or cards[index] == null:
		return false
	var c = cards[index]
	if mech.coins < float(c["price"]):
		return false
	mech.coins -= float(c["price"])
	safe_box.append(c)
	cards[index] = null
	return true

func sell_card(mech, index: int) -> bool:
	if index < 0 or index >= safe_box.size():
		return false
	var c = safe_box[index]
	mech.coins += float(c["price"]) * float(cfg.get("sell_card_rate", 0.25))
	safe_box.remove_at(index)
	return true

## §8.7：炮塔按"总原始价格"的 25% 回收。总原始价 = 造它用掉的所有卡
func turret_cost(weapon_id: String) -> float:
	var w: Dictionary = _db.weapons.get(weapon_id, {})
	var col := int(w.get("column", 1))
	var price := float(w.get("card_price", 100))
	if col <= 1:
		return price * 3.0                       # 3 张卡到 3 级
	var parent := String((w.get("parents", ["gun"]) as Array)[0])
	return 2.0 * turret_cost(parent) + price * 2.0

func sell_turret(mech, index: int) -> bool:
	if index < 0 or index >= mech.turrets.size():
		return false
	var t = mech.turrets[index]
	mech.coins += turret_cost(t.weapon_id) * float(cfg.get("sell_turret_rate", 0.25))
	mech.turrets.remove_at(index)
	return true

# ---------------------------------------------------------------- 放卡 / 合并

## 把保险箱里第 index 张卡用掉：
## 武器卡 —— 优先升级已有炮塔，没有就放一个新的；
## 装甲卡 —— 装到指定的那一面（side < 0 时自动挑受伤最多的那面）
func place(mech, index: int, side: int = -1, prefer_new: bool = false,
		want_cell = null) -> bool:
	if index < 0 or index >= safe_box.size():
		return false
	var card: Dictionary = safe_box[index]
	if String(card.get("kind", "weapon")) == "armor":
		var tier := int(card["tier"])
		var s2 := side
		if s2 < 0 or not mech.armor_accepts(s2, tier):
			s2 = -1
			for i in 4:
				if mech.armor_accepts(i, tier):
					s2 = i
					break
		if s2 < 0:
			return false
		if not mech.add_armor(s2, tier, _db.armor_levels_per_tier(), _db.armor_tiers().size() - 1):
			return false
		mech.refresh_armor(_db.armor_tiers(), float(_db.armor.get("reduce_cap", 0.45)))
		safe_box.remove_at(index)
		return true
	var wid := String(card["id"])
	var size: int = _db.weapon_size(wid)
	# 玩家指定了格子：只在那里放新炮塔；那个位置放不下就整个动作失败，
	# 不要偷偷放到别处——手玩时"点了没反应"比"放错地方"好排查得多
	if want_cell != null:
		if not mech.can_place(want_cell, size):
			return false
		mech.turrets.append(Turret.new(wid, want_cell, 1, size))
		safe_box.remove_at(index)
		return true
	# prefer_new：先铺满空槽，铺满了才升级。
	# 之前一律"有同名塔就升级"，导致"铺宽"这条策略根本表达不出来——
	# 买 3 张卡只会把一门塔顶到 3 级，而实测宽度（8 门）比高度值钱得多。
	if prefer_new:
		var c2 = best_placement(mech, size)
		if c2 != null:
			mech.turrets.append(Turret.new(wid, c2, 1, size))
			safe_box.remove_at(index)
			return true
	for t in mech.turrets:
		if t.weapon_id == wid and t.level < _db.weapon_max_level(wid):
			t.level += 1
			safe_box.remove_at(index)
			return true
	var cell = best_placement(mech, size)
	if cell == null:
		return false
	mech.turrets.append(Turret.new(wid, cell, 1, size))
	safe_box.remove_at(index)
	return true

## 挑一个"离已有炮塔的朝向最远"的空位。
## 每个槽只覆盖 180°（§6.4），全堆在一条边上等于背面裸奔——
## 之前一律取 free_placements()[0]，两门塔都落在车头，背后一点火力都没有。
func best_placement(mech, size: int):
	var spots: Array = mech.free_placements(size)
	if spots.is_empty():
		return null
	if mech.turrets.is_empty():
		return spots[0]
	var have: Array = []
	for t in mech.turrets:
		have.append(mech.turret_offset(t).angle())
	var best = spots[0]
	var best_gap := -1.0
	for c in spots:
		var a: float = (Vector2(c) + Vector2(size, size) * 0.5
			- Vector2(mech.base_size, mech.base_size) * 0.5).angle()
		var gap := INF
		for h in have:
			gap = minf(gap, absf(wrapf(a - h, -PI, PI)))
		if gap > best_gap + 0.0001:
			best_gap = gap
			best = c
	return best

## 两个 3 级同名塔可以合并（§7.2）。第 1 列合并要先选线路
func mergeable(mech) -> Array:
	var by_id := {}
	for i in mech.turrets.size():
		var t = mech.turrets[i]
		if t.level < _db.weapon_max_level(t.weapon_id):
			continue
		if not by_id.has(t.weapon_id):
			by_id[t.weapon_id] = []
		by_id[t.weapon_id].append(i)
	var out: Array = []
	var keys: Array = by_id.keys()
	keys.sort()
	for k in keys:
		if (by_id[k] as Array).size() >= 2:
			out.append({"id": k, "a": by_id[k][0], "b": by_id[k][1]})
	return out

func children_of(weapon_id: String) -> Array:
	var out: Array = []
	for wid in _db.weapons.keys():
		var ps: Array = _db.weapons[wid].get("parents", [])
		if not ps.is_empty() and String(ps[0]) == weapon_id:
			out.append(wid)
	out.sort()
	return out

## 返回 true 表示合并完成；返回 false 且 pending_line_choice 非空表示在等玩家选线路
func merge(mech, a: int, b: int, choice: String = "") -> bool:
	if a == b or a < 0 or b < 0 or a >= mech.turrets.size() or b >= mech.turrets.size():
		return false
	var ta = mech.turrets[a]
	var tb = mech.turrets[b]
	if ta.weapon_id != tb.weapon_id:
		return false
	if ta.level < _db.weapon_max_level(ta.weapon_id) or tb.level < _db.weapon_max_level(tb.weapon_id):
		return false
	var kids := children_of(ta.weapon_id)
	if kids.is_empty():
		return false
	var child := ""
	if kids.size() == 1:
		child = kids[0]
	elif choice != "" and kids.has(choice):
		child = choice
	else:
		_pending_merge = [a, b]
		pending_line_choice = kids
		return false

	var keep_cell: Vector2i = ta.cell
	var idx := [a, b]
	idx.sort()
	mech.turrets.remove_at(idx[1])
	mech.turrets.remove_at(idx[0])

	var size: int = _db.weapon_size(child)
	if size > 1 and mech.base_size < 4:
		mech.upgrade_base()                       # §7.2：放下第一个 2×2 就升 4×4
		keep_cell = Vector2i(0, 0)
	var cell = best_placement(mech, size)
	if cell == null:
		return false
	if mech.free_placements(size).has(keep_cell) and mech.turrets.is_empty():
		cell = keep_cell
	mech.turrets.append(Turret.new(child, cell, 1, size))
	unlocked[child] = true                        # §7.2：选了线路，这张卡以后就会出现
	pending_line_choice.clear()
	_pending_merge.clear()
	return true

func resolve_line_choice(mech, choice: String) -> bool:
	if _pending_merge.size() != 2:
		return false
	return merge(mech, _pending_merge[0], _pending_merge[1], choice)
