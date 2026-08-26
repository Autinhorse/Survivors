extends "res://sim/agent/Agent.gd"
## 手玩：view 每帧把键盘状态塞进来，选卡时挂起等 UI 回调。

var move := Vector2.ZERO
var turn: int = 0
var pending_choice: int = -1

func get_input(_world) -> Dictionary:
	var t := turn
	turn = 0   # 转向是边沿触发，读走就清
	return {"move": move, "turn": t}

## view 把玩家点的动作塞进 queued_action，没有就返回 wait 让世界继续挂着
var queued_action: Dictionary = {}

func shop_step(_world, _shop) -> Dictionary:
	if queued_action.is_empty():
		return {"type": "wait"}
	var a := queued_action
	queued_action = {}
	return a
