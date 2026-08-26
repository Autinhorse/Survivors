extends RefCounted
## 六种索敌方式（§7.7）。索敌策略本身就是武器特征——文档里"加特林打血最少的、
## 狙击枪打血最多的"就是靠这个区分的，不是靠伤害数字。
##
## 5、6 号要读 P4 的地图状态评估（§7.6）；那一层还没做，暂时退化成 1 号并在
## 加载时报警，免得悄悄地把两种武器变成同一种。

const NEAREST := 1
const NEAREST_LOCK := 2
const LOWEST_HP := 3
const HIGHEST_HP := 4
const BEST_AOE := 5
const BIGGEST_THREAT := 6

var _torus = null
var map_eval = null            # P4 接上以后从这里读

func setup(torus) -> void:
	_torus = torus

## 返回目标敌人；没有合法目标返回 null。
## candidates 由调用方用空间哈希 + 弧限制筛过。
func pick(mode: int, turret, candidates: Array, mech_pos: Vector2):
	match mode:
		NEAREST_LOCK:
			# 锁定：上一个目标还活着、还在范围内，就继续打它
			if turret.locked_target != null and turret.locked_target.alive \
					and candidates.has(turret.locked_target):
				return turret.locked_target
			var t = _nearest(candidates, mech_pos)
			turret.locked_target = t
			return t
		LOWEST_HP:
			return _by_hp(candidates, mech_pos, true)
		HIGHEST_HP:
			return _by_hp(candidates, mech_pos, false)
		BEST_AOE, BIGGEST_THREAT:
			if map_eval != null:
				return map_eval.pick_for(mode, turret, candidates, mech_pos)
			return _nearest(candidates, mech_pos)    # P4 之前退化成 1 号
		_:
			return _nearest(candidates, mech_pos)

## 最近；距离相同的打血少的（§7.7 第 1 条）
func _nearest(candidates: Array, mech_pos: Vector2):
	var best = null
	var best_d := INF
	for e in candidates:
		var d: float = _torus.dist_sq(mech_pos, e.pos)
		if d < best_d - 0.0001 or (absf(d - best_d) <= 0.0001 and best != null and e.hp < best.hp):
			best_d = d
			best = e
	return best

## 血量最低/最高；血量相同的打近的（§7.7 第 3、4 条）
func _by_hp(candidates: Array, mech_pos: Vector2, lowest: bool):
	var best = null
	var best_hp := INF if lowest else -INF
	var best_d := INF
	for e in candidates:
		var better: bool = (e.hp < best_hp) if lowest else (e.hp > best_hp)
		if better:
			best_hp = e.hp
			best_d = _torus.dist_sq(mech_pos, e.pos)
			best = e
		elif is_equal_approx(e.hp, best_hp):
			var d: float = _torus.dist_sq(mech_pos, e.pos)
			if d < best_d:
				best_d = d
				best = e
	return best
