@tool
extends Node3D
## Pooled combat VFX: tracers, flashes, sparks, smoke, explosions, arcs.
##
## Everything here is pooled and batched, because Milestone 3 feeds straight
## into the section 23 stress test (up to ~1000 projectiles / 100 explosions per
## second).  Anything that allocates a node per shot would measure the allocator
## instead of the renderer.
##
## Layout:
##   tracers   -> one MultiMesh, transforms written from packed float arrays
##   puffs     -> one MultiMesh per mesh kind (flash / ring / billboard)
##   particles -> a small ring buffer of one-shot GPUParticles3D emitters
##   rockets   -> pooled node + continuously emitting trail
##   arcs      -> a single ImmediateMesh rebuilt each frame
##
## Doc section 16: no dynamic light is created per explosion.  `explosion_light`
## exists only so Milestone 4 can measure what that choice actually saves.

const VFX = preload("res://scripts/vfx/VfxCommon.gd")

const MAX_TRACERS := 2048
const MAX_PUFFS := 1024
const SPARK_EMITTERS := 14
const SMOKE_EMITTERS := 10
const DEBRIS_EMITTERS := 8
const MAX_ROCKETS := 96
const MAX_ARCS := 12

@export var explosion_light: bool = false   ## section 17/23 A-B switch
## Manual-emission pool size, 0 = do not create the mass emitters at all.
##
## These pools are drawn every frame whether or not any particle is alive ——
## measured at ~138k extra primitives per frame while completely idle.
## Only the section 23 stress test needs them; the gameplay scene must not
## pay for a load it never produces.
@export var mass_pool: int = 0
@export var tracer_width: float = 0.13
@export var tracer_length: float = 3.2

# --- tracers (packed, data-oriented) -----------------------------------------
var _tr_pos := PackedVector3Array()
var _tr_vel := PackedVector3Array()
var _tr_life := PackedFloat32Array()
var _tr_count := 0
var _tracer_mm: MultiMesh

# --- puffs --------------------------------------------------------------------
class Puff:
	var pos: Vector3
	var basis: Basis
	var life := 0.0
	var max_life := 0.2
	var s0 := 1.0
	var s1 := 2.0
	var c0 := Color(1, 1, 1, 1)
	var c1 := Color(0, 0, 0, 0)

var _puffs := {}          # layer name -> Array[Puff]
var _puff_mm := {}        # layer name -> MultiMesh

# --- particle emitters --------------------------------------------------------
var _sparks: Array[GPUParticles3D] = []
var _smoke: Array[GPUParticles3D] = []
var _debris: Array[GPUParticles3D] = []
var _spark_i := 0
var _smoke_i := 0
var _debris_i := 0

# --- rockets ------------------------------------------------------------------
class Rocket:
	var node: Node3D
	var trail: GPUParticles3D
	var pos: Vector3
	var vel: Vector3
	var target: Vector3
	var alive := false
	var cooldown := 0.0

var _rockets: Array[Rocket] = []

# --- arcs ---------------------------------------------------------------------
class Arc:
	var points: PackedVector3Array
	var life := 0.0
	var max_life := 0.18
	var width := 0.16
	var seed_ := 0

var _arcs: Array[Arc] = []
var _arc_mesh: ImmediateMesh
var _arc_node: MeshInstance3D
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 424242
	_build_tracers()
	# Soft billboard sprite, not a low-poly sphere: an additive sphere at this
	# size reads as a flat octagon, which is exactly what a fireball must not be.
	_build_puff_layer("flash", VFX.quad(1.0), Color(1.0, 1.0, 1.0, 1.0),
			VFX.soft_sprite(64, 1.35, true), true)
	_build_puff_layer("ring", VFX.ring_mesh(), Color(1.0, 1.0, 1.0, 1.0))
	_build_puff_layer("muzzle", VFX.unit_box(), Color(1.0, 1.0, 1.0, 1.0))
	_build_particles()
	_build_rockets()
	_build_arcs()
	set_process(true)


# ------------------------------------------------------------------ public API
func fire_tracer(from: Vector3, to: Vector3, speed := 130.0) -> void:
	if _tr_count >= MAX_TRACERS:
		return
	var d := to - from
	var dist := d.length()
	if dist < 0.01:
		return
	var dir := d / dist
	_tr_pos[_tr_count] = from
	_tr_vel[_tr_count] = dir * speed
	_tr_life[_tr_count] = dist / speed
	_tr_count += 1
	muzzle_flash(from, dir)


