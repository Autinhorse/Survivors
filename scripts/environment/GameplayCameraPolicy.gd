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

## 正交投影。实测参考风格（styles/hellrider）用的就是正交：
## 通道宽度从画面顶端到底端完全不变（收敛斜率 −0.005 px/行），
## 而透视下我们是 +1.06 px/行、近处比远处宽 1.9 倍。
##
## 投影方式是**玩法层**的决定而不是美术风格的决定，但它和 §9 的
## 屏幕外生成半径直接相关：透视下可见区域是个梯形（近边 ±27.2 m、
## 远边 ±41.6 m，所以生成半径要按最远的角算到 54.3 m）；
## 正交下可见区域是个**矩形**，生成半径的推导会简单很多。
@export var orthographic: bool = false:
	set(v):
		orthographic = v
		_apply()
## 正交时的**纵向**世界高度（对应透视的 design_fov_vertical）
@export var ortho_size: float = 37.0:
	set(v):
		ortho_size = v
		_apply()

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

	if orthographic:
		projection = PROJECTION_ORTHOGONAL
		# 正交下 size 就是世界单位，clamp 的逻辑同样适用：
		# 比基准宽就锁横向（否则宽屏玩家横向看得更多）
		if aspect_policy == "keep_width" or (
				aspect_policy == "clamp" and a > reference_aspect):
			keep_aspect = KEEP_WIDTH
			size = ortho_size * reference_aspect
		else:
			keep_aspect = KEEP_HEIGHT
			size = ortho_size
		return
	projection = PROJECTION_PERSPECTIVE

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
