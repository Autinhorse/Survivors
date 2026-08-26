extends RefCounted
## 敌人实例。属性由波次算出（§4.5 的形状×成长），不再有独立的敌人表。

var wave_index: int = 0        # 第几波（从 1 数）
var wave_pos: int = 0          # 周期内第几位（1-8）
var type_name: String = ""

var pos := Vector2.ZERO
var hp: float = 1.0
var max_hp: float = 1.0
var speed: float = 1.0
var attack: float = 1.0
var attack_interval: float = 2.0
var attack_cd: float = 0.0
var radius: float = 0.35
var coin: float = 1.0

var move_kind: String = "chase"     # chase / straight
var straight_dir := Vector2.ZERO    # move_kind == straight 时固定不变
var attack_kind: String = "melee"   # melee / ranged
var attack_range: float = 0.0
var bullet_speed: float = 0.0
var hold_position: bool = false     # 远程进入射程后不再移动（§4.5 第六波）
var holding: bool = false

var alive: bool = true