func muzzle_flash(pos: Vector3, dir: Vector3, size := 1.0) -> void:
	var p := Puff.new()
	p.pos = pos + dir * 0.35
	p.basis = Basis.looking_at(dir)
	p.max_life = 0.05
	p.s0 = 0.30 * size
	p.s1 = 0.62 * size
	p.c0 = Color(2.6, 1.35, 0.45, 1.0)
	p.c1 = Color(0.7, 0.22, 0.05, 0.0)
	_add_puff("muzzle", p)


func hit_flash(pos: Vector3, size := 1.0, warm := true) -> void:
	var p := Puff.new()
	p.pos = pos
	p.basis = Basis()
	p.max_life = 0.10
	p.s0 = 0.35 * size
	p.s1 = 1.15 * size
	p.c0 = Color(3.0, 1.45, 0.5, 1.0) if warm else Color(0.7, 1.9, 3.6, 1.0)
	p.c1 = Color(0.5, 0.18, 0.04, 0.0) if warm else Color(0.15, 0.4, 0.9, 0.0)
	_add_puff("flash", p)


func spark(pos: Vector3) -> void:
	_fire_emitter(_sparks, _spark_i, pos)
	_spark_i = (_spark_i + 1) % _sparks.size()


func explosion(pos: Vector3, scale := 1.0) -> void:
	# fireball
	var f := Puff.new()
	f.pos = pos + Vector3(0.0, 0.6 * scale, 0.0)
	f.basis = Basis()
	f.max_life = 0.38
	f.s0 = 1.1 * scale
	f.s1 = 5.2 * scale
	f.c0 = Color(3.4, 1.25, 0.28, 1.0)
	f.c1 = Color(0.8, 0.16, 0.02, 0.0)
	_add_puff("flash", f)

	# ground shockwave
	var r := Puff.new()
	r.pos = pos + Vector3(0.0, 0.12, 0.0)
	r.basis = Basis()
	r.max_life = 0.42
	r.s0 = 1.2 * scale
	r.s1 = 9.0 * scale
	r.c0 = Color(1.7, 0.85, 0.3, 1.0)
	r.c1 = Color(0.35, 0.13, 0.03, 0.0)
	_add_puff("ring", r)

	_fire_emitter(_smoke, _smoke_i, pos + Vector3(0, 0.5 * scale, 0))
	_smoke_i = (_smoke_i + 1) % _smoke.size()
	_fire_emitter(_debris, _debris_i, pos)
	_debris_i = (_debris_i + 1) % _debris.size()
	spark(pos)

	if explosion_light:
		_flash_light(pos, scale)


func explosion_mass(pos: Vector3, scale := 1.0) -> void:
	if _mass_smoke == null:
		explosion(pos, scale)      # 没建大池子就退回普通路径
		return
	## Same look as explosion(), but the particles go through the manual-emission
	## emitters so hundreds of bursts can overlap without truncating each other.
	var f := Puff.new()
	f.pos = pos + Vector3(0.0, 0.6 * scale, 0.0)
	f.basis = Basis()
	f.max_life = 0.38
	f.s0 = 1.1 * scale
	f.s1 = 5.2 * scale
	f.c0 = Color(3.4, 1.25, 0.28, 1.0)
	f.c1 = Color(0.8, 0.16, 0.02, 0.0)
	_add_puff("flash", f)

	var r := Puff.new()
	r.pos = pos + Vector3(0.0, 0.12, 0.0)
	r.basis = Basis()
	r.max_life = 0.42
	r.s0 = 1.2 * scale
	r.s1 = 9.0 * scale
	r.c0 = Color(1.7, 0.85, 0.3, 1.0)
	r.c1 = Color(0.35, 0.13, 0.03, 0.0)
	_add_puff("ring", r)

	mass_burst("smoke", pos + Vector3(0, 0.5 * scale, 0), 18)
	mass_burst("debris", pos, 12)
	mass_burst("spark", pos, 20)

	if explosion_light:
		_flash_light(pos, scale)


func launch_rocket(from: Vector3, to: Vector3, speed := 26.0) -> void:
	for r in _rockets:
		if r.alive:
			continue
		r.alive = true
		r.pos = from
		r.target = to
		r.vel = (to - from).normalized() * speed
		r.node.visible = true
		r.node.global_position = from
		r.trail.emitting = true
		muzzle_flash(from, r.vel.normalized(), 1.5)
		return


