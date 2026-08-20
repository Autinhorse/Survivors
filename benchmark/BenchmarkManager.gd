extends Node
## Milestone 4 crowd benchmark (doc sections 22 / 27 / 28).
##
## Runs a plan of (enemy_count, shadow_mode) rows.  For every row:
##   set the crowd -> warm up 5 s -> measure 20-30 s -> append one CSV line.
##
## Section 28 is explicit that "looks smooth enough" is not a result, so the
## numbers here are always measured the same way: V-Sync off, a fixed warm-up,
## a fixed measurement window, and average / 1% low reported separately.
##
## Must run WINDOWED.  Under --headless there is no rendering and
## RenderingServer.frame_post_draw never fires.

@export var crowd_path: NodePath              ## conventional Node crowd
@export var crowd_mm_path: NodePath           ## data-oriented MultiMesh crowd
## Architectures to run.  "node" = section 6 方案 A, "mm-parts"/"mm-merged" =
## the two 方案 B variants (CPU transform per part vs shader animation).
@export var architectures: PackedStringArray = PackedStringArray(["node"])
## Section 23 VFX levels: 0 off, 1..4 = 100/300/500/1000 projectiles and
## 10/30/50/100 explosions per second.
@export var vfx_levels: PackedInt32Array = PackedInt32Array([0])
@export var stress_path: NodePath
@export var counts: PackedInt32Array = PackedInt32Array(
		[100, 250, 500, 750, 1000, 1500, 2000])
@export var shadow_modes: PackedStringArray = PackedStringArray(["A", "B"])
@export var warmup_sec: float = 5.0
@export var measure_sec: float = 20.0
@export var out_path: String = "res://benchmark/results/crowd.csv"
@export var label: String = "M4-node"
@export var auto_quit: bool = true

var move_override: float = -1.0
var freeze_override: bool = false

const HEADERS := [
	"timestamp", "hardware", "renderer", "preset", "architecture",
	"enemy_count", "alive_avg", "projectile_count", "explosion_rate",
	"shadow_mode", "move_speed", "frozen",
	"fps_avg", "fps_1pct_low", "frame_ms_avg", "frame_ms_1pct_low",
	"cpu_render_ms", "gpu_render_ms", "process_ms",
	"draw_calls", "primitives", "tri_per_unit", "nodes",
]

var _crowd: Node                 ## currently selected crowd
var _crowd_node: Node
var _crowd_mm: Node
var _stress: Node
var _rows: Array[PackedStringArray] = []


func _ready() -> void:
	_crowd_node = get_node_or_null(crowd_path)
	_crowd_mm = get_node_or_null(crowd_mm_path)
	_stress = get_node_or_null(stress_path)
	_crowd = _crowd_node
	if _crowd_node == null and _crowd_mm == null:
		push_error("BenchmarkManager: no crowd node found")
		return
	_apply_cli()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(
			get_viewport().get_viewport_rid(), true)
	_run.call_deferred()


func _apply_cli() -> void:
	## `-- counts=100,500 modes=A,B warmup=2 measure=5 label=x` so a plan can be
	## re-run without editing the scene.
	for a in OS.get_cmdline_user_args():
		var kv := String(a).split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"counts":
				var cs := PackedInt32Array()
				for t in kv[1].split(","):
					cs.append(int(t))
				counts = cs
			"modes":
				modes_from(kv[1])
			"warmup":
				warmup_sec = float(kv[1])
			"measure":
				measure_sec = float(kv[1])
			"label":
				label = kv[1]
			"freeze":
				freeze_override = kv[1] == "1"
			"move":
				move_override = float(kv[1])
			"light":
				var v := get_node_or_null(stress_path)
				if v:
					var mgr := v.get_node_or_null(v.get("vfx_path"))
					if mgr:
						mgr.set("explosion_light", kv[1] == "1")
			"noproj":
				if _stress:
					_stress.set("projectiles_disabled", kv[1] == "1")
			"vfx":
				var vs := PackedInt32Array()
				for t in kv[1].split(","):
					vs.append(int(t))
				vfx_levels = vs
			"archs":
				var az := PackedStringArray()
				for t in kv[1].split(","):
					az.append(t)
				architectures = az


func modes_from(csv: String) -> void:
	var ms := PackedStringArray()
	for t in csv.split(","):
		ms.append(t)
	shadow_modes = ms


