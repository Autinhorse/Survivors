extends "res://sim/agent/Agent.gd"
## 手玩：view 每帧把键盘状态塞进来，选卡时挂起等 UI 回调。

var move := Vector2.ZERO
var turn: int = 0
var pending_choice: int = -1

func get_input(_world) -> Dictionary:
	var t := turn
	turn = 0   # 转向是边沿触发，读走就清
	return {"move": move, "turn": t}

func choose_upgrade(_world, options: Array) -> int:
	if pending_choice >= 0 and pending_choice < options.size():
		var c := pending_choice
		pending_choice = -1
		return c
	return -1   # -1 = 还没选，SimWorld 会挂起
