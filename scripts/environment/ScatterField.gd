@tool
extends Node3D
## Draws one class of scattered environment prop (rocks / trees / bushes) as a
## handful of MultiMeshes -- one per mesh variant, one extra for tree trunks.
##
## Placements come from the scene as a flat float array (7 floats per item:
## x, y, z, yaw, sx, sy, sz) because that is what the layout generator already
## computes; the meshes themselves are built procedurally at load (ProcMesh),
## so no asset import step is involved.
##
## This also puts a realistic number of MultiMesh draw calls in front of the
## Milestone 4/5 comparison: environment props are already batched, so the crowd
## benchmark measures the enemies, not the scenery.

# preload rather than relying on the global class name: the class cache is
# only built by the editor, so a direct `godot <scene>` run would not see it
const PM = preload("res://scripts/environment/ProcMesh.gd")

const STRIDE := 7

@export_enum("rock", "tree", "bush") var kind: String = "rock"
## 从 GLB 里取网格，而不是程序生成（tools/gen_assets_blender.py 的产物）。
## 设了这个之后 kind 被忽略：每个网格就是一个变体，仍然走 MultiMesh 批处理 ——
## 资产在 Blender 里做，批处理在 Godot 这边，两件事不冲突。
@export var source_scene: PackedScene
@export var placements: PackedFloat32Array = PackedFloat32Array()
@export var variants: int = 6
@export var rng_seed: int = 20260820
@export var cast_shadows: bool = true

@export_group("Blob 阴影")
## 贴在地面上的软影贴片（hr_blob.gdshader）。设了才生成。
## 平面着色风格用它代替真实投影阴影 —— 真影子会把纯色块切出硬边。
@export var blob_material: Material
@export var blob_scale: float = 2.1        ## 相对散布物尺度
## 椭圆度：影子按物体底面的形状拉扁并跟着朝向转，比正圆更像烘出来的 AO
@export var blob_aspect: float = 0.78
@export var blob_y: float = 0.03
## 逐块的底面椭圆（Blender 端量出来的，rocks_footprint.json）。
## 一个"变体"其实是**一组**石头（一大配两三小），只给整组一个椭圆的话
## 影子比石头小得多，从上面看等于没有影子。
## 编码：每个变体先一个数字 = 这组有几块，然后每块 5 个数
## (cx, cy, ex, ey, ang)，坐标是 Blender 的 XY、角度是弧度。
@export var footprints: PackedFloat32Array = PackedFloat32Array()

@export_group("Materials")
@export var material: Material                 ## rocks / bushes / tree trunks
@export var material_secondary: Material       ## tree canopies

@export_group("Tree shape")
@export var trunk_height: float = 3.0
@export var trunk_radius: float = 0.22
@export var canopy_radius: float = 1.8
@export var canopy_blobs: int = 3

@export var rebuild: bool = false:             # editor button
	set(v):
		rebuild = false
		if v:
			_build()


func _ready() -> void:
	_build()


func _build() -> void:
	for c in get_children():
		c.queue_free()
	if placements.is_empty() or variants <= 0:
		return

	# bucket every placement by variant so each MultiMesh gets one mesh
	var buckets: Array[Array] = []
	for _v in variants:
		buckets.append([])
	var count := placements.size() / STRIDE
	for i in count:
		var o := i * STRIDE
		var basis := Basis(Vector3.UP, deg_to_rad(placements[o + 3]))
		basis = basis.scaled(Vector3(placements[o + 4], placements[o + 5],
				placements[o + 6]))
		buckets[i % variants].append(
				Transform3D(basis, Vector3(placements[o], placements[o + 1],
						placements[o + 2])))

	if blob_material:
		_blobs(buckets)
	var src_meshes := _meshes_from_source()
	if not src_meshes.is_empty():
		for v in variants:
			if buckets[v].is_empty():
				continue
			# 传 material 而不是 null。GLB 自带的材质只是个白色载体 ——
			# 真正的颜色烘在顶点色里，得靠这里挂上的着色器读出来。
			_add_layer("Src%d" % v, src_meshes[v % src_meshes.size()],
					material, buckets[v])
		return

	for v in variants:
		if buckets[v].is_empty():
			continue
		var salt := rng_seed + v * 1013
		match kind:
			"rock":
				_add_layer("Rock%d" % v, PM.rock(salt), material, buckets[v])
			"bush":
				_add_layer("Bush%d" % v, PM.bush(salt), material, buckets[v])
			"tree":
				_add_layer("Trunk%d" % v,
						PM.trunk(salt, trunk_height, trunk_radius),
						material, buckets[v])
				_add_layer("Canopy%d" % v,
						PM.canopy(salt, canopy_blobs, canopy_radius,
								trunk_height * 0.85),
						material_secondary, buckets[v])


