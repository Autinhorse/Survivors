extends RefCounted
## 一局的输入参数。批量模拟时只改这个 + data/ 里的 json。

var seed_value: int = 0
var duration_sec: float = 1800.0
var tick_hz: int = 30
var data_dir: String = "res://data"

## 自动模拟用的策略；手玩时忽略
var move_policy: String = "kite"      # kite / circle / stand
var face_policy: String = "threat"    # threat / fixed
var pick_policy: String = "dps"       # dps / armor / random

## 标签，会写进 RunLog 方便分组统计
var label: String = ""

func duplicate_cfg() -> RefCounted:
	var c = (load("res://sim/core/SimConfig.gd") as GDScript).new()
	c.seed_value = seed_value
	c.duration_sec = duration_sec
	c.tick_hz = tick_hz
	c.data_dir = data_dir
	c.move_policy = move_policy
	c.face_policy = face_policy
	c.pick_policy = pick_policy
	c.label = label
	return c
