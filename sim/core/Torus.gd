extends RefCounted
## 环形地图的坐标运算（§10.1）。
##
## **全工程所有距离和方向计算都必须走这里。** 漏一处，地图接缝上就会出现
## "敌人明明在旁边却打不到"、"AI 往反方向跑" 这类只在特定位置复现的怪 bug。
## 判据：sim/ 里不允许出现 Vector2.distance_to() / direction_to()。

var w: float = 200.0
var h: float = 100.0
var wrap_x: bool = true
var wrap_y: bool = true

func _init(p_w: float = 200.0, p_h: float = 100.0, p_wx: bool = true, p_wy: bool = true) -> void:
	w = p_w
	h = p_h
	wrap_x = p_wx
	wrap_y = p_wy

func wrap(p: Vector2) -> Vector2:
	var x := fposmod(p.x, w) if wrap_x else clampf(p.x, 0.0, w)
	var y := fposmod(p.y, h) if wrap_y else clampf(p.y, 0.0, h)
	return Vector2(x, y)

## 从 a 指向 b 的最短向量（可能穿过接缝）
func delta(a: Vector2, b: Vector2) -> Vector2:
	var dx := b.x - a.x
	var dy := b.y - a.y
	if wrap_x:
		dx = fposmod(dx + w * 0.5, w) - w * 0.5
	if wrap_y:
		dy = fposmod(dy + h * 0.5, h) - h * 0.5
	return Vector2(dx, dy)

func dist(a: Vector2, b: Vector2) -> float:
	return delta(a, b).length()

func dist_sq(a: Vector2, b: Vector2) -> float:
	return delta(a, b).length_squared()

## 单位方向；重合时返回零向量
func dir(a: Vector2, b: Vector2) -> Vector2:
	var d := delta(a, b)
	var l := d.length()
	return d / l if l > 0.00001 else Vector2.ZERO

## 设计文档的角度约定：正上 0°，顺时针，正右 90°（§4.1）
static func angle_to_vec(deg: float) -> Vector2:
	var r := deg_to_rad(deg)
	return Vector2(sin(r), -cos(r))

static func vec_to_angle(v: Vector2) -> float:
	return rad_to_deg(atan2(v.x, -v.y))
