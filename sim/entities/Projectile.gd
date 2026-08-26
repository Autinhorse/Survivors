extends RefCounted

var pos := Vector2.ZERO
var vel := Vector2.ZERO
var damage: float = 1.0

var shape: String = "single"    # single / multi / area / line
var aoe_radius: float = 0.0     # shape == area
var knockback: float = 0.0      # 命中后把敌人推开几格
var line_falloff: float = 0.2   # shape == line：沿途敌人各吃这个比例的伤害
var hit_radius: float = 0.2     # 命中判定半径；齿轮/滚轮比子弹粗得多
var hit_set: Array = []         # shape == line：已经打过的敌人，避免重复结算

var ttl: float = 2.0
var owner_turret = null         # Turret，用于按武器统计伤害
var from_armor: bool = false    # 齿轮/滚轮：伤害记到车体那一栏，不记到武器
var alive: bool = true