func add_arc(points: PackedVector3Array, life := 0.18, width := 0.16) -> void:
	if _arcs.size() >= MAX_ARCS:
		return
	var a := Arc.new()
	a.points = points
	a.max_life = life
	a.width = width
	a.seed_ = _rng.randi()
	_arcs.append(a)


# ---------------------------------------------------------------------- build
func _build_tracers() -> void:
	_tr_pos.resize(MAX_TRACERS)
	_tr_vel.resize(MAX_TRACERS)
	_tr_life.resize(MAX_TRACERS)
	_tracer_mm = MultiMesh.new()
	_tracer_mm.transform_format = MultiMesh.TRANSFORM_3D
	_tracer_mm.use_colors = true
	var tracer_mesh := VFX.unit_box()
	tracer_mesh.material = VFX.additive(Color(2.8, 1.15, 0.35, 1.0))
	_tracer_mm.mesh = tracer_mesh
	_tracer_mm.instance_count = MAX_TRACERS
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Tracers"
	mmi.multimesh = _tracer_mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	for i in MAX_TRACERS:
		_tracer_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO),
				Vector3.ZERO))


func _build_puff_layer(nm: String, mesh: Mesh, tint: Color,
		sprite: Texture2D = null, billboard := false) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var mat := VFX.additive(tint)
	if sprite:
		mat.albedo_texture = sprite
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale = true
	# PrimitiveMesh keeps its material in `material`; only ArrayMesh has surfaces.
	if mesh is PrimitiveMesh:
		(mesh as PrimitiveMesh).material = mat
	else:
		mesh.surface_set_material(0, mat)
	mm.instance_count = MAX_PUFFS
	for i in MAX_PUFFS:
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO),
				Vector3.ZERO))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Puff_" + nm
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_puff_mm[nm] = mm
	_puffs[nm] = []


## Manual-emission burst emitters.
##
## The M3 ring buffer of one-shot emitters is fine at gameplay rates, but the
## section 23 stress test asks for up to 100 explosions/sec.  With a 2 s smoke
## lifetime that needs ~200 concurrent bursts; recycling 10 emitters would cut
## every plume short and under-report exactly the smoke overdraw section 15
## warns about.  Growing the pool instead would measure emitter-node overhead.
##
## So the stress path uses ONE emitter per effect type with a large `amount`,
## `amount_ratio = 0` (no automatic emission, system still processing) and
## `emit_particle()` placing every particle by hand.  One draw call, no ceiling
## on concurrent bursts.
var _mass_spark: GPUParticles3D
var _mass_smoke: GPUParticles3D
var _mass_debris: GPUParticles3D


func _make_mass_emitter(amount: int, lifetime: float, mesh: Mesh,
		pm: ParticleProcessMaterial) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.one_shot = false
	# `amount_ratio = 0` also zeroes the particle POOL, so emit_particle() has no
	# free slots and silently emits nothing.  `emitting = false` is the correct
	# way to stop automatic emission while keeping the pool and the simulation.
	p.emitting = false
	p.local_coords = false
	p.draw_pass_1 = mesh
	p.process_material = pm
	p.visibility_aabb = AABB(Vector3(-60, -20, -60), Vector3(120, 40, 120))
	add_child(p)
	return p


func mass_burst(kind: String, pos: Vector3, n: int) -> void:
	var e: GPUParticles3D = null
	var speed := 6.0
	match kind:
		"spark":
			e = _mass_spark
			speed = 9.0
		"smoke":
			e = _mass_smoke
			speed = 3.0
		"debris":
			e = _mass_debris
			speed = 10.0
	if e == null:
		return
	var flags := 1 | 4          # EMIT_FLAG_POSITION | EMIT_FLAG_VELOCITY
	for i in n:
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.1, 1.0),
				_rng.randf_range(-1.0, 1.0)).normalized()
		var xf := Transform3D(Basis(), pos + dir * 0.3)
		e.emit_particle(xf, dir * speed * _rng.randf_range(0.5, 1.0),
				Color.WHITE, Color.WHITE, flags)


