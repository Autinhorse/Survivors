extends Node
## Headless-ish screenshot harness for reviewing the benchmark scene.
##
##   Godot_v4.7-stable_win64_console.exe --path <project> \
##       --resolution 1920x1080 res://tools/Screenshot.tscn -- <out.png> [scene]
##
## Loads the target scene, lets it settle for a few frames, writes a PNG and
## quits.
##
## Do NOT pass --headless: the dummy renderer never fires
## RenderingServer.frame_post_draw, so the await below hangs forever.  Used to compare the blockout against docs/target.png.

const SETTLE_FRAMES := 20

var _sub: SubViewport = null

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "user://shot.png"
	var scene_path: String = args[1] if args.size() > 1 else "res://scenes/VisualBenchmark.tscn"
	# 下面那几个"位置参数"（frames / shots / interval）只认**纯数字**的 token。
	# 场景脚本自己也读 user args（MapInspector 的 pos= / ortho=），
	# 而 String.to_int() 会从 "ortho=300" 里抠出 300 —— 一次 ortho=300 的截图
	# 变成了连拍 300 张。踩过一次。
	var pos_args := PackedStringArray()
	for a in args:
		if String(a).is_valid_int() or String(a).is_valid_float():
			pos_args.append(String(a))

	var packed: PackedScene = load(scene_path)
	if packed == null:
		printerr("[screenshot] cannot load ", scene_path)
		get_tree().quit(1)
		return

	# `size=WxH` 走 SubViewport 渲染：窗口尺寸受桌面分辨率钳制，
	# 想测 21:9 / 32:9 / 4K 这类超出屏幕的画面就只能这样。
	var forced := Vector2i.ZERO
	for a in args:
		if String(a).begins_with("size="):
			var wh := String(a).substr(5).split("x")
			if wh.size() == 2:
				forced = Vector2i(int(wh[0]), int(wh[1]))
	if forced.x > 0 and forced.y > 0:
		_sub = SubViewport.new()
		_sub.size = forced
		_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_sub.handle_input_locally = false
		add_child(_sub)
		_sub.add_child(packed.instantiate())
		print("[screenshot] SubViewport ", forced)
	else:
		add_child(packed.instantiate())

	for _i in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	# Optional timing pass: `-- <out.png> <scene> <frames>`.
	# NOT the Milestone 4 benchmark (that needs the 5s warm-up / 20-30s window
	# from doc section 28).  This is only good for A/B comparisons of the same
	# scene on the same machine in the same session -- e.g. renderer switches.
	var frames: int = int(pos_args[0]) if pos_args.size() > 0 else 0
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

	# Multiple shots over time: combat VFX cannot be judged from one frame.
	var shots: int = int(pos_args[1]) if pos_args.size() > 1 else 1
	var interval: float = float(pos_args[2]) if pos_args.size() > 2 else 0.5
	var err := OK
	for shot in maxi(shots, 1):
		if shot > 0:
			await get_tree().create_timer(interval).timeout
			await RenderingServer.frame_post_draw
		var vp: Viewport = _sub if _sub else get_viewport()
		var img: Image = vp.get_texture().get_image()
		var path := out_path
		if shots > 1:
			path = out_path.get_basename() + "_%d." % (shot + 1) + out_path.get_extension()
		err = img.save_png(path)
		print("[screenshot] wrote ", path, " (", img.get_width(), "x",
				img.get_height(), ") err=", err)
	get_tree().quit(0 if err == OK else 1)
