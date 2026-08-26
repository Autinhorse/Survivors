extends RefCounted
## 地图上的商店（§8.5）：占 2×2 格，外面套一个半径 5 的保护罩。
## 玩家碰到就进店；出来以后保护罩还能撑一小会儿。

var pos := Vector2.ZERO
var size: float = 2.0
var shield_radius: float = 5.0
var alive: bool = true
var visited: bool = false
