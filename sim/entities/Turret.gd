extends RefCounted
## 一个炮塔实例 = 武器 id + 等级 + 槽位。攻击逻辑在 CombatSystem，这里只存状态。

var weapon_id: String = ""
var level: int = 1
var slot: int = 0
var cooldown: float = 0.0

var locked_target = null        # 索敌方式 2（最近并锁定）用
var burst_left: int = 0         # 连射剩余发数（Fragment Cannon / Wall of Lead）
var burst_cd: float = 0.0

var damage_done: float = 0.0
var kills: int = 0

func _init(p_weapon: String = "", p_slot: int = 0, p_level: int = 1) -> void:
	weapon_id = p_weapon
	slot = p_slot
	level = p_level