func _run() -> void:
	var started := Time.get_datetime_string_from_system()
	var n_rows := counts.size() * shadow_modes.size() * architectures.size() 			* vfx_levels.size()
	print("[bench] plan: %d rows (%s), %.0fs warmup + %.0fs measure each"
			% [n_rows, ",".join(architectures), warmup_sec, measure_sec])
	print("[bench] estimated wall clock: %.1f min"
			% ((n_rows * (warmup_sec + measure_sec)) / 60.0))

	for arch in architectures:
		for mode in shadow_modes:
			for c in counts:
				for v in vfx_levels:
					await _measure_row(String(arch), int(c), String(mode), int(v))

	_write_csv(started)
	if auto_quit:
		get_tree().quit()


func _select(arch: String) -> void:
	## Only one crowd is populated at a time; the other is emptied so it cannot
	## contribute nodes, draw calls or CPU time to the measurement.
	match arch:
		"node":
			_crowd = _crowd_node
		"mm-parts", "mm-merged":
			_crowd = _crowd_mm
			_crowd.set("variant", arch.substr(3))
		_:
			push_error("unknown architecture: " + arch)
			return
	for other in [_crowd_node, _crowd_mm]:
		if other and other != _crowd:
			other.set("count", 0)


func _measure_row(arch: String, c: int, mode: String, vfx_level: int) -> void:
	_select(arch)
	if _crowd == null:
		return
	if move_override >= 0.0:
		_crowd.set("move_speed", move_override)
	_crowd.set("freeze_logic", freeze_override)
	_crowd.set("shadow_mode", mode)
	_crowd.set("count", c)
	if _stress:
		_stress.call("level", vfx_level)
	# node creation for 2000 units is not free; let it settle before warm-up
	await get_tree().process_frame
	await get_tree().create_timer(warmup_sec).timeout

	var frames := PackedFloat64Array()
	var alive_sum := 0.0
	var draw_calls := 0.0
	var prims := 0.0
	var cpu_ms := 0.0
	var gpu_ms := 0.0
	var proc_ms := 0.0
	var vp := get_viewport().get_viewport_rid()

	var t_end := Time.get_ticks_usec() + int(measure_sec * 1_000_000.0)
	var last := Time.get_ticks_usec()
	while Time.get_ticks_usec() < t_end:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		frames.append(float(now - last) / 1000.0)
		last = now
		alive_sum += float(_crowd.call("alive_count"))
		draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		proc_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0

	var n := float(maxi(frames.size(), 1))
	var sorted := Array(frames)
	sorted.sort()
	var total := 0.0
	for f in frames:
		total += f
	var avg: float = total / n
	# "1% low" = the 99th percentile frame time, i.e. the worst 1% of frames
	var p99: float = sorted[maxi(int(sorted.size() * 0.99) - 1, 0)]

	var row := PackedStringArray([
		Time.get_datetime_string_from_system(),
		RenderingServer.get_video_adapter_name(),
		_renderer_name(),
		"default",
		String(_crowd.call("arch_name")),
		str(c),
		"%.1f" % (alive_sum / n),
		str(_stress.call("live_projectiles")) if _stress else "0",
		("%.0f" % float(_stress.call("explosion_rate"))) if _stress else "0",
		mode,
		"%.2f" % float(_crowd.get("move_speed")),
		"1" if bool(_crowd.get("freeze_logic")) else "0",
		"%.1f" % (1000.0 / avg),
		"%.1f" % (1000.0 / p99),
		"%.3f" % avg,
		"%.3f" % p99,
		"%.3f" % (cpu_ms / n),
		"%.3f" % (gpu_ms / n),
		"%.3f" % (proc_ms / n),
		"%.0f" % (draw_calls / n),
		"%.0f" % (prims / n),
		str(_crowd.call("triangles_per_unit")),
		str(get_tree().get_node_count()),
	])
	_rows.append(row)
	print("[bench] %-11s n=%5d sh=%s vfx=%d(%s proj,%s expl/s)  avg=%6.1f fps (%6.2f ms)  1%%low=%6.1f fps  gpu=%5.2f ms  dc=%s"
			% [row[4], c, mode, vfx_level, row[7], row[8],
			1000.0 / avg, avg, 1000.0 / p99, gpu_ms / n, row[19]])


func _renderer_name() -> String:
	var m: String = ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")
	return m


func _write_csv(started: String) -> void:
	var dir := out_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var stamp := started.replace(":", "-").replace("T", "_")
	var path := "%s/%s_%s.csv" % [dir, out_path.get_file().get_basename(), stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("BenchmarkManager: cannot write " + path)
		return
	f.store_line(",".join(HEADERS))
	for r in _rows:
		f.store_line(",".join(r))
	f.close()
	print("[bench] wrote ", ProjectSettings.globalize_path(path))
