extends SceneTree
## MapEval 的分段计时。改性能之前先量，别猜。
const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const Agent = preload("res://sim/agent/Agent.gd")
const Enemy = preload("res://sim/entities/Enemy.gd")

func _initialize() -> void:
	var cfg = SimConfig.new()
	cfg.seed_value = 5
	var w = SimWorld.new()
	w.setup(cfg, Agent.new())
	w.spawner._next_wave = 99999
	var c: Vector2 = w.mech.pos
	var many: Array = []
	for i in 1000:
		var e = Enemy.new()
		e.pos = c + Vector2(float(i % 25) - 12.0, float(i / 25) * 0.5 - 12.0)
		e.hp = 100.0; e.max_hp = 100.0; e.attack = 10.0; e.attack_interval = 2.0
		many.append(e)
	w.enemies = many
	var me = w.map_eval
	me.evaluate(w)

	var reps := 20
	print("1000 敌人，%d 次平均：" % reps)
	print("  整体            %6.0f µs" % _t(reps, func(): me.evaluate(w)))
	print("  只清零 + 主循环   %6.0f µs" % _t(reps, func(): me.prof_scan(w)))
	print("  只聚集度         %6.0f µs" % _t(reps, func(): me._eval_clusters()))
	print("  只 SAT           %6.0f µs" % _t(reps, func(): me._build_sat()))
	print("  只己方DPS        %6.0f µs" % _t(reps, func(): me._eval_own_dps(w.mech)))
	quit()

func _t(reps: int, f: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	for i in reps:
		f.call()
	return float(Time.get_ticks_usec() - t0) / float(reps)
