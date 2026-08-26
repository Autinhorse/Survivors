extends RefCounted
## 一个炮塔实例 = 武器 id + 等级 + 在底座格盘上的位置。攻击逻辑在 CombatSystem。

var weapon_id: String = ""
var level: int = 1
var cell := Vector2i.ZERO       # 占据的左上角格子
var size: int = 1               # 1×1 或 2×2（§7.2 从狙击枪那一列起是 2×2）
var cooldown: float = 0.0

var locked_target = null        # 索敌方式 2（最近并锁定）用
var burst_left: int = 0         # 连射剩余发数
var burst_cd: float = 0.0

var damage_done: float = 0.0
var kills: int = 0

func _init(p_weapon: String = "", p_cell := Vector2i.ZERO, p_level: int = 1, p_size: int = 1) -> void:
	weapon_id = p_weapon
	cell = p_cell
	level = p_level
	size = p_size
