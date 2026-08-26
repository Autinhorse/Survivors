extends RefCounted
## 商店里出什么卡、各自多大概率（§8.4）。
##
## 规则：
##   1. 先算"现在能放到底座上的卡"（放新炮塔 或 升级已有炮塔），保证出的卡都可用；
##   2. 已经装备的卡权重加倍，装了两个及以上加三倍；
##   3. 按当前有几个级别，给最高的几级设概率上限（越高级越稀有）。
##
## 上限表按"从最高级往下数"，剩下的份额都给最低级：
##   2 级：[1/8]            3 级：[1/32, 1/8]
##   4 级：[1/32, 1/16, 1/8]  5 级：[1/32, 1/16, 1/8, 1/4]

const CAPS := {
	1: [],
	2: [0.125],
	3: [0.03125, 0.125],
	4: [0.03125, 0.0625, 0.125],
	5: [0.03125, 0.0625, 0.125, 0.25],
}

var _db = null
var _rng = null

func setup(db, rng) -> void:
	_db = db
	_rng = rng

## 现在能用的武器卡。unlocked 是已经解锁的武器 id 集合（§7.2：选了线路那张卡才会出现）
func available(mech, unlocked: Dictionary) -> Array:
	var out: Array = []
	for wid in _db.weapons.keys():
		if int(_db.weapons[wid].get("column", 1)) > 1 and not unlocked.has(wid):
			continue
		var size: int = _db.weapon_size(wid)
		var can_place: bool = not mech.free_placements(size).is_empty()
		var can_level := false
		for t in mech.turrets:
			if t.weapon_id == wid and t.level < _db.weapon_max_level(wid):
				can_level = true
				break
		if not can_place and not can_level:
			continue
		out.append({
			"kind": "weapon", "id": wid,
			"column": int(_db.weapons[wid].get("column", 1)),
			"price": int(_db.weapons[wid].get("card_price", 100)),
			"name": _db.weapon_name(wid),
		})
	# 装甲卡（§6.2）：某一面能吃下这一级，这张卡才会出现。
	# column 用 tier+1，好和武器卡共用"按级别设概率上限"那套规则。
	var tiers: Array = _db.armor_tiers()
	for tier in tiers.size():
		var ok := false
		for side in 4:
			if mech.armor_accepts(side, tier):
				ok = true
				break
		if not ok:
			continue
		out.append({
			"kind": "armor", "id": "armor:%d" % tier, "tier": tier,
			"column": tier + 1,
			"price": int(tiers[tier].get("price", 50)),
			"name": String(tiers[tier].get("name", "装甲")),
		})
	out.sort_custom(func(a, b): return a["id"] < b["id"])   # 固定顺序，保证可复现
	return out

## 给每张卡算权重（已归一化，和为 1）
func weights(cards: Array, mech) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(cards.size())
	if cards.is_empty():
		return w

	# 规则 2：已装备的加权
	var own := {}
	for t in mech.turrets:
		own[t.weapon_id] = int(own.get(t.weapon_id, 0)) + 1
	# 装甲按"已经装了几面"算拥有数，套用同一条加权规则
	for side in 4:
		if mech.armor_level[side] > 0:
			var k := "armor:%d" % mech.armor_tier[side]
			own[k] = int(own.get(k, 0)) + 1
	var raw := PackedFloat32Array()
	raw.resize(cards.size())
	var cols := {}
	for i in cards.size():
		var n := int(own.get(cards[i]["id"], 0))
		raw[i] = 3.0 if n >= 2 else (2.0 if n == 1 else 1.0)
		var c := int(cards[i]["column"])
		cols[c] = float(cols.get(c, 0.0)) + raw[i]

	# 规则 3：按"现在有几个级别"给高级卡设上限
	var levels: Array = cols.keys()
	levels.sort()
	levels.reverse()                       # 从最高级往下
	var caps: Array = CAPS.get(levels.size(), [])
	var share := {}
	var used := 0.0
	for i in levels.size():
		var c: int = levels[i]
		if i < caps.size():
			share[c] = float(caps[i])
			used += float(caps[i])
		else:
			share[c] = -1.0                # 剩下的都给它（只会是最低级那一档）
	var rest: float = maxf(0.0, 1.0 - used)
	var open_levels := 0
	for c in share.keys():
		if share[c] < 0.0:
			open_levels += 1
	for c in share.keys():
		if share[c] < 0.0:
			share[c] = rest / float(maxi(1, open_levels))

	for i in cards.size():
		var c2 := int(cards[i]["column"])
		w[i] = float(share[c2]) * raw[i] / maxf(0.0001, float(cols[c2]))
	return w

## 按权重抽一张；pool 为空返回 null
func draw(cards: Array, w: PackedFloat32Array):
	if cards.is_empty():
		return null
	var total := 0.0
	for x in w:
		total += x
	if total <= 0.0:
		return cards[_rng.range_i(0, cards.size() - 1)].duplicate()
	var roll: float = _rng.f() * total
	for i in cards.size():
		roll -= w[i]
		if roll <= 0.0:
			return cards[i].duplicate()
	return cards[cards.size() - 1].duplicate()
