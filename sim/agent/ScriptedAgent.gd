extends "res://sim/agent/Agent.gd"
## 自动模拟的策略。参数在 data/agents.json —— **AI 的参数本身也是被测对象**，
## 所以不能写死在这里。
##
## 移动分三层，各自的更新频率不同：
##   第 3 层 · 1 Hz  · 战略方向：直接读 §7.6 的四方向威胁，往最空的那边走
##   第 2 层 · 4 Hz  · 短程试探：四个方向各做 1 秒线性外推，算"会被多少威胁碰到"
##   第 1 层 · 每 tick · 势场微调：贴脸的敌人产生排斥力，防止在密集区里卡住
##
## 转向是**要付 1 秒零输出的离散决策**（§3.3），所以用效用比较而不是"敌人在哪边转哪边"：
## 只有 (转后火力增益 × 威胁持续时间) 大于 (停火 1 秒的损失 × (1+滞回)) 才转。
## 对称 build 下增益恒为 0，AI 自然不转 —— 这正好把"转向到底有没有用"变成可观测的数据。

const Torus = preload("res://sim/core/Torus.gd")

## 世界四方向：0=上 1=右 2=下 3=左，和 MapEval 的 dir_* 索引一致
const DIR_VEC := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]

var move_policy: String = "field"
var pick_policy: String = "dps"
var rng = null

var _p: Dictionary = {}          # 从 data/agents.json 读进来的参数
var _loaded: bool = false
var _probe_dir: int = 0
var _next_probe: float = -1.0
var _line_dir: int = 1
var _last_turn_t: float = -999.0

func _load(world) -> void:
	_loaded = true
	var cfgs: Dictionary = world.db.agents
	_p = cfgs.get(move_policy, cfgs.get("field", {}))
	if move_policy == "line":
		_line_dir = rng.range_i(0, 3) if rng != null else 1

# ---------------------------------------------------------------- 移动

func get_input(world) -> Dictionary:
	if not _loaded:
		_load(world)
	var mode := String(_p.get("move", "field"))
	var move := Vector2.ZERO
	match mode:
		"none":
			move = Vector2.ZERO
		"line":
			move = DIR_VEC[_line_dir]
		_:
			move = DIR_VEC[_field_dir(world)]
	return {"move": move, "turn": _decide_turn(world, move)}

func _field_dir(world) -> int:
	var mech = world.mech
	var torus = world.torus
	var panic: float = float(_p.get("panic_radius", 3.0))

	# 已经在保护罩里就不用躲了（§8：罩内不会被攻击）
	if world.shop.in_shield(mech, world.time) and world.shop.site != null:
		return _to_dir(torus.dir(mech.pos, world.shop.site.pos))

	# 第 1 层：贴脸的敌人直接产生排斥力，压过缓存的试探结果
	var push := Vector2.ZERO
	var close := 0
	for e in world.combat.hash.query(mech.pos, mech.half_size + panic):
		if not e.alive:
			continue
		var rel: Vector2 = torus.delta(mech.pos, e.pos)
		var d: float = rel.length()
		if d > mech.half_size + panic or d < 0.001:
			continue
		push -= rel / d / maxf(0.5, d)
		close += 1
	if close > 0 and push.length() > 0.001:
		return _to_dir(push)

	# 第 2 层：按 probe_hz 重新试探
	if world.time >= _next_probe:
		_next_probe = world.time + 1.0 / maxf(0.5, float(_p.get("probe_hz", 4.0)))
		_probe_dir = _probe(world)
	return _probe_dir

