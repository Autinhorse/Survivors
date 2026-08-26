extends RefCounted
## data/*.json 的加载与查询。数值只在 json 里，脚本里出现写死的游戏数值视为 bug。

var balance: Dictionary = {}
var weapons: Dictionary = {}
var waves_cfg: Dictionary = {}
var agents: Dictionary = {}
var shop: Dictionary = {}
var armor: Dictionary = {}
var upgrades: Array = []
var draw_cfg: Dictionary = {}

var errors: PackedStringArray = []

const IMPLEMENTED_MOVE := ["chase", "straight"]
const IMPLEMENTED_ATTACK := ["melee", "ranged"]
const IMPLEMENTED_PATTERN := ["random", "group", "circle", "line"]
const IMPLEMENTED_SHAPE := ["single", "multi", "area", "line"]
const IMPLEMENTED_TARGETING := [1, 2, 3, 4, 5, 6]

static func load_from(dir_path: String) -> RefCounted:
	var db = (load("res://sim/data/DataDB.gd") as GDScript).new()
	db.balance = db._read(dir_path + "/balance.json")
	db.weapons = db._strip_notes(db._read(dir_path + "/weapons.json"))
	db.waves_cfg = db._read(dir_path + "/waves.json")
	db.agents = db._strip_notes(db._read(dir_path + "/agents.json"))
	db.shop = db._read(dir_path + "/shop.json")
	db.armor = db._read(dir_path + "/armor.json")
	var u: Dictionary = db._read(dir_path + "/upgrades.json")
	db.upgrades = u.get("upgrades", [])
	db.draw_cfg = u.get("draw", {})
	db._validate()
	return db

func _read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		errors.append("读不到 %s" % path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s 不是合法 JSON 对象" % path)
		return {}
	return parsed

func _strip_notes(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d.keys():
		if not String(k).begins_with("_"):
			out[k] = d[k]
	return out

func _validate() -> void:
	var defs: Array = waves_cfg.get("waves", [])
	if defs.size() != int(waves_cfg.get("cycle_waves", 8)):
		errors.append("waves 条数 %d 与 cycle_waves %s 不一致" % [defs.size(), waves_cfg.get("cycle_waves")])
	for i in defs.size():
		var d: Dictionary = defs[i]
		for pair in [["move", IMPLEMENTED_MOVE], ["attack_kind", IMPLEMENTED_ATTACK],
				["pattern", IMPLEMENTED_PATTERN]]:
			var v := String(d.get(pair[0], ""))
			if not (pair[1] as Array).has(v):
				errors.append("waves[%d] 的 %s=%s 未实现" % [i, pair[0], v])
	for id in weapons.keys():
		var w: Dictionary = weapons[id]
		if not IMPLEMENTED_SHAPE.has(String(w.get("attack_shape", ""))):
			errors.append("武器 %s 的 attack_shape=%s 未实现" % [id, w.get("attack_shape")])
		var tg := int(w.get("targeting", 1))
		if not IMPLEMENTED_TARGETING.has(tg):
			errors.append("武器 %s 的索敌方式 %d 未实现" % [id, tg])
	var growth: Dictionary = waves_cfg.get("growth", {})
	for f in ["hp", "count", "attack", "coin"]:
		if float(growth.get(f, 1.0)) < 1.0:
			errors.append("growth.%s = %s < 1，会导致该项跨周期下降（设计要求只涨不跌）"
				% [f, growth.get(f)])

## 武器在某一级的实际数值。升级是**加法**增量（§7.8 的"升级：伤害+50"），
## 攻击距离那一栏是百分比（"攻击距离+5%"）。
func weapon_damage(id: String, level: int) -> float:
	var w: Dictionary = weapons.get(id, {})
	return float(w.get("damage", 0.0)) + float(w.get("upgrade", {}).get("damage", 0.0)) * float(level - 1)

func weapon_range(id: String, level: int) -> float:
	var w: Dictionary = weapons.get(id, {})
	var pct := float(w.get("upgrade", {}).get("range_pct", 0.0))
	return float(w.get("range", 0.0)) * (1.0 + pct * float(level - 1))

func weapon_interval(id: String, _level: int) -> float:
	return maxf(0.01, float(weapons.get(id, {}).get("interval", 1.0)))

func weapon_aoe(id: String, _level: int) -> float:
	return float(weapons.get(id, {}).get("aoe", 0.0))

func weapon_burst(id: String, level: int) -> int:
	var w: Dictionary = weapons.get(id, {})
	var base := int(w.get("mechanic", {}).get("burst", 1))
	return base + int(w.get("upgrade", {}).get("burst", 0)) * (level - 1)

func weapon_shape(id: String) -> String:
	return String(weapons.get(id, {}).get("attack_shape", "single"))

func weapon_targeting(id: String) -> int:
	return int(weapons.get(id, {}).get("targeting", 1))

func weapon_mech(id: String, key: String, def_value: float) -> float:
	return float(weapons.get(id, {}).get("mechanic", {}).get(key, def_value))

func weapon_name(id: String) -> String:
	return String(weapons.get(id, {}).get("name", id))

func weapon_max_level(id: String) -> int:
	return int(weapons.get(id, {}).get("max_level", 3))

func weapon_size(id: String) -> int:
	return int(weapons.get(id, {}).get("size", 1))

func armor_tiers() -> Array:
	return armor.get("tiers", [])

func armor_levels_per_tier() -> int:
	return int(armor.get("levels_per_tier", 3))

func weapon_column(id: String) -> int:
	return int(weapons.get(id, {}).get("column", 1))

## 设计时的估算 DPS，只用于调试打印，不参与规则
func weapon_dps(id: String, level: int) -> float:
	return weapon_damage(id, level) / weapon_interval(id, level) * float(maxi(1, weapon_burst(id, level)))

func tier1_weapons() -> Array:
	var out := []
	for id in weapons.keys():
		if int(weapons[id].get("tier", 1)) == 1:
			out.append(id)
	out.sort()
	return out

func cfg(path: String, def_value: float) -> float:
	## cfg("mech/move_speed", 2.0)
	var parts := path.split("/")
	var node = balance
	for p in parts:
		if typeof(node) != TYPE_DICTIONARY or not node.has(p):
			return def_value
		node = node[p]
	return float(node)