func _parse_footprints() -> Array:
	## 拆成 [变体][(cx, cy, ex, ey, ang), ...]
	var out: Array = []
	var i := 0
	while i < footprints.size():
		var n := int(footprints[i])
		i += 1
		var grp: Array = []
		for _k in n:
			if i + 5 > footprints.size():
				break
			grp.append([footprints[i], footprints[i + 1], footprints[i + 2],
					footprints[i + 3], footprints[i + 4]])
			i += 5
		out.append(grp)
	return out


func _blobs(buckets: Array) -> void:
	## 所有散布物共用一层 MultiMesh，一次 draw call。
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.orientation = PlaneMesh.FACE_Y
	var fps := _parse_footprints()
	var xf: Array[Transform3D] = []
	for v in buckets.size():
		for t in buckets[v]:
			var s: float = t.basis.get_scale().x
			var yaw: float = t.basis.get_euler().y
			if not fps.is_empty() and not fps[v % fps.size()].is_empty():
				# 逐块一个椭圆，按实例的朝向和缩放摆
				var ca := cos(yaw)
				var sa := sin(yaw)
				for f in fps[v % fps.size()]:
					# Blender XY -> Godot XZ，和 layout.py 的 _blob_spots 同一套
					var lx: float = f[0] * s
					var lz: float = -f[1] * s
					xf.append(Transform3D(
							Basis(Vector3.UP, f[4] + yaw).scaled(Vector3(
									2.0 * f[2] * s * blob_scale, 1.0,
									2.0 * f[3] * s * blob_scale)),
							Vector3(t.origin.x + lx * ca + lz * sa, blob_y,
									t.origin.z - lx * sa + lz * ca)))
				continue
			# 没有底面数据就退回"整件一个椭圆"
			var r: float = s * blob_scale
			# 跟着散布物的朝向转，并按 blob_aspect 拉扁 ——
			# 正圆的影子在成组的石头下面一眼是贴上去的
			var bs := Basis(Vector3.UP, yaw).scaled(
					Vector3(r, 1.0, r * blob_aspect))
			xf.append(Transform3D(bs, Vector3(t.origin.x, blob_y, t.origin.z)))
	if xf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	var mi := MultiMeshInstance3D.new()
	mi.name = "Blobs"
	mi.multimesh = mm
	mi.material_override = blob_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _meshes_from_source() -> Array[Mesh]:
	var out: Array[Mesh] = []
	if source_scene == null:
		return out
	var inst := source_scene.instantiate()
	_collect_meshes(inst, out)
	inst.queue_free()
	return out


func _collect_meshes(n: Node, out: Array[Mesh]) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		out.append((n as MeshInstance3D).mesh)
	for c in n.get_children():
		_collect_meshes(c, out)


func _add_layer(nm: String, mesh: Mesh, mat: Material,
		xforms: Array) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	if mat:
		mmi.material_override = mat
	if not cast_shadows:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	# 不设 owner：一旦设了，编辑器里保存场景会把这些**运行时生成**的节点
	# 写进 .tscn。下次打开脚本又重建一遍，新旧混在一起，
	# MultiMesh 的 instance_count 会和写入的索引对不上。
	# 生成物就该只活在内存里。
