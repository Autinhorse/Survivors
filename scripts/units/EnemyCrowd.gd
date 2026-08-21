extends Node3D
## Milestone 4 crowd: the CONVENTIONAL NODE architecture (doc section 6, 方案 A).
##
## Each enemy is a real Node3D with separate MeshInstance3D parts:
##     Enemy -> Body / Head / Gun / LeftLeg / RightLeg
## ~150 triangles per unit, inside the 100-300 budget from section 4.1.
##
## Logic is deliberately the minimum from section 22: Spawn -> Move -> Hit ->
## Death.  No navigation, no pathfinding, no formations, no target search.
##
## One deliberate choice worth stating: the per-frame update runs as a single
## loop in THIS script rather than a `_process` on every enemy node.  That is
## the realistic Node-architecture implementation; attaching a script with
## `_process` to 1000 nodes is a strictly worse variant, left for Milestone 5.
##
## `freeze_logic` stops the update loop entirely.  It is not a shipping mode --
## it is the measurement floor: whatever remains is pure scene-tree + draw-call
## cost, which is how the crowd's CPU time gets split from the renderer's.
##
## Legs and body are animated procedurally (section 7): sin() driven, each unit
## carrying its own phase so the crowd never swings in lockstep.

@export var target_path: NodePath
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
## Deaths per second.  Nothing shoots during the crowd benchmark (section 23
## keeps VFX load separate), so the churn is self-inflicted to keep the
## spawn/death path represented in the measurement.
@export var churn_per_sec: float = 10.0
@export var respawn_delay: float = 1.5

@export_group("Shadows (section 17)")
## "A" = every unit casts a real shadow
## "B" = units cast nothing (environment/player/boss still do)
## "C" = no real shadow, one batched blob shadow quad per unit
@export var shadow_mode: String = "B":
	set(v):
		shadow_mode = v
		if is_inside_tree():
			_apply_shadow_mode()

var _target: Node3D
var _rng := RandomNumberGenerator.new()

# parallel arrays: the node hierarchy is the thing under test, the bookkeeping
# around it should not itself become the bottleneck
var _nodes: Array[Node3D] = []
var _legL: Array[Node3D] = []
var _legR: Array[Node3D] = []
var _body: Array[Node3D] = []
var _phase := PackedFloat32Array()
var _dead_t := PackedFloat32Array()
var _churn_acc := 0.0
var _time := 0.0

var _mesh_body: Mesh
var _mesh_head: Mesh
var _mesh_gun: Mesh
var _mesh_leg: Mesh
var _mat_body: Material
var _mat_metal: Material

var _blob_mm: MultiMesh
var _blob_node: MultiMeshInstance3D


func _ready() -> void:
	_rng.seed = 20260821
	_target = get_node_or_null(target_path)
	_make_shared_resources()
	_make_blob_layer()
	_resize()
	_apply_shadow_mode()


func arch_name() -> String:
	return "node-frozen" if freeze_logic else "node"


func alive_count() -> int:
	var n := 0
	for i in _dead_t.size():
		if _dead_t[i] <= 0.0:
			n += 1
	return n


func triangles_per_unit() -> int:
	var t := 0
	for m in [_mesh_body, _mesh_head, _mesh_gun, _mesh_leg, _mesh_leg]:
		t += _mesh_tris(m)
	return t


static func _mesh_tris(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		var arrays := m.surface_get_arrays(s)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.size() > 0:
			n += idx.size() / 3
		else:
			n += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


# ------------------------------------------------------------------ resources
func _make_shared_resources() -> void:
	var body := CapsuleMesh.new()
	body.radius = 0.31
	body.height = 1.24
	body.radial_segments = 10
	body.rings = 3
	_mesh_body = body

	var head := BoxMesh.new()
	head.size = Vector3(0.5, 0.36, 0.5)
	_mesh_head = head

	var gun := BoxMesh.new()
	gun.size = Vector3(0.18, 0.18, 1.1)
	_mesh_gun = gun

	var leg := BoxMesh.new()
	leg.size = Vector3(0.24, 0.52, 0.3)
	_mesh_leg = leg

	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.502, 0.161, 0.129)
	m.roughness = 0.58
	m.metallic = 0.25
	_mat_body = m

	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.298, 0.310, 0.337)
	mm.roughness = 0.42
	mm.metallic = 0.65
	_mat_metal = mm


func _make_blob_layer() -> void:
	var q := QuadMesh.new()
	q.size = Vector2(1.5, 1.5)
	q.orientation = PlaneMesh.FACE_Y
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	bm.albedo_color = Color(0.35, 0.33, 0.30, 1.0)
	bm.albedo_texture = _blob_texture()
	bm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	bm.no_depth_test = false
	q.material = bm

	_blob_mm = MultiMesh.new()
	_blob_mm.transform_format = MultiMesh.TRANSFORM_3D
	_blob_mm.mesh = q
	_blob_node = MultiMeshInstance3D.new()
	_blob_node.name = "BlobShadows"
	_blob_node.multimesh = _blob_mm
	_blob_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_blob_node.visible = false
	add_child(_blob_node)


