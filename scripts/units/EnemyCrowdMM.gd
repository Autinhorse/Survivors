extends Node3D
## Milestone 5 crowd: DATA-ORIENTED + MultiMesh (doc section 6, 方案 B).
##
## No node per enemy.  Unit state lives in packed arrays:
##     position / yaw / phase / dead timer
## and the visual is written straight into MultiMesh buffers.
##
## Two variants, because section 7 asks which combination actually wins:
##
##   "parts"   5 MultiMeshes (body/head/gun/legL/legR).  The CPU computes each
##             part's transform, including the leg swing -- i.e. the same work
##             the Node version does, minus the scene tree.
##             => 5 draw calls, 5 buffer writes per unit
##
##   "merged"  1 MultiMesh holding ONE merged mesh; the leg swing and body bob
##             run in shaders/enemy_crowd.gdshader from INSTANCE_CUSTOM.
##             => 1 draw call, 1 buffer write per unit
##
## Both write whole MultiMesh buffers with `set_buffer()` rather than calling
## `set_instance_transform()` per instance: in GDScript the per-call overhead is
## the thing being avoided, so measuring the slow API would measure the wrong
## thing.
##
## Geometry is IDENTICAL to EnemyCrowd (same primitive sizes, ~150 tris/unit) so
## the comparison is like-for-like, as section 22 Milestone 5 requires.

const SHADER := preload("res://shaders/enemy_crowd.gdshader")

@export var target_path: NodePath
@export_enum("parts", "merged") var variant: String = "merged":
	set(v):
		variant = v
		if is_inside_tree():
			_rebuild_layers()
@export var freeze_logic: bool = false

@export_group("Crowd")
@export var count: int = 0:
	set(v):
		count = maxi(v, 0)
		if is_inside_tree():
			_resize()
@export var spawn_radius: float = 30.0
@export var move_speed: float = 1.6
@export var stop_radius: float = 6.0
@export var churn_per_sec: float = 10.0
@export var respawn_delay: float = 1.5

@export_group("Shadows (section 17)")
@export var shadow_mode: String = "B":
	set(v):
		shadow_mode = v
		if is_inside_tree():
			_apply_shadow_mode()

const BODY_COLOR := Color(0.502, 0.161, 0.129)
const METAL_COLOR := Color(0.298, 0.310, 0.337)
const HIP_Y := 0.52

var _target: Node3D
var _rng := RandomNumberGenerator.new()

# --- unit state (data-oriented) ----------------------------------------------
var _pos := PackedVector3Array()
var _yaw := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _dead_t := PackedFloat32Array()
var _churn_acc := 0.0
var _time := 0.0

# --- draw layers --------------------------------------------------------------
var _layers: Array[MultiMeshInstance3D] = []
var _buffers: Array[PackedFloat32Array] = []
## part local offsets for the "parts" variant, in the same order as _layers
var _part_offsets: Array[Vector3] = []
var _part_leg: Array[float] = []          # -1 / 0 / +1
var _blob: MultiMeshInstance3D
var _blob_buf := PackedFloat32Array()


func _ready() -> void:
	_rng.seed = 20260821
	_target = get_node_or_null(target_path)
	_rebuild_layers()
	_resize()
	_apply_shadow_mode()


func arch_name() -> String:
	return "mm-" + variant


func alive_count() -> int:
	var n := 0
	for i in _dead_t.size():
		if _dead_t[i] <= 0.0:
			n += 1
	return n


func triangles_per_unit() -> int:
	var t := 0
	for m in _unit_parts():
		t += _tris(m[0])
	return t


# ------------------------------------------------------------------- geometry
func _unit_parts() -> Array:
	## [mesh, local offset, colour, leg sign, bob weight]
	var body := CapsuleMesh.new()
	body.radius = 0.31
	body.height = 1.24
	body.radial_segments = 10
	body.rings = 3
	var head := BoxMesh.new()
	head.size = Vector3(0.5, 0.36, 0.5)
	var gun := BoxMesh.new()
	gun.size = Vector3(0.18, 0.18, 1.1)
	var leg := BoxMesh.new()
	leg.size = Vector3(0.24, 0.52, 0.3)
	return [
		[body, Vector3(0, 0.92, 0), BODY_COLOR, 0.0, 1.0],
		[head, Vector3(0, 1.44, 0), METAL_COLOR, 0.0, 1.0],
		[gun, Vector3(0.3, 1.02, -0.62), METAL_COLOR, 0.0, 1.0],
		[leg, Vector3(-0.3, 0.26, 0), METAL_COLOR, -1.0, 0.0],
		[leg, Vector3(0.3, 0.26, 0), METAL_COLOR, 1.0, 0.0],
	]


