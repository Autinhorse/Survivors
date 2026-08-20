extends Node
## Headless-ish screenshot harness for reviewing the benchmark scene.
##
##   Godot_v4.7-stable_win64_console.exe --path <project> \
##       --resolution 1920x1080 res://tools/Screenshot.tscn -- <out.png> [scene]
##
## Loads the target scene, lets it settle for a few frames, writes a PNG and
## quits.  Used to compare the blockout against docs/target.png.

const SETTLE_FRAMES := 20

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "user://shot.png"
	var scene_path: String = args[1] if args.size() > 1 else "res://scenes/VisualBenchmark.tscn"

	var packed: PackedScene = load(scene_path)
	if packed == null:
		printerr("[screenshot] cannot load ", scene_path)
		get_tree().quit(1)
		return
	add_child(packed.instantiate())

	for _i in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	# Optional timing pass: `-- <out.png> <scene> <frames>`.
	# NOT the Milestone 4 benchmark (that needs the 5s warm-up / 20-30s window
	# from doc section 28).  This is only good for A/B comparisons of the same
	# scene on the same machine in the same session -- e.g. renderer switches.
	var frames: int = int(args[2]) if args.size() > 2 else 0
	if frames > 0:
		# V-Sync pins every frame to the refresh rate and hides the real cost.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		for _w in 90:
			await get_tree().process_frame
		var samples := PackedFloat64Array()
		var last := Time.get_ticks_usec()
		for _f in frames:
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			samples.append(float(now - last) / 1000.0)
			last = now
		var sorted := Array(samples)
		sorted.sort()
		var total := 0.0
		for v in samples:
			total += v
		var avg: float = total / float(samples.size())
		var p99: float = sorted[int(sorted.size() * 0.99) - 1]
		print("[bench] frames=", samples.size(),
				" avg_ms=", "%.3f" % avg,
				" avg_fps=", "%.1f" % (1000.0 / avg),
				" 1pct_low_ms=", "%.3f" % p99,
				" 1pct_low_fps=", "%.1f" % (1000.0 / p99))

	# Cheap render stats: not a benchmark (that is Milestone 4), just enough to
	# see whether the visual pass has quietly blown up the draw call count.
	print("[stats] draw_calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			" primitives=", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			" objects=", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
			" fps=", Performance.get_monitor(Performance.TIME_FPS))

	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(out_path)
	print("[screenshot] wrote ", out_path, " (", img.get_width(), "x",
			img.get_height(), ") err=", err)
	get_tree().quit(0 if err == OK else 1)