static func _blob_texture(size := 32) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c: float = (size - 1) * 0.5
	for y in size:
		for x in size:
			var d: float = Vector2(x - c, y - c).length() / c
			var a: float = pow(clampf(1.0 - d, 0.0, 1.0), 1.6)
			# MUL blend: white = untouched ground, dark = shadow
			var v: float = 1.0 - a * 0.75
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------- crowd
func _resize() -> void:
	while _nodes.size() > count:
		var n: Node3D = _nodes.pop_back()
		_legL.pop_back()
		_legR.pop_back()
		_body.pop_back()
		n.queue_free()
	while _nodes.size() < count:
		_spawn_one()
	_phase.resize(_nodes.size())
	_dead_t.resize(_nodes.size())
	for i in _nodes.size():
		if _phase[i] == 0.0:
			_phase[i] = _rng.randf() * TAU
	if _blob_mm:
		_blob_mm.instance_count = _nodes.size()
	_apply_shadow_mode()


func _spawn_one() -> void:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	body.mesh = _mesh_body
	body.material_override = _mat_body
	body.position = Vector3(0, 0.92, 0)
	root.add_child(body)

	var head := MeshInstance3D.new()
	head.mesh = _mesh_head
	head.material_override = _mat_metal
	head.position = Vector3(0, 1.44, 0)
	root.add_child(head)

	var gun := MeshInstance3D.new()
	gun.mesh = _mesh_gun
	gun.material_override = _mat_metal
	gun.position = Vector3(0.3, 1.02, -0.62)
	root.add_child(gun)

	var l := MeshInstance3D.new()
	l.mesh = _mesh_leg
	l.material_override = _mat_metal
	l.position = Vector3(-0.3, 0.26, 0)
	root.add_child(l)

	var r := MeshInstance3D.new()
	r.mesh = _mesh_leg
	r.material_override = _mat_metal
	r.position = Vector3(0.3, 0.26, 0)
	root.add_child(r)

	add_child(root)
	root.global_position = _spawn_point()
	_nodes.append(root)
	_body.append(body)
	_legL.append(l)
	_legR.append(r)


func _spawn_point() -> Vector3:
	var a := _rng.randf() * TAU
	var d: float = spawn_radius * (0.75 + 0.25 * _rng.randf())
	var c: Vector3 = _target.global_position if _target else Vector3.ZERO
	return Vector3(c.x + cos(a) * d, 0.0, c.z + sin(a) * d)


func _apply_shadow_mode() -> void:
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow_mode == "A" \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for n in _nodes:
		for c in n.get_children():
			(c as GeometryInstance3D).cast_shadow = cast
	if _blob_node:
		_blob_node.visible = shadow_mode == "C"


# --------------------------------------------------------------------- update
func _process(delta: float) -> void:
	if freeze_logic or _nodes.is_empty():
		return
	_time += delta
	var tp: Vector3 = _target.global_position if _target else Vector3.ZERO

	# churn: Hit -> Death -> Spawn, at a fixed rate
	_churn_acc += churn_per_sec * delta
	while _churn_acc >= 1.0:
		_churn_acc -= 1.0
		var k := _rng.randi() % _nodes.size()
		if _dead_t[k] <= 0.0:
			_dead_t[k] = respawn_delay
			_nodes[k].visible = false

	var blob_visible: bool = shadow_mode == "C" 			and _blob_mm != null and _blob_mm.instance_count >= _nodes.size()
	for i in _nodes.size():
		var n: Node3D = _nodes[i]
		if _dead_t[i] > 0.0:
			_dead_t[i] -= delta
			if _dead_t[i] <= 0.0:
				n.global_position = _spawn_point()
				n.visible = true
			elif blob_visible:
				_blob_mm.set_instance_transform(i,
						Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
			continue

		var p: Vector3 = n.global_position
		var d: Vector3 = tp - p
		d.y = 0.0
		var dist := d.length()
		if dist > stop_radius:
			n.global_position = p + d / dist * move_speed * delta
			n.rotation.y = atan2(-d.x, -d.z)

		# procedural mechanical animation (section 7)
		var ph: float = _phase[i]
		var swing: float = sin(_time * 6.0 + ph)
		_legL[i].rotation.x = swing * 0.55
		_legR[i].rotation.x = -swing * 0.55
		_body[i].position.y = 0.92 + absf(swing) * 0.05

		if blob_visible:
			_blob_mm.set_instance_transform(i, Transform3D(Basis(),
					Vector3(n.global_position.x, 0.03, n.global_position.z)))