static func _tris(m: Mesh) -> int:
	var a := m.surface_get_arrays(0)
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	if idx.size() > 0:
		return idx.size() / 3
	return (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func _merged_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	for part in _unit_parts():
		var m: Mesh = part[0]
		var off: Vector3 = part[1]
		var col: Color = part[2]
		var leg: float = part[3]
		var bob: float = part[4]
		var a := m.surface_get_arrays(0)
		var pv: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var nv: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var pi: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var base := verts.size()
		for i in pv.size():
			verts.append(pv[i] + off)
			norms.append(nv[i])
			cols.append(col)
			uv2.append(Vector2(leg, bob))
		if pi.size() > 0:
			for i in pi.size():
				idx.append(base + pi[i])
		else:
			for i in pv.size():
				idx.append(base + i)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var sm := ShaderMaterial.new()
	sm.shader = SHADER
	out.surface_set_material(0, sm)
	return out


# --------------------------------------------------------------------- layers
func _rebuild_layers() -> void:
	for l in _layers:
		l.queue_free()
	_layers.clear()
	_buffers.clear()
	_part_offsets.clear()
	_part_leg.clear()

	if variant == "merged":
		_add_layer("Crowd", _merged_mesh(), true)
		_part_offsets.append(Vector3.ZERO)
		_part_leg.append(0.0)
	else:
		var i := 0
		for part in _unit_parts():
			var m: Mesh = part[0]
			var mat := StandardMaterial3D.new()
			mat.albedo_color = part[2]
			mat.roughness = 0.45
			mat.metallic = 0.35
			(m as PrimitiveMesh).material = mat
			_add_layer("Part%d" % i, m, false)
			_part_offsets.append(part[1])
			_part_leg.append(part[3])
			i += 1

	if _blob == null:
		_make_blob_layer()
	_resize()
	_apply_shadow_mode()


func _add_layer(nm: String, mesh: Mesh, custom: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = custom
	mm.mesh = mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	add_child(mmi)
	_layers.append(mmi)
	_buffers.append(PackedFloat32Array())


func _make_blob_layer() -> void:
	var q := QuadMesh.new()
	q.size = Vector2(1.5, 1.5)
	q.orientation = PlaneMesh.FACE_Y
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	bm.albedo_color = Color(0.35, 0.33, 0.30, 1.0)
	bm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	q.material = bm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = q
	_blob = MultiMeshInstance3D.new()
	_blob.name = "BlobShadows"
	_blob.multimesh = mm
	_blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_blob.visible = false
	add_child(_blob)


func _apply_shadow_mode() -> void:
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow_mode == "A" \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for l in _layers:
		l.cast_shadow = cast
	if _blob:
		_blob.visible = shadow_mode == "C"


# ---------------------------------------------------------------------- crowd
func _resize() -> void:
	var n := count
	_pos.resize(n)
	_yaw.resize(n)
	_phase.resize(n)
	_dead_t.resize(n)
	for i in n:
		if _phase[i] == 0.0:
			_phase[i] = _rng.randf()
			_pos[i] = _spawn_point()
	var stride := 16 if variant == "merged" else 12
	for k in _layers.size():
		_layers[k].multimesh.instance_count = n
		_buffers[k].resize(n * stride)
	if _blob:
		_blob.multimesh.instance_count = n
		_blob_buf.resize(n * 12)


func _spawn_point() -> Vector3:
	var a := _rng.randf() * TAU
	var d: float = spawn_radius * (0.75 + 0.25 * _rng.randf())
	var c: Vector3 = _target.global_position if _target else Vector3.ZERO
	return Vector3(c.x + cos(a) * d, 0.0, c.z + sin(a) * d)


# --------------------------------------------------------------------- update
func _process(delta: float) -> void:
	if freeze_logic or count == 0:
		return
	_time += delta
	var tp: Vector3 = _target.global_position if _target else Vector3.ZERO

	_churn_acc += churn_per_sec * delta
	while _churn_acc >= 1.0:
		_churn_acc -= 1.0
		var k := _rng.randi() % count
		if _dead_t[k] <= 0.0:
			_dead_t[k] = respawn_delay

	for i in count:
		if _dead_t[i] > 0.0:
			_dead_t[i] -= delta
			if _dead_t[i] <= 0.0:
				_pos[i] = _spawn_point()
			continue
		var p: Vector3 = _pos[i]
		var d: Vector3 = tp - p
		d.y = 0.0
		var dist := d.length()
		if dist > stop_radius:
			_pos[i] = p + d / dist * move_speed * delta
			_yaw[i] = atan2(-d.x, -d.z)

	if variant == "merged":
		_write_merged()
	else:
		_write_parts()
	if shadow_mode == "C":
		_write_blobs()


func _write_merged() -> void:
	## 16 floats per instance: 12 transform + 4 custom data.
	var buf := _buffers[0]
	var j := 0
	for i in count:
		var dead: float = 1.0 if _dead_t[i] > 0.0 else 0.0
		var s: float = 0.0 if dead > 0.5 else 1.0
		var c := cos(_yaw[i]) * s
		var sn := sin(_yaw[i]) * s
		var p: Vector3 = _pos[i]
		buf[j] = c;      buf[j + 1] = 0.0; buf[j + 2] = sn;  buf[j + 3] = p.x
		buf[j + 4] = 0.0; buf[j + 5] = s;  buf[j + 6] = 0.0; buf[j + 7] = p.y
		buf[j + 8] = -sn; buf[j + 9] = 0.0; buf[j + 10] = c; buf[j + 11] = p.z
		buf[j + 12] = _phase[i]
		buf[j + 13] = dead
		buf[j + 14] = 0.0
		buf[j + 15] = 0.0
		j += 16
	_layers[0].multimesh.set_buffer(buf)


func _write_parts() -> void:
	## The CPU does what the Node version does: a transform per part per unit,
	## leg swing included.
	for k in _layers.size():
		var buf := _buffers[k]
		var off: Vector3 = _part_offsets[k]
		var leg: float = _part_leg[k]
		var j := 0
		for i in count:
			var dead: bool = _dead_t[i] > 0.0
			var s: float = 0.0 if dead else 1.0
			var yaw: float = _yaw[i]
			var cy := cos(yaw)
			var sy := sin(yaw)
			var swing: float = sin(_time * 6.0 + _phase[i] * TAU)
			var local := off
			if leg != 0.0:
				var a: float = swing * 0.55 * leg
				var q := local - Vector3(0.0, HIP_Y, 0.0)
				var ca := cos(a)
				var sa := sin(a)
				q = Vector3(q.x, q.y * ca - q.z * sa, q.y * sa + q.z * ca)
				local = q + Vector3(0.0, HIP_Y, 0.0)
			else:
				local.y += absf(swing) * 0.05
			var wx: float = _pos[i].x + local.x * cy + local.z * sy
			var wz: float = _pos[i].z - local.x * sy + local.z * cy
			buf[j] = cy * s;   buf[j + 1] = 0.0; buf[j + 2] = sy * s; buf[j + 3] = wx
			buf[j + 4] = 0.0;  buf[j + 5] = s;   buf[j + 6] = 0.0;    buf[j + 7] = _pos[i].y + local.y
			buf[j + 8] = -sy * s; buf[j + 9] = 0.0; buf[j + 10] = cy * s; buf[j + 11] = wz
			j += 12
		_layers[k].multimesh.set_buffer(buf)


func _write_blobs() -> void:
	var j := 0
	for i in count:
		var s: float = 0.0 if _dead_t[i] > 0.0 else 1.0
		var p: Vector3 = _pos[i]
		_blob_buf[j] = s;    _blob_buf[j + 1] = 0.0; _blob_buf[j + 2] = 0.0; _blob_buf[j + 3] = p.x
		_blob_buf[j + 4] = 0.0; _blob_buf[j + 5] = s; _blob_buf[j + 6] = 0.0; _blob_buf[j + 7] = 0.03
		_blob_buf[j + 8] = 0.0; _blob_buf[j + 9] = 0.0; _blob_buf[j + 10] = s; _blob_buf[j + 11] = p.z
		j += 12
	_blob.multimesh.set_buffer(_blob_buf)