## 四个方向各做一次线性外推，选"未来会被最少威胁碰到"的那个
func _probe(world) -> int:
	var mech = world.mech
	var torus = world.torus
	var T: float = float(_p.get("lookahead_sec", 1.0))
	var predict: bool = bool(_p.get("predict_enemies", true))
	var vision: float = float(_p.get("vision", 14.0))
	var sw: float = float(_p.get("strategic_weight", 0.35))

	var pool: Array = world.enemies if vision > 500.0 else world.combat.hash.query(mech.pos, vision)

	# 第 3 层：把 §7.6 的四方向威胁折进代价里，往最空的那边偏
	var shop_dir := Vector2.ZERO
	if world.shop.site != null:
		shop_dir = torus.dir(mech.pos, world.shop.site.pos)

	# 金币掉在敌人死的地方（射程 6-8 格外），不主动去捡就攒不够进店的钱。
	# 取附近金币的加权质心；越近的权重越大，避免为了一枚远处的币横穿敌群。
	var coin_dir := Vector2.ZERO
	if float(_p.get("coin_pull", 0.0)) > 0.0:
		var acc := Vector2.ZERO
		for c in world.shop.coins:
			var rel: Vector2 = torus.delta(mech.pos, c.pos)
			var dd: float = rel.length()
			if dd > 12.0 or dd < 0.001:
				continue
			acc += rel / dd * (c.amount / maxf(1.0, dd))
		if acc.length() > 0.001:
			coin_dir = acc.normalized()

	var me = world.map_eval
	var max_threat := 0.001
	for i in 4:
		max_threat = maxf(max_threat, me.dir_threat[i])

	# 先把四个方向的威胁代价算出来，**归一化**之后再叠加商店/金币/战略的偏好。
	# 之前直接用绝对值相加，威胁项是"每个敌人 5 点 × 几百个"的量级，
	# 而商店引力最多 ±10 —— 引力被淹掉两个数量级，AI 从来没往商店走过
	# （实测最近只接近到 49.4 格，商店就在 49.5 格外）。
	var threat := PackedFloat32Array()
	threat.resize(4)
	for i in 4:
		var fut: Vector2 = torus.wrap(mech.pos + DIR_VEC[i] * mech.move_speed * T)
		var c := 0.0
		for e in pool:
			if not e.alive:
				continue
			var epos: Vector2 = e.pos
			if predict:
				if e.move_kind == "straight":
					epos = torus.wrap(e.pos + e.straight_dir * e.speed * T)
				elif not e.holding:
					epos = torus.wrap(e.pos + torus.dir(e.pos, fut) * e.speed * T)
			var dist: float = torus.dist(fut, epos)
			var reach: float = mech.half_size + e.radius + 0.2
			if e.attack_kind == "ranged":
				reach = maxf(reach, e.attack_range)
			var th: float = e.attack / maxf(0.01, e.attack_interval)
			if dist <= reach:
				c += th
			else:
				var gap: float = dist - reach
				c += th / (1.0 + gap * gap)
		threat[i] = c

	var lo := INF
	var hi := -INF
	for i in 4:
		lo = minf(lo, threat[i])
		hi = maxf(hi, threat[i])
	var span: float = maxf(0.0001, hi - lo)

	var best := 0
	var best_cost := INF
	for i in 4:
		# 归一化到 0-1，这样下面几项权重才是"相对威胁的几成"，可读也可调
		var cost: float = (threat[i] - lo) / span
		cost += sw * (me.dir_threat[i] / max_threat)
		if shop_dir != Vector2.ZERO:
			cost -= float(_p.get("shop_pull", 1.0)) * (DIR_VEC[i].dot(shop_dir) + 1.0) * 0.5
		elif coin_dir != Vector2.ZERO:
			cost -= float(_p.get("coin_pull", 0.0)) * (DIR_VEC[i].dot(coin_dir) + 1.0) * 0.5
		if cost < best_cost:
			best_cost = cost
			best = i
	return best

## 合成向量 → 最接近的 4 方向。平局按 上>右>下>左 的固定顺序打破，保证可复现
func _to_dir(v: Vector2) -> int:
	var best := 0
	var best_dot := -INF
	for i in 4:
		var d: float = v.dot(DIR_VEC[i])
		if d > best_dot + 0.000001:
			best_dot = d
			best = i
	return best

# ---------------------------------------------------------------- 转向

