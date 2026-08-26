extends RefCounted
## 一局的遥测（文档 §23）。手玩和批量模拟落的是同一张表，才能横向比。
## 还没实现的系统（融合/终极）字段先留着并输出 0，免得以后改表头。

var seed_value: int = 0
var label: String = ""
var move_policy: String = ""
var pick_policy: String = ""

var run_duration: float = 0.0
var result: String = "survived"      # survived / died / timeout
var wave_reached: int = 0
var player_level: int = 1

var weapon_pick_history: Array = []  # ["12.3|turret+weapon_cannon", ...]
var first_turret_time: float = -1.0
var first_fusion_time: float = -1.0  # 未实现（P9）
var fusion_count: int = 0            # 未实现（P9）
var first_ultimate_time: float = -1.0  # 未实现（P8）
var ultimate_count: int = 0
var ultimate_active_seconds: float = 0.0
var power_window_ratio: float = 0.0

var distance_moved: float = 0.0
var rotation_count: int = 0
var time_stationary: float = 0.0
var time_turning: float = 0.0        # 转向中不开火，这段时间是纯损失（§3.3）
var time_contacted: float = 0.0      # 有敌人贴住车体的时长——AI 躲得好不好看这个
var nearest_sum: float = 0.0         # 最近敌人距离的累计，除以采样数得平均
var nearest_n: int = 0

var kills_total: int = 0
var kills_by_weapon: Dictionary = {}
var damage_by_weapon: Dictionary = {}
var kills_by_wave_pos := [0, 0, 0, 0, 0, 0, 0, 0]   # 周期内第 1-8 位各杀了多少

var enemy_contact_count: int = 0
var damage_taken: float = 0.0
var damage_by_side := [0.0, 0.0, 0.0, 0.0]          # 局部 0=车头 1=右 2=车尾 3=左
var hull_kills: int = 0
var hull_damage: float = 0.0

var coins_earned: float = 0.0
var coins_left: float = 0.0
var peak_enemies: int = 0

func pick(now: float, what: String) -> void:
	weapon_pick_history.append("%.1f|%s" % [now, what])
	if first_turret_time < 0.0 and what.begins_with("turret+"):
		first_turret_time = now

func add_kill(weapon_id: String) -> void:
	kills_by_weapon[weapon_id] = int(kills_by_weapon.get(weapon_id, 0)) + 1

func add_damage(weapon_id: String, amount: float) -> void:
	damage_by_weapon[weapon_id] = float(damage_by_weapon.get(weapon_id, 0.0)) + amount

const COLUMNS := [
	"seed", "label", "move_policy", "pick_policy", "result", "run_duration", "wave_reached",
	"player_level", "kills_total", "damage_taken", "enemy_contact_count",
	"hull_kills", "hull_damage", "distance_moved", "rotation_count",
	"time_stationary", "time_turning", "time_contacted", "avg_nearest", "peak_enemies",
	"coins_earned", "coins_left", "damage_by_side", "kills_by_wave_pos",
	"first_turret_time", "first_fusion_time", "fusion_count", "first_ultimate_time",
	"ultimate_count", "ultimate_active_seconds", "power_window_ratio",
	"kills_by_weapon", "damage_by_weapon", "picks",
]

static func csv_header() -> String:
	return ",".join(COLUMNS)

func csv_row() -> String:
	var v: Array = [
		seed_value, label, move_policy, pick_policy, result,
		"%.2f" % run_duration, wave_reached, player_level, kills_total,
		"%.1f" % damage_taken, enemy_contact_count, hull_kills, "%.1f" % hull_damage,
		"%.1f" % distance_moved, rotation_count,
		"%.1f" % time_stationary, "%.1f" % time_turning, "%.1f" % time_contacted,
		"%.2f" % (nearest_sum / maxf(1.0, float(nearest_n))), peak_enemies,
		"%.0f" % coins_earned, "%.0f" % coins_left,
		_arr(damage_by_side), _arr(kills_by_wave_pos),
		"%.1f" % first_turret_time, "%.1f" % first_fusion_time, fusion_count,
		"%.1f" % first_ultimate_time, ultimate_count,
		"%.1f" % ultimate_active_seconds, "%.3f" % power_window_ratio,
		_kv(kills_by_weapon), _kv(damage_by_weapon), "|".join(weapon_pick_history),
	]
	assert(v.size() == COLUMNS.size())
	var parts: Array = []
	for x in v:
		parts.append(str(x))
	return ",".join(parts)

func _arr(a: Array) -> String:
	var parts: Array = []
	for x in a:
		parts.append("%.0f" % float(x))
	return "|".join(parts)

func _kv(d: Dictionary) -> String:
	var parts: Array = []
	var keys := d.keys()
	keys.sort()
	for k in keys:
		parts.append("%s:%s" % [k, d[k]])
	return " ".join(parts)
