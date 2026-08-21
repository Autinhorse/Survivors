@tool
extends MeshInstance3D
## 沿河道生成的一条带状水面，带**顺流 UV**。
##
## 之前是一片片独立的 plane，着色器只能拿世界坐标滚动噪声 ——
## 于是水流永远朝同一个世界方向。河道一拐弯，就能看见水从一侧河岸流出、
## 流进对岸。静帧完全看不出来，跑起来一眼就是错的。
##
## UV 约定：
##   UV.x   横向归一化，0 = 左岸、1 = 右岸（河道边界恰好是 0 和 1）
##          岸边泡沫用它，宽窄变化时边界依然精确
##   UV.y   顺流坐标，按 `ds / 宽度` 累加
##   UV2.x  横向的**米制**坐标，用于保持纹理横向密度恒定
##          （UV.x 是归一化的，宽处会把纹理横向拉长）
##   UV2.y  同 UV.y
##
## UV.y 按 `ds / 宽度` 累加是关键的一步，也是流量守恒的直接体现：
## Q = 宽 × 深 × 流速 是常量，所以宽处流速慢。窄处每米累加更多 V，
## 着色器用**恒定的 UV 滚动速度**就能得到「窄处流得快、宽处流得慢」，
## 不需要在着色器里知道河宽。
##
## 网格比河道宽出 `overhang`：多出的部分埋在地形里看不见，
## 于是可见的水面轮廓完全由地形挖槽决定，不必和挖槽逐点对齐。

@export var rebuild: bool = false:
	set(v):
		rebuild = false
		if v:
			_build()

@export_group("河道（与生成器/着色器保持一致）")
@export var river_x0: float = 10.0
@export var river_slope: float = 0.28
@export var river_amp: float = 2.6
@export var river_freq: float = 0.085
@export var river_w: float = 7.5
@export var river_w_amp: float = 0.28
@export var river_w_freq_mul: float = 1.7
@export var river_w_phase: float = 1.1

@export_group("网格")
@export var z_start: float = -50.0
@export var z_end: float = 50.0
@export var step: float = 1.5
@export var overhang: float = 2.5      ## 超出河道的部分，埋进地形
@export var water_y: float = -2.55
@export var v_scale: float = 6.0       ## 顺流 UV 的整体缩放
@export var u_metre_scale: float = 4.0 ## UV2.x 的米制缩放


func _ready() -> void:
	_build()


func _centre(z: float) -> float:
	return river_x0 + river_slope * z + river_amp * sin(z * river_freq)


func _width(z: float) -> float:
	return river_w * (1.0 + river_w_amp * sin(z * river_freq * river_w_freq_mul
			+ river_w_phase))


func _tangent(z: float) -> Vector3:
	var dxdz := river_slope + river_amp * river_freq * cos(z * river_freq)
	return Vector3(dxdz, 0.0, 1.0).normalized()


func _build() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()

	var v_acc := 0.0
	var prev_centre := Vector3.ZERO
	var first := true
	var rows := 0
	var z := z_start
	while z <= z_end:
		var w := _width(z)
		var half := w * 0.5 + overhang
		var c := Vector3(_centre(z), water_y, z)
		var t := _tangent(z)
		var side := Vector3(t.z, 0.0, -t.x)      # XZ 平面内的法向

		if not first:
			var ds := c.distance_to(prev_centre)
			# 流量守恒 Q = 宽 × 深 × 流速：宽处流速慢。
			#
			# 推导（别凭直觉，很容易写反）：设 dv/ds = k，滚动速度 dv/dt 恒定，
			# 则世界流速 ds/dt = (dv/dt)/k。要让 ds/dt ∝ 1/w，就需要 k ∝ w。
			# 所以是乘以 w/river_w，不是除。
			# 写反的表现是"宽处流得更快"，正好和真实河流相反。
			v_acc += ds * (w / river_w) / v_scale
		first = false
		prev_centre = c

		var l := c - side * half
		var r := c + side * half
		verts.append(l)
		verts.append(r)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		# UV.x 让河道边界恰好落在 0 和 1（overhang 落在区间外）
		var edge_u := (half - overhang) / (2.0 * half)
		uvs.append(Vector2(0.5 - edge_u, v_acc))
		uvs.append(Vector2(0.5 + edge_u, v_acc))
		uv2.append(Vector2(-half / u_metre_scale, v_acc))
		uv2.append(Vector2(half / u_metre_scale, v_acc))
		rows += 1
		z += step

	for i in rows - 1:
		var a := i * 2
		# 缠绕方向：与 ProcMesh 里踩过的是同一个坑 —— 顺序反了整个面会被
		# 背面剔除掉，表现为"网格存在、AABB 正确、但什么都不画"
		idx.append(a); idx.append(a + 1); idx.append(a + 2)
		idx.append(a + 1); idx.append(a + 3); idx.append(a + 2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 水面是完全平的，自动算出来的 AABB 在 Y 方向厚度接近 0。
	# 给它一点厚度，避免退化 AABB 在剔除时出问题。
	var ab := m.get_aabb()
	custom_aabb = AABB(ab.position - Vector3(0, 1, 0), ab.size + Vector3(0, 2, 0))