func _decide_turn(world, move: Vector2) -> int:
	var mode = _p.get("turn", false)
	if mode is bool and not mode:
		return 0
	var mech = world.mech
	if mech.turning:
		return 0
	if String(mode) == "follow_move":
		if move == Vector2.ZERO:
			return 0
		return _step_toward(mech.facing_dir, _to_dir(move))

	# 效用比较：转 90° 后火力覆盖变好多少，值不值 1 秒停火
	if world.time - _last_turn_t < float(_p.get("turn_min_gap", 2.0)):
		return 0
	var me = world.map_eval
	var T: float = float(_p.get("turn_expect_sec", 3.0))
	var cur := _coverage(me, 0, T)
	var cw := _coverage(me, 1, T)     # 顺时针 90°
	var ccw := _coverage(me, -1, T)
	var gain: float = maxf(cw, ccw) - cur
	if gain <= 0.0:
		return 0
	var cost: float = 0.0 if bool(_p.get("turn_cost_free", false)) \
		else cur * mech.turn_seconds
	if gain * T <= cost * (1.0 + float(_p.get("turn_hysteresis", 0.25))):
		return 0
	_last_turn_t = world.time
	return 1 if cw >= ccw else -1

## 机甲顺时针转 90°，所有槽位的弧也跟着转 90°，
## 所以"转后各方向的己方 DPS"就是把 dir_dps 循环移一位——不用重算几何。
## 超出"T 秒内清空该方向"所需的火力算浪费，不计入收益。
func _coverage(me, steps: int, T: float) -> float:
	var total := 0.0
	for i in 4:
		var dps: float = me.dir_dps[posmod(i - steps, 4)]
		var need: float = me.dir_hp[i] / maxf(0.01, T)
		total += minf(dps, need)
	return total

func _step_toward(cur_dir: int, want: int) -> int:
	var diff := posmod(want - cur_dir, 4)
	if diff == 1:
		return 1
	if diff == 3:
		return -1
	if diff == 2:
		return 1
	return 0

# ---------------------------------------------------------------- 采购（§8）

## 商店里一次走一步。两套策略：
##   rush_tree —— 一路往高级推：先合并，再优先买能推进最高列的卡
##   wide      —— 先铺满槽位：优先买能占空位的低级卡，铺满了才升级
## 没有这个，批量模拟里机甲永远停在开局那门枪上。
func shop_step(world, shop) -> Dictionary:
	var mech = world.mech

	# 1. 合并是免费的，而且按 §7.8 的数值单位面积效率总是正收益，能合就合
	# wide 流派：槽位没铺满之前不合并（合并会把两门塔并成一门，等于自断宽度）
	# wide / mix：槽位没铺满之前不合并（合并会把两门塔并成一门，等于自断宽度）
	var hold_merge: bool = (pick_policy == "wide" or pick_policy == "mix") 		and not mech.free_placements(1).is_empty()
	var ms: Array = [] if hold_merge else shop.mergeable(mech)
	if not ms.is_empty():
		var m: Dictionary = ms[0]
		var kids: Array = shop.children_of(String(m["id"]))
		var choice := ""
		if kids.size() > 1:
			choice = _prefer_line(kids)
		if not kids.is_empty():
			return {"type": "merge", "a": int(m["a"]), "b": int(m["b"]), "choice": choice}

	# 2. 保险箱里的卡能放就放
	var idx := _best_in_box(world, shop, mech)
	if idx >= 0:
		var card: Dictionary = shop.safe_box[idx]
		var side := -1
		if String(card.get("kind", "weapon")) == "armor":
			side = _worst_side(world, mech, int(card["tier"]))
		return {"type": "place", "index": idx, "id": String(card["id"]), "side": side,
			"prefer_new": pick_policy == "wide" or pick_policy == "mix"}

	# 3. 买一张买得起、而且放得下的卡
	var buy := _best_to_buy(world, shop, mech)
	if buy >= 0:
		return {"type": "buy", "index": buy}

	# 4. 没有想要的就刷新（留一点余钱，别刷到破产）
	var keep: float = _cheapest_useful(world, shop, mech)
	if shop.refresh_count < 3 and mech.coins > shop.refresh_cost() + keep:
		return {"type": "refresh"}

	return {"type": "leave"}

