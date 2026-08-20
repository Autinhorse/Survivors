@tool
extends MultiMeshInstance3D
## Ground decoration: sparse plant clumps as a single MultiMesh.
##
## NOT a grass carpet.  The open field is a texture (see shaders/ground.gdshader):
## a full geometry carpet measured at 100k triangles -- a third of the whole
## scene, and a third of the 1000-enemy triangle budget from doc section 5 --
## for ground cover the reference art draws with a texture.  What stays here is
## the accent clumps the reference does model, near rocks and path edges.
##
## Ground clutter is the single biggest gap between "engine test scene" and the
## reference art, and it is also the cheapest to add: one draw call, real
## geometry (no alpha blending), and a distance fade handled in the shader.
##
## Tufts are placed with a fixed seed so the layout is reproducible between
## runs -- the doc (section 28) requires comparable screenshots.

@export var tuft_count: int = 9000
@export var rebuild: bool = false:            # editor button: flip to rebuild
	set(v):
		rebuild = false
		if v:
			_build()

@export_group("Area")
@export var area_min: Vector2 = Vector2(-36.0, -32.0)
@export var area_max: Vector2 = Vector2(32.0, 24.0)
@export var far_bank_y: float = 2.0

@export_group("Exclusions")
## Channel: x = river_x0 + river_slope * z, half width river_half.
@export var river_x0: float = 10.0
@export var river_slope: float = 0.28
@export var river_half: float = 4.4
## Village loop road, skipped between loop_band.x and loop_band.y of its radius.
@export var loop_center: Vector2 = Vector2(-7.0, -2.0)
@export var loop_radii: Vector2 = Vector2(9.3, 6.9)
@export var loop_band: Vector2 = Vector2(0.80, 1.20)
## Buildings/props/player: each Vector3 is (x, z, radius).
@export var exclusions: PackedVector3Array = PackedVector3Array()

@export_group("Tuft")
@export var blades: int = 5
@export var blade_height: float = 0.30
@export var blade_width: float = 0.07
@export var rng_seed: int = 20260820

@export_group("Patchiness")
## Ground clutter grows in clumps, not as an even carpet.  A cheap value-noise
## mask gates placement; density is the floor everywhere outside a clump.
@export var patch_scale: float = 0.085
@export var patch_threshold: float = 0.62
@export var base_density: float = 0.05

const MAX_TRIES := 6


func _ready() -> void:
	_build()


func _build() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _make_tuft_mesh()

	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var placed: Array[Transform3D] = []
	var customs: Array[Color] = []
	for _i in tuft_count:
		for _t in MAX_TRIES:
			var px := rng.randf_range(area_min.x, area_max.x)
			var pz := rng.randf_range(area_min.y, area_max.y)
			if _rejected(px, pz):
				continue
			if not _in_patch(px, pz, rng):
				continue
			var y := far_bank_y if px > river_x0 + river_slope * pz + river_half else 0.0
			var b := Basis().rotated(Vector3.UP, rng.randf_range(0.0, TAU))
			b = b.scaled(Vector3.ONE * rng.randf_range(0.8, 1.5))
			placed.append(Transform3D(b, Vector3(px, y, pz)))
			customs.append(Color(rng.randf(), rng.randf(), rng.randf(), 1.0))
			break

	mm.instance_count = placed.size()
	for i in placed.size():
		mm.set_instance_transform(i, placed[i])
		mm.set_instance_custom_data(i, customs[i])
	multimesh = mm


func _in_patch(px: float, pz: float, rng: RandomNumberGenerator) -> bool:
	var m := sin(px * patch_scale * 6.0) * cos(pz * patch_scale * 5.0) 			+ 0.6 * sin((px + pz) * patch_scale * 11.0) 			+ 0.4 * cos((px - pz * 1.7) * patch_scale * 17.0)
	m = m * 0.35 + 0.5
	if m > patch_threshold:
		return true
	return rng.randf() < base_density


func _rejected(px: float, pz: float) -> bool:
	if absf(px - (river_x0 + river_slope * pz)) < river_half:
		return true                                  # in the gorge
	var e := Vector2((px - loop_center.x) / loop_radii.x,
			(pz - loop_center.y) / loop_radii.y).length()
	if e > loop_band.x and e < loop_band.y:
		return true                                  # on the road
	for c in exclusions:
		if Vector2(px - c.x, pz - c.y).length() < c.z:
			return true
	return false


func _make_tuft_mesh() -> ArrayMesh:
	## A few tapered blades of real geometry -- deliberately not alpha cards.
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed ^ 0x5f5f

	for b in blades:
		var a: float = TAU * float(b) / float(blades) + rng.randf_range(-0.3, 0.3)
		var dir := Vector3(cos(a), 0.0, sin(a))
		var side := Vector3(-dir.z, 0.0, dir.x) * blade_width
		var lean := dir * rng.randf_range(0.10, 0.26)
		var h: float = blade_height * rng.randf_range(0.7, 1.3)

		var base := verts.size()
		verts.append(-side)
		verts.append(side)
		verts.append(lean + Vector3(0.0, h, 0.0))
		# lit as if it were part of the ground: avoids near-black blades
		for _n in 3:
			norms.append(Vector3.UP)
		idx.append(base)
		idx.append(base + 1)
		idx.append(base + 2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
