@tool
extends Node3D
## 风格 "hellrider" 的场地：**锯齿边界的地面 + 两侧熔岩带**。
##
## 这是这个风格最强的识别元素。参考图里它由三层构成，缺一层都不像：
##   1. 场地边缘的锯齿轮廓（这里生成的几何）
##   2. 紧贴轮廓的亮边（shaders/hr_lava.gdshader，靠 UV.x 携带的距离画）
##   3. 外面一大片菱形色块场（同一个着色器）
##
## 参考图是 45° 等距投影，锯齿沿着菱形网格走。**本项目是轴向的方形世界**，
## 所以锯齿只在 X 方向起伏、沿 Z 排列 —— 两条边各是一条竖直的锯齿线。
##
## 地面和熔岩共用同一个 `_edge_x(z)`，所以两者的边界**精确重合**，
## 不会出现缝或者重叠。这一点比看上去重要：
## 上一个风格里"判据坐标和实际可见边界对不上"这个坑踩了三次。

@export var rebuild: bool = false:
	set(v):
		rebuild = false
		if v:
			_build()

@export_group("场地")
@export var half_width: float = 20.0        ## 场地半宽（不含锯齿）
@export var z_start: float = -44.0
@export var z_end: float = 34.0
@export var tooth_len: float = 5.0          ## 一个锯齿沿 Z 的长度
@export var tooth_depth: float = 2.6        ## 锯齿的进出幅度

@export_group("熔岩")
@export var lava_width: float = 34.0        ## 熔岩带向外延伸多远
@export var lava_drop: float = 0.12         ## 熔岩比地面低多少
@export var lava_rows: int = 2              ## 熔岩带沿 X 分几段（着色器按 UV 算，够用）

@export_group("材质")
@export var ground_material: Material
@export var lava_material: Material


func _ready() -> void:
	_build()


func _edge_x(z: float) -> float:
	## 三角波：|2f-1| 在 0..1 之间往返，减 0.5 让锯齿在名义边界两侧对称摆动。
	var t := z / tooth_len
	var f: float = t - floor(t)
	return half_width + tooth_depth * (absf(2.0 * f - 1.0) - 0.5)


func _build() -> void:
	for c in get_children():
		c.queue_free()
	_ground()
	for s in [-1.0, 1.0]:
		_lava(s)


func _rows() -> PackedFloat32Array:
	## 采样点必须**正好落在锯齿的拐点上**，否则三角波会被采样平滑掉。
	##
	## 步长取 tooth_len 的一半只是一半条件 —— **起点还要对齐齿的相位**。
	## 这里一度只做了前者：z_start = -46、tooth_len = 5 时，采样落在
	## 三角波的 f=0.8 / 0.3 处而不是波峰波谷，振幅被压到名义值的 1/5，
	## 实测边界只摆动 ±3 px（应为 ±26 px）。表现是"把齿调到 5.2 m 还看不见"。
	var out := PackedFloat32Array()
	var step := tooth_len * 0.5
	var z: float = floor(z_start / tooth_len) * tooth_len
	while z <= z_end + 0.001:
		out.append(z)
		z += step
	return out


func _make(nm: String, verts: PackedVector3Array, uvs: PackedVector2Array,
		idx: PackedInt32Array, m: Material, shadow: bool) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var norms := PackedVector3Array()
	norms.resize(verts.size())
	norms.fill(Vector3.UP)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	if m:
		mi.material_override = m
	mi.cast_shadow = (GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	add_child(mi)
	# 不设 owner：这些是运行时生成的，写进 .tscn 会和重建冲突


func _ground() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var rows := _rows()
	for i in rows.size():
		var z: float = rows[i]
		var e := _edge_x(z)
		verts.append(Vector3(-e, 0.0, z))
		verts.append(Vector3(e, 0.0, z))
		uvs.append(Vector2(0.0, z))
		uvs.append(Vector2(1.0, z))
	for i in rows.size() - 1:
		var a := i * 2
		# 缠绕方向：Godot 的正面和"按右手定则法线朝上"是**反的**。
		# 这个坑在 RiverSurface / ProcMesh 里各踩过一次，注释就写在本文件顶上，
		# 这次还是写反了 —— 表现是地面和熔岩整个消失（网格在、AABB 对、
		# 但从上方看全被剔除）。判断方法：和 RiverSurface.gd 抄同一个顺序。
		idx.append(a); idx.append(a + 1); idx.append(a + 2)
		idx.append(a + 1); idx.append(a + 3); idx.append(a + 2)
	_make("Ground", verts, uvs, idx, ground_material, false)


func _lava(side: float) -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var rows := _rows()
	var cols := maxi(2, lava_rows + 1)
	for i in rows.size():
		var z: float = rows[i]
		var e := _edge_x(z)
		for j in cols:
			var f := float(j) / float(cols - 1)
			var d := f * lava_width
			verts.append(Vector3(side * (e + d), -lava_drop, z))
			# UV.x 携带**到场地边缘的距离（米）**，着色器靠它画亮边；
			# 用距离而不是世界坐标，亮边宽度在两条边上才一致
			uvs.append(Vector2(d, z))
	for i in rows.size() - 1:
		for j in cols - 1:
			var a := i * cols + j
			var b := a + 1
			var c := a + cols
			var d2 := c + 1
			# 两侧的顶点在 X 上方向相反，所以缠绕也要相反
			if side > 0.0:
				idx.append(a); idx.append(b); idx.append(c)
				idx.append(b); idx.append(d2); idx.append(c)
			else:
				idx.append(a); idx.append(c); idx.append(b)
				idx.append(b); idx.append(c); idx.append(d2)
	_make("Lava%s" % ("R" if side > 0.0 else "L"), verts, uvs, idx,
			lava_material, false)