func _build_particles() -> void:
	var dot := VFX.soft_sprite(32, 2.4)
	var puff := VFX.soft_sprite(64, 1.5, true)
	var chunk := VFX.soft_sprite(16, 5.0)

	var spark_mesh := VFX.quad(0.20)
	spark_mesh.material = VFX.particle_mat(Color(5.0, 2.6, 1.0, 1.0), true, dot)
	for i in SPARK_EMITTERS:
		var p := VFX.make_burst(22, 0.55, spark_mesh, VFX.spark_process())
		add_child(p)
		_sparks.append(p)

	var smoke_mesh := VFX.quad(1.1)
	smoke_mesh.material = VFX.particle_mat(Color(1, 1, 1, 1), false, puff)
	for i in SMOKE_EMITTERS:
		var p := VFX.make_burst(20, 2.1, smoke_mesh, VFX.smoke_process(1.7, 3.6))
		add_child(p)
		_smoke.append(p)

	var debris_mesh := VFX.quad(0.24)
	debris_mesh.material = VFX.particle_mat(Color(1, 1, 1, 1), false, chunk)
	for i in DEBRIS_EMITTERS:
		var p := VFX.make_burst(14, 1.1, debris_mesh, VFX.debris_process())
		add_child(p)
		_debris.append(p)

	if mass_pool > 0:
		_mass_spark = _make_mass_emitter(mass_pool, 0.55, spark_mesh,
				VFX.spark_process())
		_mass_smoke = _make_mass_emitter(mass_pool, 2.1, smoke_mesh,
				VFX.smoke_process(1.7, 3.6))
		_mass_debris = _make_mass_emitter(maxi(mass_pool / 2, 1), 1.1, debris_mesh,
				VFX.debris_process())


func _build_rockets() -> void:
	var body := VFX.unit_box()
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.55, 0.12, 0.08)
	body_mat.emission_enabled = true
	body_mat.emission = Color(2.4, 0.7, 0.15)
	body_mat.emission_energy_multiplier = 1.6
	body.material = body_mat

	var trail_mesh := VFX.quad(0.62)
	trail_mesh.material = VFX.particle_mat(Color(1, 1, 1, 1), false,
			VFX.soft_sprite(48, 1.6, true))

	for i in MAX_ROCKETS:
		var r := Rocket.new()
		r.node = Node3D.new()
		r.node.name = "Rocket%d" % i
		r.node.visible = false
		var mi := MeshInstance3D.new()
		mi.mesh = body
		mi.scale = Vector3(0.22, 0.22, 0.9)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		r.node.add_child(mi)
		var tr := GPUParticles3D.new()
		tr.amount = 26
		tr.lifetime = 1.25
		tr.emitting = false
		tr.local_coords = false
		tr.draw_pass_1 = trail_mesh
		tr.process_material = VFX.smoke_process(0.7, 1.1)
		tr.visibility_aabb = AABB(Vector3(-30, -10, -30), Vector3(60, 20, 60))
		r.node.add_child(tr)
		r.trail = tr
		add_child(r.node)
		_rockets.append(r)


func _build_arcs() -> void:
	_arc_mesh = ImmediateMesh.new()
	_arc_node = MeshInstance3D.new()
	_arc_node.name = "Arcs"
	_arc_node.mesh = _arc_mesh
	_arc_node.material_override = VFX.additive(Color(0.55, 1.5, 3.4, 1.0))
	_arc_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arc_node)


# --------------------------------------------------------------------- update
func _process(delta: float) -> void:
	_update_tracers(delta)
	_update_puffs(delta)
	_update_rockets(delta)
	_update_arcs(delta)


func _update_tracers(delta: float) -> void:
	var i := 0
	while i < _tr_count:
		_tr_life[i] -= delta
		if _tr_life[i] <= 0.0:
			_tr_count -= 1
			_tr_pos[i] = _tr_pos[_tr_count]
			_tr_vel[i] = _tr_vel[_tr_count]
			_tr_life[i] = _tr_life[_tr_count]
			continue
		_tr_pos[i] += _tr_vel[i] * delta
		i += 1

	for j in MAX_TRACERS:
		if j < _tr_count:
			var dir: Vector3 = _tr_vel[j].normalized()
			var b := Basis.looking_at(dir)
			b = b.scaled(Vector3(tracer_width, tracer_width, tracer_length))
			_tracer_mm.set_instance_transform(j, Transform3D(b, _tr_pos[j]))
			_tracer_mm.set_instance_color(j, Color(1, 1, 1, 1))
		else:
			_tracer_mm.set_instance_transform(j,
					Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))


