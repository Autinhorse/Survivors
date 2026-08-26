extends RefCounted
## 机甲平台（§6）。底座是 3×3 或 4×4 的格盘，炮塔占 1×1 或 2×2。
## 局部坐标系：+x 右、+y 下，rot=0 表示车头朝北。世界向量 = 局部向量.rotated(rot)。
##
## 槽位不再是写死的 8 个偏移，而是「格盘里的一个格子 + 尺寸」——
## 因为 §7.2 从狙击枪那一列起炮塔占 2×2，同时 §6.3 底座会从 3×3 升到 4×4。
## 攻击弧心 = 炮塔中心相对底座中心的方向（§6.4 的角度表就是这么来的，实测对得上）。

const Torus = preload("res://sim/core/Torus.gd")

const SLOT_ARC_DEG := 180.0

var base_size: int = 3
var pos := Vector2.ZERO
var rot: float = 0.0              # 当前朝向（弧度），转向过程中连续变化
var facing_dir: int = 0           # 0=北 1=东 2=南 3=西
var turn_target: int = 0
var turning: bool = false

var hp: float = 1000.0
var max_hp: float = 1000.0
var move_speed: float = 2.0
var turn_seconds: float = 1.0

## 四面装甲（§6.2），索引是**局部**方向 0=车头 1=右 2=车尾 3=左。
## 每面独立升级：tier 0-4（装甲/尖刺/链锯/齿轮/滚筒），每级 1-3。
var armor_tier := [0, 0, 0, 0]
var armor_level := [0, 0, 0, 0]
## 下面四个是从 tier/level 算出来的派生值，由 refresh_armor() 刷新
var armor := [0.0, 0.0, 0.0, 0.0]            # 减伤比例
var armor_reflect := [0.0, 0.0, 0.0, 0.0]    # 敌人每次攻击这一面自己受到的伤害
var armor_aura := [0.0, 0.0, 0.0, 0.0]       # 范围内每秒伤害
var armor_range := [0.0, 0.0, 0.0, 0.0]      # 向外支出几格
var armor_standoff := [0.0, 0.0, 0.0, 0.0]   # >0 表示敌人被挡在这么远，够不着车体就打不到
var armor_proj_cd := [0.0, 0.0, 0.0, 0.0]    # 定时飞出齿轮/滚轮的冷却
var armor_proj := [null, null, null, null]   # 对应那一级的 projectile 配置

var turrets: Array = []           # Array[Turret]，每个带 cell 和 size
var level: int = 1
var xp: float = 0.0
var coins: float = 0.0
var upgrade_levels: Dictionary = {}

var half_size: float:
	get:
		return float(base_size) * 0.5

## 按 data/armor.json 重算四面的派生值。装完卡就要调一次。
func refresh_armor(tiers: Array, cap: float) -> void:
	for i in 4:
		var lv: int = armor_level[i]
		if lv <= 0:
			armor[i] = 0.0
			armor_reflect[i] = 0.0
			armor_aura[i] = 0.0
			armor_range[i] = 0.0
			armor_standoff[i] = 0.0
			armor_proj[i] = null
			continue
		var t: Dictionary = tiers[clampi(armor_tier[i], 0, tiers.size() - 1)]
		armor[i] = minf(cap, float(t.get("reduce_base", 0.0))
			+ float(t.get("reduce_per_level", 0.0)) * float(lv))
		armor_reflect[i] = float(t.get("reflect_base", 0.0)) + float(t.get("reflect_per_level", 0.0)) * float(lv)
		armor_aura[i] = float(t.get("aura_base", 0.0)) + float(t.get("aura_per_level", 0.0)) * float(lv)
		armor_range[i] = float(t.get("aura_range", 0.0))
		# v0.2 §6.2：链锯起"向外支出"，敌人被挡在支出范围外，够不着车体自然打不到
		armor_standoff[i] = armor_range[i] if bool(t.get("standoff", false)) else 0.0
		armor_proj[i] = t.get("projectile", null)