## 线路偏好：固定顺序，保证可复现。pick_policy 顺带当作流派开关
func _prefer_line(kids: Array) -> String:
	var order := ["rifle", "spread", "rapid"]
	if pick_policy == "spread":
		order = ["spread", "rapid", "rifle"]
	elif pick_policy == "rapid":
		order = ["rapid", "rifle", "spread"]
	for line in order:
		for k in kids:
			if String(_db_line(k)) == line:
				return String(k)
	return String(kids[0])

var _db_cache = null
func _db_line(wid: String) -> String:
	return String(_db_cache.weapons.get(wid, {}).get("line", ""))

## 装甲装在挨打最多的那一面（§6.2 装甲是按方向升级的，选错面等于没装）。
## damage_by_side 记的是**局部**方向，和装甲索引一致。
func _worst_side(world, mech, tier: int) -> int:
	var best := -1
	var best_d := -1.0
	for i in 4:
		if not mech.armor_accepts(i, tier):
			continue
		var d: float = float(world.log.damage_by_side[i])
		if d > best_d:
			best_d = d
			best = i
	return best

func _score_card(world, card: Dictionary, mech) -> float:
	if String(card.get("kind", "weapon")) == "armor":
		# armor 流派把装甲排在最前；其他流派只在便宜且顺手时买
		var base: float = 5000.0 if pick_policy == "armor" else 30.0
		return base + float(card["tier"]) * 100.0
	return _score(world, String(card["id"]), mech)

func _score(world, wid: String, mech) -> float:
	_db_cache = world.db
	var col: float = float(world.db.weapon_column(wid))
	var dps: float = world.db.weapon_damage(wid, 1) / world.db.weapon_interval(wid, 1)
	if pick_policy == "mix":
		# 设计意图是"枪族的 2-3 种配合才能过关"，不是单挑一条线推到底。
		# 所以优先补自己最缺的那条线，同一条线内再按列数推进。
		var line := String(world.db.weapons.get(wid, {}).get("line", ""))
		var have := {}
		for t in mech.turrets:
			var l := String(world.db.weapons.get(t.weapon_id, {}).get("line", ""))
			have[l] = int(have.get(l, 0)) + 1
		var mine := int(have.get(line, 0))
		var most := 0
		for k in have.keys():
			most = maxi(most, int(have[k]))
		return float(most - mine) * 1000.0 + col * 10.0 + dps * 0.001
	if pick_policy == "wide":
		# 铺满优先：能占空位的低级卡更值钱；铺满了才看伤害
		var free: bool = not mech.free_placements(world.db.weapon_size(wid)).is_empty()
		return (100.0 if free else 0.0) + col + dps * 0.001
	return col * 1000.0 + dps * 0.001        # rush_tree：越高列越优先

func _best_in_box(world, shop, mech) -> int:
	var best := -1
	var best_s := -INF
	for i in shop.safe_box.size():
		var card: Dictionary = shop.safe_box[i]
		var usable := false
		if String(card.get("kind", "weapon")) == "armor":
			usable = _worst_side(world, mech, int(card["tier"])) >= 0
		else:
			var wid := String(card["id"])
			for t in mech.turrets:
				if t.weapon_id == wid and t.level < world.db.weapon_max_level(wid):
					usable = true
					break
			if not usable and not mech.free_placements(world.db.weapon_size(wid)).is_empty():
				usable = true
		if not usable:
			continue
		var sc: float = _score_card(world, card, mech)
		if sc > best_s:
			best_s = sc
			best = i
	return best

func _best_to_buy(world, shop, mech) -> int:
	var best := -1
	var best_s := -INF
	for i in shop.cards.size():
		var c = shop.cards[i]
		if c == null or mech.coins < float(c["price"]):
			continue
		var sc: float = _score_card(world, c, mech)
		if sc > best_s:
			best_s = sc
			best = i
	return best

func _cheapest_useful(_world, shop, _mech) -> float:
	var lo := INF
	for c in shop.cards:
		if c != null:
			lo = minf(lo, float(c["price"]))
	return 0.0 if lo == INF else lo
