extends RefCounted
## 3x3 机甲平台。中心是控制核心，外围 8 格放炮塔（文档 §6.1）。
## 局部坐标系：+x 右、+y 下，rot=0 表示车头朝北。世界向量 = 局部向量.rotated(rot)。

const Grid = preload("res://sim/core/Grid.gd")

## 8 个槽位的局部偏移（格）。角落 4 个、边中 4 个，攻击弧不同（§6.4）。
const SLOT_OFFSETS := [
	Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1),
	Vector2(-1, 0),                  Vector2(1, 0),
	Vector2(-1, 1),  Vector2(0, 1),  Vector2(1, 1),
]
const SLOT_COUNT := 8
const SLOT_ARC_DEG := 180.0

var pos := Vector2.ZERO
var rot: float = 0.0            # 当前朝向（弧度），转向过程中连续变化
var facing_dir: int = Grid.DIR_N  # 当前锁定的 90° 朝向
var turn_target: int = Grid.DIR_N
var turning: bool = false

var hp: float = 1000.0
var max_hp: float = 1000.0
var move_speed: float = 2.0
var turn_seconds: float = 1.0
var half_size: float = 1.5

## 四面装甲，索引是**局部**方向 0=车头 1=右 2=车尾 3=左（§6.1/§20.4）
var armor := [0.0, 0.0, 0.0, 0.0]           # 减伤百分比
var contact_damage := [0.0, 0.0, 0.0, 0.0]  # 尖刺类接触伤害/秒

var turrets: Array = []   # Array[Turret]
var level: int = 1
var xp: float = 0.0
## 已吃过的强化等级，key 形如 "hull_armor:0" / "mech_speed"
var upgrade_levels: Dictionary = {}
var coins: float = 0.0

## 转向过程中炮塔不开火（§3.3）
func can_fire() -> bool:
	return not turning

func slot_taken(slot: int) -> bool:
	for t in turrets:
		if t.slot == slot:
			return true
	return false

func free_slots() -> Array:
	var out := []
	for i in SLOT_COUNT:
		if not slot_taken(i):
			out.append(i)
	return out

func turret_world_pos(t) -> Vector2:
	return pos + SLOT_OFFSETS[t.slot].rotated(rot)

## 槽位攻击弧的中心（世界角度）：朝外，角落槽指对角线
func slot_arc_center(slot: int) -> float:
	return SLOT_OFFSETS[slot].angle() + rot

func request_turn(delta_steps: int) -> bool:
	if turning or delta_steps == 0:
		return false
	turn_target = (facing_dir + delta_steps) & 3
	turning = true
	return true

func advance_turn(dt: float) -> void:
	if not turning:
		return
	var target_rot := float(turn_target) * PI * 0.5
	var step := (PI * 0.5) / maxf(0.01, turn_seconds) * dt
	var diff := wrapf(target_rot - rot, -PI, PI)
	if absf(diff) <= step:
		rot = wrapf(target_rot, -PI, PI)
		facing_dir = turn_target
		turning = false
	else:
		rot = wrapf(rot + signf(diff) * step, -PI, PI)

## 敌人打在哪一面（返回局部方向索引 0..3）。rel = torus.delta(mech.pos, 目标位置)
func hit_side(rel: Vector2) -> int:
	var local := rel.rotated(-rot)
	if absf(local.y) >= absf(local.x):
		return 0 if local.y < 0.0 else 2
	return 1 if local.x > 0.0 else 3

## 点是否在车体方框内（含半径外扩）。rel = torus.delta(mech.pos, 目标位置)
func overlaps(rel: Vector2, radius: float) -> bool:
	var local := rel.rotated(-rot)
	var r := half_size + radius
	return absf(local.x) <= r and absf(local.y) <= r
