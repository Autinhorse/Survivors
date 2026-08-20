@tool
class_name VfxCommon
extends RefCounted
## Shared material / mesh / particle factories for the combat VFX.
##
## Built in code rather than in the scene file on purpose: particle and blend
## settings are a long list of enums, and getting one of them wrong in .tscn
## text fails silently (see the M2 findings in docs/M2_visual_报告.md).
##
## Doc section 16: the glow comes from emissive geometry and particles, NOT from
## a real light per explosion.  Every colour below is deliberately > 1.0 so it
## crosses the environment's glow HDR threshold and blooms.


## Unshaded additive material -- the workhorse for tracers, flashes and arcs.
static func additive(color: Color, double_sided := true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = color
	m.vertex_color_use_as_albedo = true
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.disable_receive_shadows = true
	if double_sided:
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Alpha-blended smoke: NOT additive.  Additive smoke reads as light, not as
## smoke, and stacks into a white blob when explosions overlap.
static func smoke_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.albedo_color = color
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.disable_receive_shadows = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 1.0
	return m


static func particle_mat(color: Color, additive_blend := true,
		sprite: Texture2D = null) -> StandardMaterial3D:
	var m := additive(color) if additive_blend else smoke_mat(color)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	# Without a texture a QuadMesh particle is a hard-edged square with uniform
	# alpha -- it reads as white paper, not as smoke or a spark.  The sprite is
	# generated in code so the project still ships with no texture files.
	if sprite:
		m.albedo_texture = sprite
	return m


## Radial falloff sprite, optionally broken up by noise (for smoke).
static func soft_sprite(size := 64, power := 2.0, noisy := false) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c: float = (size - 1) * 0.5
	var fnl: FastNoiseLite = null
	if noisy:
		fnl = FastNoiseLite.new()
		fnl.frequency = 0.05
		fnl.fractal_octaves = 3
	for y in size:
		for x in size:
			var d: float = Vector2(x - c, y - c).length() / c
			var a: float = pow(clampf(1.0 - d, 0.0, 1.0), power)
			if fnl:
				a *= 0.45 + 0.85 * (fnl.get_noise_2d(float(x), float(y)) * 0.5 + 0.5)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


static func gradient_tex(colors: Array, offsets: Array = []) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets) if offsets.size() == colors.size() \
			else PackedFloat32Array(_even_offsets(colors.size()))
	g.colors = PackedColorArray(colors)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


static func _even_offsets(n: int) -> Array:
	var out := []
	for i in n:
		out.append(float(i) / maxf(float(n - 1), 1.0))
	return out


static func curve_tex(points: Array) -> CurveTexture:
	## points: [[x, y], ...] in 0..1
	var c := Curve.new()
	for p in points:
		c.add_point(Vector2(p[0], p[1]))
	var t := CurveTexture.new()
	t.curve = c
	return t


static func quad(size: float) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	return q


static func unit_box() -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3.ONE
	return b


static func unit_sphere(segments := 8, rings := 4) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = 0.5
	s.height = 1.0
	s.radial_segments = segments
	s.rings = rings
	return s


## Flat ring used for the explosion shockwave; lies in the XZ plane.
static func ring_mesh(inner := 0.34, outer := 0.5, segments := 20) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for i in segments:
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var p0i := Vector3(cos(a0) * inner, 0.0, sin(a0) * inner)
		var p0o := Vector3(cos(a0) * outer, 0.0, sin(a0) * outer)
		var p1i := Vector3(cos(a1) * inner, 0.0, sin(a1) * inner)
		var p1o := Vector3(cos(a1) * outer, 0.0, sin(a1) * outer)
		for v in [p0i, p0o, p1o, p0i, p1o, p1i]:
			verts.append(v)
			norms.append(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## One-shot particle emitter, pooled and re-fired by VfxManager.
static func make_burst(amount: int, lifetime: float, mesh: Mesh,
		process: ParticleProcessMaterial) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.draw_pass_1 = mesh
	p.process_material = process
	p.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	return p


static func spark_process() -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.12
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 75.0
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 11.0
	pm.gravity = Vector3(0, -14.0, 0)
	pm.damping_min = 1.0
	pm.damping_max = 3.0
	pm.scale_min = 0.5
	pm.scale_max = 1.2
	pm.scale_curve = curve_tex([[0.0, 1.0], [1.0, 0.0]])
	pm.color_ramp = gradient_tex([
		Color(3.0, 1.7, 0.6, 1.0), Color(1.7, 0.55, 0.14, 1.0),
		Color(0.6, 0.15, 0.03, 0.0)])
	return pm


static func smoke_process(rise: float, spread_vel: float) -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.35
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 40.0
	pm.initial_velocity_min = spread_vel * 0.4
	pm.initial_velocity_max = spread_vel
	pm.gravity = Vector3(0, rise, 0)
	pm.damping_min = 1.5
	pm.damping_max = 3.5
	pm.scale_min = 0.7
	pm.scale_max = 1.4
	pm.scale_curve = curve_tex([[0.0, 0.30], [0.4, 1.0], [1.0, 1.25]])
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.color_ramp = gradient_tex([
		Color(0.55, 0.5, 0.46, 0.0), Color(0.42, 0.39, 0.36, 0.85),
		Color(0.26, 0.25, 0.24, 0.55), Color(0.2, 0.19, 0.19, 0.0)],
		[0.0, 0.12, 0.55, 1.0])
	return pm


static func debris_process() -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.3
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 60.0
	pm.initial_velocity_min = 5.0
	pm.initial_velocity_max = 14.0
	pm.gravity = Vector3(0, -22.0, 0)
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -520.0
	pm.angular_velocity_max = 520.0
	pm.color_ramp = gradient_tex([
		Color(0.34, 0.3, 0.27, 1.0), Color(0.24, 0.21, 0.19, 1.0),
		Color(0.2, 0.18, 0.16, 0.0)])
	return pm
