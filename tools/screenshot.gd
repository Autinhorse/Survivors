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

	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(out_path)
	print("[screenshot] wrote ", out_path, " (", img.get_width(), "x",
			img.get_height(), ") err=", err)
	get_tree().quit(0 if err == OK else 1)
