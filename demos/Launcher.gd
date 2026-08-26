extends Control
## 工程入口。三个 Demo 各自独立，互不引用。

const DEMOS := [
	["03 数值验证（手玩）", "res://demos/03_balance/Play.tscn"],
	["02 美术风格 hellrider", "res://scenes/VisualBenchmark_hellrider.tscn"],
	["02 美术风格 gatling", "res://scenes/VisualBenchmark.tscn"],
	["01 人群性能压测", "res://scenes/PerformanceBenchmark.tscn"],
	["01 VFX 压测", "res://scenes/AssetPreview.tscn"],
]

func _ready() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(700, 300)
	box.custom_minimum_size = Vector2(520, 0)
	add_child(box)
	var title := Label.new()
	title.text = "Survivors — 选一个 Demo"
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	for d in DEMOS:
		var b := Button.new()
		b.text = d[0]
		b.custom_minimum_size = Vector2(520, 52)
		var path: String = d[1]
		b.disabled = not ResourceLoader.exists(path)
		b.pressed.connect(func() -> void: get_tree().change_scene_to_file(path))
		box.add_child(b)
	var hint := Label.new()
	hint.text = "批量模拟不走这里：godot --headless --script res://demos/03_balance/Batch.gd -- runs=50"
	box.add_child(hint)
