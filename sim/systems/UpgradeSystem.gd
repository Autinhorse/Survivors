extends RefCounted
## 升级：经验够了就发三选一（文档 §22 Phase 1）。
## 文档 §8 的金币商店以后接进来时，只需要换掉这里的「发牌来源」，规则和 UI 不动。

const Turret = preload("res://sim/entities/Turret.gd")

var _db = null
var _rng = null

func setup(db, rng) -> void:
	_db = db
	_rng = rng

func xp_to_next(level: int) -> float:
	return _db.cfg("xp/base", 5.0) * pow(float(level), _db.cfg("xp/exp", 1.35))

func ready_to_level(mech) -> bool:
	return mech.xp >= xp_to_next(mech.level)

func consume_level(mech) -> void:
	mech.xp -= xp_to_next(mech.level)
	mech.level += 1

## 生成候选牌。返回 Array[Dictionary]
func draw_options(mech) -> Array:
	var pool: Array = []
	var weights: Array = []
	var new_w := float(_db.draw_cfg.get("new_turret_weight", 1.5))
	var lvl_w := float(_db.draw_cfg.get("turret_level_weight", 1.4))

	for slot in mech.free_slots():
		for wid in _db.tier1_weapons():
			pool.append({"type": "new_turret", "weapon_id": wid, "slot": slot,
				"text": "新炮塔：%s（槽 %d）" % [_db.weapon_name(wid), slot]})
			weights.append(new_w)

	for i in mech.turrets.size():
		var t = mech.turrets[i]
		if t.level >= _db.weapon_max_level(t.weapon_id):
			continue
		pool.append({"type": "turret_level", "index": i,
			"text": "%s Lv%d → Lv%d" % [_db.weapon_name(t.weapon_id), t.level, t.level + 1]})
		weights.append(lvl_w)

	const SIDE_NAME := ["车头", "右舷", "车尾", "左舷"]
	for u in _db.upgrades:
		var uid := String(u.get("id", ""))
		if bool(u.get("per_side", false)):
			for side in 4:
				var key := "%s:%d" % [uid, side]
				if int(mech.upgrade_levels.get(key, 0)) >= int(u.get("max_level", 5)):
					continue
				pool.append({"type": "hull", "id": uid, "side": side, "key": key,
					"text": "%s·%s +1" % [String(u.get("name", uid)), SIDE_NAME[side]]})
				weights.append(float(u.get("weight", 1.0)))
		else:
			if int(mech.upgrade_levels.get(uid, 0)) >= int(u.get("max_level", 5)):
				continue
			pool.append({"type": "hull", "id": uid, "side": -1, "key": uid,
				"text": "%s +1" % String(u.get("name", uid))})
			weights.append(float(u.get("weight", 1.0)))

	var want := int(_db.draw_cfg.get("options", 3))
	var out: Array = []
	while out.size() < want and not pool.is_empty():
		var i: int = _rng.pick_weighted(weights)
		out.append(pool[i])
		pool.remove_at(i)
		weights.remove_at(i)
	return out

func apply(mech, opt: Dictionary, now: float, log_ref) -> void:
	match String(opt.get("type", "")):
		"new_turret":
			var t = Turret.new(String(opt["weapon_id"]), int(opt["slot"]), 1)
			mech.turrets.append(t)
			log_ref.pick(now, "turret+" + String(opt["weapon_id"]))
		"turret_level":
			var tt = mech.turrets[int(opt["index"])]
			tt.level += 1
			log_ref.pick(now, "lv+" + tt.weapon_id)
		"hull":
			var uid := String(opt["id"])
			var key := String(opt["key"])
			mech.upgrade_levels[key] = int(mech.upgrade_levels.get(key, 0)) + 1
			var def: Dictionary = {}
			for u in _db.upgrades:
				if String(u.get("id", "")) == uid:
					def = u
					break
			var v := float(def.get("value", 0.0))
			var side := int(opt.get("side", -1))
			match String(def.get("kind", "")):
				"armor_side":
					mech.armor[side] = minf(0.9, mech.armor[side] + v)
				"contact_damage":
					mech.contact_damage[side] += v
				"move_speed":
					mech.move_speed += v
				"max_hp":
					mech.max_hp += v
					mech.hp += v
				"turn_speed":
					mech.turn_seconds = maxf(0.2, mech.turn_seconds - v)
			log_ref.pick(now, key)
