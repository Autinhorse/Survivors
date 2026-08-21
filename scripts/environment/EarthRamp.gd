@tool
extends MeshInstance3D
## 桥头的土坡：一个**四周平滑归零**的高度场，不是一个旋转的盒子。
##
## 旋转的 CSG 盒子有三个问题，而且都是原理性的：
##   1. 三面都是硬棱 —— 侧面和坡趾读成一个三角楔子，一眼是几何体不是地形；
##   2. 它是实体，会捅穿桥面和旁边的房子（本项目两样都发生了）；
##   3. 布尔运算的结果没法"渐隐"进周围地面。
##
## 高度场解决全部三条：坡面在两端和两侧都用 smoothstep 归零，
## 边缘正好落在地面高度（略低一点点避免 z-fighting），于是和地面自然接上。
##
## 用**地形材质**（shaders/ground.gdshader）：它是按世界坐标投影的，
## 所以土丘的草地纹理和周围地面严丝合缝对齐 —— 换成 UV 投影就会出现接缝。
## 坡度还会自动触发着色器的草→土→石过渡，坡面因此比平地更偏土色，
## 正是踩出来的路该有的样子。
##
## 局部坐标：+X 从坡趾指向桥头，Z 横向，Y 向上。

@export var rebuild: bool = false:
	set(v):
		rebuild = false
		if v:
			_build()

@export_group("形状")
@export var length: float = 10.0          ## 坡趾到桥头的长度
@export var height: float = 1.78          ## 桥头处的高度（要低于桥底面）
@export var half_width_toe: float = 6.4   ## 坡趾处的半宽（宽）
@export var half_width_head: float = 5.2  ## 桥头处的半宽（窄）
@export var side_falloff: float = 0.42    ## 两侧从满高降到 0 占的比例
@export var head_flat: float = 0.16       ## 顶端保持满高的一段，让桥能落在上面

@export_group("打碎")
@export var noise_amp: float = 0.16
@export var noise_freq: float = 0.55
@export var seed_val: int = 90210

@export_group("网格")
@export var steps_long: int = 28
@export var steps_across: int = 24
@export var sink: float = 0.05            ## 边缘沉入地面多少，避免 z-fighting

var _rng := RandomNumberGenerator.new()
var _grad := PackedFloat32Array()


func _ready() -> void:
	_build()


func _noise_at(x: float, z: float) -> float:
	# 廉价的值噪声：四角哈希 + 平滑插值。只是为了打碎数学般的规整，
	# 不需要真正的分形噪声。
	var fx := x * noise_freq
	var fz := z * noise_freq
	var x0 := floori(fx)
	var z0 := floori(fz)
	var tx: float = smoothstep(0.0, 1.0, fx - float(x0))
	var tz: float = smoothstep(0.0, 1.0, fz - float(z0))
	var a := _hash2(x0, z0)
	var b := _hash2(x0 + 1, z0)
	var c := _hash2(x0, z0 + 1)
	var d := _hash2(x0 + 1, z0 + 1)
	return lerp(lerp(a, b, tx), lerp(c, d, tx), tz)


func _hash2(x: int, z: int) -> float:
	var h := (x * 374761393 + z * 668265263 + seed_val * 1442695040) & 0x7fffffff
	h = (h ^ (h >> 13)) * 1274126177
	return float((h ^ (h >> 16)) & 0xffff) / 65535.0 * 2.0 - 1.0


func _height(u: float, v: float) -> float:
	## u: 0 = 坡趾, 1 = 桥头。 v: -1..1 横向归一化。
	# 纵向：smoothstep 在两端导数都为 0 —— 坡趾不会有折线，
	# 顶端也不会在接桥处顶出一道棱
	var ramp: float = smoothstep(0.0, 1.0 - head_flat, u)
	# 横向：中间满高，靠边平滑归零
	var a: float = absf(v)
	var side: float = 1.0 - smoothstep(1.0 - side_falloff, 1.0, a)
	var h := height * ramp * side
	# 噪声要被同样的包络乘住，否则边缘会翘起一圈毛边。
	# **顶端也要把噪声收掉**：桥底面离坡顶只有几厘米，
	# 噪声在这里哪怕只顶起 0.1 m 也会从桥板缝里冒出来。
	var head_fade: float = 1.0 - smoothstep(0.72, 1.0, u)
	var hw := lerpf(half_width_toe, half_width_head, u)
	h += _noise_at(u * length, v * hw) * noise_amp * ramp * side * head_fade
	return h - sink * (1.0 - side)


func _build() -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	var du := 1.0 / float(steps_long)
	var dv := 2.0 / float(steps_across)

	for i in steps_long + 1:
		var u := float(i) * du
		var hw := lerpf(half_width_toe, half_width_head, u)
		for j in steps_across + 1:
			var v := -1.0 + float(j) * dv
			var x := (u - 1.0) * length          # 桥头在 x = 0
			var z := v * hw
			verts.append(Vector3(x, _height(u, v), z))
			uvs.append(Vector2(u, (v + 1.0) * 0.5))

			# 法线用中心差分。解析求导也行，但噪声那一项写起来容易错，
			# 差分对高度场是稳的。
			var e := 0.04
			var hx := (_height(minf(1.0, u + e), v) - _height(maxf(0.0, u - e), v))
			var hz := (_height(u, minf(1.0, v + e)) - _height(u, maxf(-1.0, v - e)))
			norms.append(Vector3(-hx / (2.0 * e * length), 1.0,
					-hz / (2.0 * e * hw)).normalized())

	var stride := steps_across + 1
	for i in steps_long:
		for j in steps_across:
			var a := i * stride + j
			var b := a + 1
			var c := a + stride
			var d := c + 1
			idx.append(a); idx.append(c); idx.append(b)
			idx.append(b); idx.append(c); idx.append(d)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = m
