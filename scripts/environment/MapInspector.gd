extends Node
## 看大地图用的：**方向键平移相机，R 重掷整张图**。
##
## 这是个检视工具，不是玩法 —— 现在还没有玩家，黄色方块只是尺度参照。
## 相机是正交的，所以平移只是把相机连同它的注视点一起挪，投影不变。
##
## 夹取：把注视点夹在可玩区里。站在最边上时正好看见外面那条熔岩带 ——
## 屏幕宽 65.8 m，熔岩带 12-24 m，也就是 1/5 到 1/3 屏宽。

@export var camera_path: NodePath
@export var map_path: NodePath
@export var scatter_path: NodePath
@export var speed: float = 60.0            ## 米/秒
@export var fast_mult: float = 3.0         ## 按住 Shift
## 注视点离可玩区边界最近能到多少米。**这一条决定了熔岩占多少屏宽。**
## 屏幕半宽 32.9 m，边界离屏幕中心 inset 米，看到的熔岩带就是 32.9 - inset；
## 再加上边界本身向内抖动 0-12 m，实际是 11-23 m = 1/6 到 1/3 屏宽。
## 夹到边界上（inset = 0）的话熔岩会占到 60% 屏宽，太多了。
@export var edge_inset: float = 22.0

var _cam: Camera3D
var _focus := Vector3.ZERO
var _offset := Vector3.ZERO
var _rect := Rect2(-200.0, -200.0, 400.0, 400.0)


func _ready() -> void:
	_cam = get_node_or_null(camera_path) as Camera3D
	if _cam == null:
		push_warning("[MapInspector] 没找到相机，方向键不会有反应")
		return
	# 相机的初始位置就是"注视点 + 一个固定偏移"，平移时只动注视点
	_focus = Vector3(0.0, 0.0, 0.0)
	_offset = _cam.position
	var map := get_node_or_null(map_path)
	if map and map.has_method("play_rect"):
		_rect = map.play_rect()
	_rect = _rect.grow(-edge_inset)
	# 截图用：命令行给 pos=x,z 就直接跳过去，省得靠手按方向键去边角
	for a in OS.get_cmdline_user_args():
		var t := String(a)
		if t.begins_with("ortho="):
			# 截图用：拉远看全图，验证疏密和地图形状。
			# 正交下沿视线往后退不改变构图，只是把整张地图推到近裁剪面之前 ——
			# 不退的话相机身后那半张图会被裁掉，全图截出来一半是黑的。
			_cam.size = float(t.substr(6))
			_cam.far = 4000.0
			_cam.position += _cam.transform.basis.z * 800.0
			_offset = _cam.position
		if t.begins_with("pos="):
			var xz := t.substr(4).split(",")
			if xz.size() == 2:
				_focus = Vector3(float(xz[0]), 0.0, float(xz[1]))
				_focus.x = clampf(_focus.x, _rect.position.x, _rect.end.x)
				_focus.z = clampf(_focus.z, _rect.position.y, _rect.end.y)
				_cam.position = _focus + _offset
	print("[MapInspector] 方向键平移，Shift 加速，R 重掷。可玩区 %.0f x %.0f m"
			% [_rect.size.x, _rect.size.y])


func _process(delta: float) -> void:
	if _cam == null:
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	# 上/下键 = 世界的 -Z / +Z：相机俯视朝 -Z，所以"上"就是往画面深处走
	if Input.is_key_pressed(KEY_UP):
		dir.z -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		dir.z += 1.0
	if dir == Vector3.ZERO:
		return
	var v := speed * delta
	if Input.is_key_pressed(KEY_SHIFT):
		v *= fast_mult
	_focus += dir.normalized() * v
	_focus.x = clampf(_focus.x, _rect.position.x, _rect.end.x)
	_focus.z = clampf(_focus.z, _rect.position.y, _rect.end.y)
	_cam.position = _focus + _offset


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_reroll()


func _reroll() -> void:
	var s := randi()
	var map := get_node_or_null(map_path)
	if map and map.has_method("reroll"):
		map.call("reroll", s)
	var sc := get_node_or_null(scatter_path)
	if sc and sc.has_method("regenerate"):
		sc.call("regenerate", s + 1)
	print("[MapInspector] 重掷，seed = %d" % s)
