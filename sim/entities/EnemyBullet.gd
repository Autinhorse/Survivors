extends RefCounted
## 远程敌人的子弹。不制导，朝发射瞬间的机甲位置直飞（§4.3）。

var pos := Vector2.ZERO
var vel := Vector2.ZERO
var damage: float = 1.0
var ttl: float = 8.0
var alive: bool = true
