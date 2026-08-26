extends RefCounted
## 玩家输入的唯一入口。手玩和自动模拟都走这里——两种测试跑的是同一套规则，
## 不然「模拟说这套强、手玩感觉弱」就永远说不清是规则差异还是数值问题。

## 返回 {"move": Vector2(四方向单位向量), "turn": -1/0/1}
func get_input(_world) -> Dictionary:
	return {"move": Vector2.ZERO, "turn": 0}

## 三选一，返回下标
func choose_upgrade(_world, options: Array) -> int:
	return 0 if options.size() > 0 else -1