## 这一面朝外的法线（世界方向）。定时弹朝这个方向飞
const SIDE_NORMAL := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]
func side_normal(side: int) -> Vector2:
	return SIDE_NORMAL[side].rotated(rot)

## 这一面能不能吃下 tier 级的卡（§6.2：只能一级一级来）
func armor_accepts(side: int, tier: int) -> bool:
	return armor_tier[side] == tier or (armor_level[side] == 0 and tier == 0)

## 装一张 tier 级的装甲卡。3 级满了再放一张同级卡就晋升下一级
func add_armor(side: int, tier: int, levels_per_tier: int, max_tier: int) -> bool:
	if not armor_accepts(side, tier):
		return false
	if armor_level[side] < levels_per_tier:
		armor_level[side] += 1
	elif armor_tier[side] < max_tier:
		armor_tier[side] += 1
		armor_level[side] = 1
	else:
		return false
	return true

## 中心禁区：3×3 是中间 1 格，4×4 是中间 2×2（§6.1 / §6.3）
func _center_cells() -> Array:
	if base_size == 3:
		return [Vector2i(1, 1)]
	return [Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 1), Vector2i(2, 2)]

func _in_center(c: Vector2i) -> bool:
	return _center_cells().has(c)

## 炮塔中心相对底座中心的偏移（单位：格）
func turret_offset(t) -> Vector2:
	return Vector2(t.cell) + Vector2(t.size, t.size) * 0.5 - Vector2(base_size, base_size) * 0.5

func turret_world_pos(t) -> Vector2:
	return pos + turret_offset(t).rotated(rot)

## 攻击弧心（世界角度）：朝外，角落槽指对角线（§6.4）
func slot_arc_center(t) -> float:
	return turret_offset(t).angle() + rot

func cells_of(t) -> Array:
	var out: Array = []
	for dy in t.size:
		for dx in t.size:
			out.append(t.cell + Vector2i(dx, dy))
	return out

func occupied() -> Array:
	var out: Array = []
	for t in turrets:
		out.append_array(cells_of(t))
	return out

## 这个位置能不能放下尺寸为 size 的炮塔（§6.3）
func can_place(cell: Vector2i, size: int) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x + size > base_size or cell.y + size > base_size:
		return false
	var occ := occupied()
	var all_center := true
	for dy in size:
		for dx in size:
			var c := cell + Vector2i(dx, dy)
			if occ.has(c):
				return false
			if not _in_center(c):
				all_center = false
	# 1×1 不能进中心禁区；2×2 可以压住中心，但不能整个放进去
	if size == 1:
		return not all_center
	return not all_center

func free_placements(size: int) -> Array:
	var out: Array = []
	for y in base_size:
		for x in base_size:
			var c := Vector2i(x, y)
			if can_place(c, size):
				out.append(c)
	return out

## 底座 3×3 → 4×4（§6.3）。角上的炮塔留在角上，边中的挪到对应边的第一个新格。
func upgrade_base() -> bool:
	if base_size != 3:
		return false
	base_size = 4
	const REMAP := {
		Vector2i(0, 0): Vector2i(0, 0), Vector2i(1, 0): Vector2i(1, 0), Vector2i(2, 0): Vector2i(3, 0),
		Vector2i(0, 1): Vector2i(0, 1), Vector2i(2, 1): Vector2i(3, 1),
		Vector2i(0, 2): Vector2i(0, 3), Vector2i(1, 2): Vector2i(1, 3), Vector2i(2, 2): Vector2i(3, 3),
	}
	for t in turrets:
		t.cell = REMAP.get(t.cell, t.cell)
	return true

# ---------------------------------------------------------------- 转向

## 转向过程中炮塔不开火（§3.3）
func can_fire() -> bool:
	return not turning

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

# ---------------------------------------------------------------- 车体

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
