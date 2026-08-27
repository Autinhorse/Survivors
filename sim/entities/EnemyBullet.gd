extends RefCounted
## 远程敌人的子弹。不制导，朝发射瞬间的机甲位置直飞（§4.3）。

var pos := Vector2.ZERO
var vel := Vector2.ZERO
var damage: float = 1.0
var ttl: float = 8.0
var alive: bool = true
## 发射它的是周期内第几位（1-8）。伤害归因要用：远程敌人站在 9-11 格外，
## 子弹打中时离机甲最近的永远是贴脸的近战兵，按"最近的敌人"归因会把
## 远程伤害全记到近战头上。
var wave_pos: int = 0
