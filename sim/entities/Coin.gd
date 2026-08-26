extends RefCounted
## 掉在地上的金币。环形地图上会一直留在原处，绕一圈回来还能捡（§10.1）。

var pos := Vector2.ZERO
var amount: float = 0.0
var alive: bool = true
