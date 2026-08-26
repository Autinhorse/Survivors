extends RefCounted
## 地图与坐标约定。全部长度单位是「格」。
## 坐标系：x 向右，y 向下（屏幕系）。角度 0 = +x（东），顺时针为正。
## 朝向索引：0=北 1=东 2=南 3=西，对应角度 -PI/2, 0, PI/2, PI。

const DIR_N := 0
const DIR_E := 1
const DIR_S := 2
const DIR_W := 3

static func dir_to_angle(dir: int) -> float:
	return wrapf(float(dir) * PI * 0.5 - PI * 0.5, -PI, PI)

## 角度落在哪个 90° 象限（用于「把哪一面转过去」）
static func angle_to_dir(a: float) -> int:
	return int(round(wrapf(a + PI * 0.5, -PI, PI) / (PI * 0.5))) & 3

static func clamp_pos(p: Vector2, w: float, h: float, margin: float) -> Vector2:
	return Vector2(clampf(p.x, margin, w - margin), clampf(p.y, margin, h - margin))

## 从地图外一圈某个角度取一个刷新点
static func spawn_point(center: Vector2, a: float, w: float, h: float, margin: float) -> Vector2:
	var r := sqrt(w * w + h * h) * 0.5 + margin
	return center + Vector2(cos(a), sin(a)) * r
