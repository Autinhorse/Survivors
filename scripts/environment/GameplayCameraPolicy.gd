@tool
extends Camera3D
## 固定机位相机的宽高比策略。
##
## Godot 的 Camera3D 默认 `keep_aspect = KEEP_HEIGHT`：**垂直 FOV 固定，
## 水平 FOV 随宽高比增长**。对这种俯视射击来说这是个玩法问题，不只是画面问题：
##
##   16:9  水平 FOV  65.8°   可见地面宽  65.7 m
##   21:9  水平 FOV  81.6°   可见地面宽  87.7 m
##   32:9  水平 FOV 104.6°   可见地面宽 131.5 m   <- 正好是 16:9 的两倍
##
## 带鱼屏玩家能在两倍远处看见敌人。同时边缘物体也会明显外倾（越宽越夸张，
## 编辑器视口 FOV 75 + 3.2:1 时水平 FOV 达 136°，就是那种鱼眼感）。
##
## 三种策略：
##   keep_height   Godot 默认。越宽看得越多（有优势，有畸变）
##   keep_width    水平固定，越宽看得**越少**（上下被裁）
##   clamp         以基准宽高比为准，取更受限的那个轴 —— 任何屏幕都不会
##                 比基准看得更多。这是竞技公平性上的稳妥选择，也是默认值。
##
## 真正要"既公平又不裁切"的话得加信箱黑边，那属于 UI/呈现层，不在本 benchmark 范围。

@export_enum("clamp", "keep_height", "keep_width") var aspect_policy: String = "clamp":
	set(v):
		aspect_policy = v
		_apply()

## 设计基准：这个垂直 FOV 是在 reference_aspect 下定的（见 doc §9）
@export var design_fov_vertical: float = 40.0:
	set(v):
		design_fov_vertical = v
		_apply()
@export var reference_aspect: float = 16.0 / 9.0


func _ready() -> void:
	_apply()
	var vp := get_viewport()
	if vp and not vp.size_changed.is_connected(_apply):
		vp.size_changed.connect(_apply)


func _apply() -> void:
	if not is_inside_tree():
		return
	var vp := get_viewport()
	if vp == null:
		return
	var sz := vp.get_visible_rect().size
	var a: float = sz.x / maxf(sz.y, 1.0)

	# KEEP_WIDTH 下 `fov` 被解释为**水平** FOV，所以切换时要换算，
	# 否则视野会跳变
	var h_fov: float = rad_to_deg(2.0 * atan(tan(deg_to_rad(design_fov_vertical) * 0.5)
			* reference_aspect))

	match aspect_policy:
		"keep_height":
			keep_aspect = KEEP_HEIGHT
			fov = design_fov_vertical
		"keep_width":
			keep_aspect = KEEP_WIDTH
			fov = h_fov
		_:
			# 取更受限的轴：比基准宽 -> 锁水平；比基准窄 -> 锁垂直
			if a > reference_aspect:
				keep_aspect = KEEP_WIDTH
				fov = h_fov
			else:
				keep_aspect = KEEP_HEIGHT
				fov = design_fov_vertical