func _add_puff(layer: String, p: Puff) -> void:
	var arr: Array = _puffs[layer]
	if arr.size() >= MAX_PUFFS:
		return
	arr.append(p)


func _update_puffs(delta: float) -> void:
	for layer in _puffs.keys():
		var arr: Array = _puffs[layer]
		var mm: MultiMesh = _puff_mm[layer]
		var i := 0
		while i < arr.size():
			var p: Puff = arr[i]
			p.life += delta
			if p.life >= p.max_life:
				arr.remove_at(i)
				continue
			i += 1
		for j in MAX_PUFFS:
			if j < arr.size():
				var p: Puff = arr[j]
				var t: float = p.life / p.max_life
				var s: float = lerpf(p.s0, p.s1, t)
				mm.set_instance_transform(j,
						Transform3D(p.basis.scaled(Vector3.ONE * s), p.pos))
				mm.set_instance_color(j, p.c0.lerp(p.c1, t))
			else:
				mm.set_instance_transform(j,
						Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))


func _update_rockets(delta: float) -> void:
	for r in _rockets:
		if not r.alive:
			if r.cooldown > 0.0:
				r.cooldown -= delta
				if r.cooldown <= 0.0:
					r.node.visible = false
			continue
		var step: Vector3 = r.vel * delta
		var remaining: float = r.pos.distance_to(r.target)
		if step.length() >= remaining:
			r.pos = r.target
			r.alive = false
			r.trail.emitting = false
			r.cooldown = 2.0          # let the trail finish before hiding
			explosion(r.pos, 1.0)
		else:
			r.pos += step
		r.node.global_position = r.pos
		if r.vel.length_squared() > 0.001:
			r.node.basis = Basis.looking_at(r.vel.normalized())


func _update_arcs(delta: float) -> void:
	_arc_mesh.clear_surfaces()
	var i := 0
	while i < _arcs.size():
		_arcs[i].life += delta
		if _arcs[i].life >= _arcs[i].max_life:
			_arcs.remove_at(i)
			continue
		i += 1
	if _arcs.is_empty():
		return

	_arc_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for a in _arcs:
		var fade: float = 1.0 - a.life / a.max_life
		_emit_arc(a, fade)
	_arc_mesh.surface_end()


func _emit_arc(a: Arc, fade: float) -> void:
	## Flat ribbon in the horizontal plane: from a 60-degree camera that reads
	## as a bolt, and it avoids needing camera-facing geometry.
	var rng := RandomNumberGenerator.new()
	for seg in a.points.size() - 1:
		var p0: Vector3 = a.points[seg]
		var p1: Vector3 = a.points[seg + 1]
		var steps := 7
		var prev := p0
		for k in range(1, steps + 1):
			var t := float(k) / float(steps)
			var straight: Vector3 = p0.lerp(p1, t)
			rng.seed = a.seed_ + seg * 977 + k * 131 \
					+ int(a.life * 90.0) * 7919
			var jitter := 0.0 if k == steps else 0.55
			var side: Vector3 = (p1 - p0).cross(Vector3.UP).normalized()
			var cur: Vector3 = straight \
					+ side * rng.randf_range(-jitter, jitter) \
					+ Vector3.UP * rng.randf_range(-jitter, jitter) * 0.5
			_ribbon(prev, cur, a.width * fade)
			prev = cur


func _ribbon(p0: Vector3, p1: Vector3, w: float) -> void:
	var dir := p1 - p0
	if dir.length_squared() < 1e-8:
		return
	var side := dir.normalized().cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = Vector3.RIGHT
	side = side.normalized() * w
	var a := p0 - side
	var b := p0 + side
	var c := p1 + side
	var d := p1 - side
	for v in [a, b, c, a, c, d]:
		_arc_mesh.surface_add_vertex(v)


func _fire_emitter(pool: Array, idx: int, pos: Vector3) -> void:
	var p: GPUParticles3D = pool[idx]
	p.global_position = pos
	p.restart()
	p.emitting = true


func _flash_light(pos: Vector3, scale: float) -> void:
	## Deliberately off by default (doc section 16).  Kept so Milestone 4 can
	## measure the cost of the alternative instead of arguing about it.
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.62, 0.28)
	l.light_energy = 6.0 * scale
	l.omni_range = 12.0 * scale
	l.shadow_enabled = false
	l.position = pos + Vector3(0, 1.0, 0)
	add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.35)
	tw.tween_callback(l.queue_free)
