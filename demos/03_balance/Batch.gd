extends SceneTree
## 无美术批量模拟（文档 §10.2 第 2 种测试）。用法：
##   godot --headless --script res://demos/03_balance/Batch.gd -- runs=50 duration=600 \
##         move=kite,stand pick=dps,armor out=res://out/runs.csv label=v1
## move/pick 用逗号可以列多个策略，会跑笛卡尔积，方便一次比几套打法。

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const DataDB = preload("res://sim/data/DataDB.gd")
const ScriptedAgent = preload("res://sim/agent/ScriptedAgent.gd")
const Rng = preload("res://sim/core/Rng.gd")
const RunLog = preload("res://sim/telemetry/RunLog.gd")

func _initialize() -> void:
	var a := _args()
	var runs := int(a.get("runs", "20"))
	var seed0 := int(a.get("seed", "1000"))
	var duration := float(a.get("duration", "600"))
	var out_path := String(a.get("out", "res://out/runs.csv"))
	var label := String(a.get("label", "batch"))
	var moves: PackedStringArray = String(a.get("move", "field")).split(",")
	var picks: PackedStringArray = String(a.get("pick", "dps")).split(",")

	var db = DataDB.load_from("res://data")
	for e in db.errors:
		print("[data] ", e)

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		print("写不了 ", out_path)
		quit(1)
		return
	f.store_line(RunLog.csv_header())

	var t0 := Time.get_ticks_msec()
	var total := 0
	var sim_seconds := 0.0
	for mv in moves:
		for pk in picks:
			var survived := 0
			var sum_kills := 0.0
			var sum_time := 0.0
			var sum_level := 0.0
			var sum_stat := 0.0
			var sum_turn := 0.0
			var sum_touch := 0.0
			for i in runs:
				var cfg = SimConfig.new()
				cfg.seed_value = seed0 + i
				cfg.duration_sec = duration
				cfg.move_policy = mv
				cfg.pick_policy = pk
				cfg.label = label
				var agent = ScriptedAgent.new()
				agent.move_policy = mv
				agent.pick_policy = pk
				agent.rng = Rng.new(cfg.seed_value ^ 0x5f3759df)
				var w = SimWorld.new()
				w.setup(cfg, agent, db)
				var lg = w.run_to_end()
				f.store_line(lg.csv_row())
				total += 1
				if lg.result == "survived":
					survived += 1
				sum_kills += float(lg.kills_total)
				sum_time += lg.run_duration
				sim_seconds += lg.run_duration
				sum_level += float(lg.player_level)
				sum_stat += lg.time_stationary
				sum_turn += float(lg.rotation_count)
				sum_touch += lg.time_contacted
			print("%-7s/%-6s 存活率 %5.1f%%  平均存活 %6.1fs  击杀 %7.0f  转向 %4.1f 次  贴身占比 %4.1f%%  静止占比 %4.1f%%" % [
				mv, pk, 100.0 * float(survived) / float(runs), sum_time / float(runs),
				sum_kills / float(runs), sum_turn / float(runs),
				100.0 * sum_touch / maxf(1.0, sum_time),
				100.0 * sum_stat / maxf(1.0, sum_time)])
	f.close()
	var secs := float(Time.get_ticks_msec() - t0) / 1000.0
	print("—— %d 局 / %.1fs 墙钟，约 %.0f 倍速  →  %s" % [total, secs, sim_seconds / maxf(0.001, secs), out_path])
	quit()

func _args() -> Dictionary:
	var out := {}
	for s in OS.get_cmdline_user_args():
		var kv := String(s).split("=", true, 1)
		if kv.size() == 2:
			out[kv[0]] = kv[1]
	return out
