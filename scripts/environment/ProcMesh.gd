@tool
class_name ProcMesh
extends RefCounted
## Procedural low-poly environment meshes (rocks, trunks, canopies, bushes).
##
## Everything is flat-shaded on purpose: at the benchmark camera distance the
## silhouette and the facet break-up are what read, not smooth normals -- and
## flat shading is what gives a 130-triangle rock the look of a carved boulder
## instead of a squashed sphere.
##
## Meshes are unit-sized (roughly 1 m across, sitting on y = 0) so the scatter
## transforms can scale them directly.


## Deterministic vertex jitter: neighbours must agree or the shell tears open,
## so displacement is hashed from the grid coordinates, never drawn per-vertex.
static func _hash01(a: int, b: int, salt: int) -> float:
	var h := (a * 73856093) ^ (b * 19349663) ^ (salt * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return float(absi(h) % 100003) / 100003.0


static func _flat_surface(grid: Array, segments: int, rings: int) -> Array:
	## Emit flat-shaded triangles from a (rings+1) x segments vertex grid.
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for r in rings:
		for s in segments:
			var s2 := (s + 1) % segments
			var a: Vector3 = grid[r][s]
			var b: Vector3 = grid[r][s2]
			var c: Vector3 = grid[r + 1][s2]
			var d: Vector3 = grid[r + 1][s]
			for tri in [[a, b, c], [a, c, d]]:
				var n: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
				if n.length_squared() < 1e-12:
					continue
				n = n.normalized()      # outward, verified against the centroid
				# Godot's front face is the opposite winding to the order this
				# grid produces.  Emitted as-is, every near-side face is culled
				# and the mesh renders as a hollow shell seen from the inside.
				for v in [tri[0], tri[2], tri[1]]:
					verts.append(v)
					norms.append(n)
	return [verts, norms]


static func _build(verts: PackedVector3Array, norms: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func _blob_grid(salt: int, segments: int, rings: int, bump: float,
		squash: float, underside: float) -> Array:
	var grid := []
	for r in rings + 1:
		var row := []
		var theta := PI * float(r) / float(rings)
		var y := cos(theta)
		var ring_r := sin(theta)
		for s in segments:
			var phi := TAU * float(s) / float(segments)
			# The pole rings collapse to a single point, so every vertex there
			# must get the SAME displacement.  Otherwise the pole fan turns into
			# thin slivers whose normals point sideways, and the whole top of the
			# rock stops catching the key light.
			var ss := 0 if (r == 0 or r == rings) else s
			# Low-frequency lumps dominate; the per-vertex term is deliberately
			# small.  Strong per-vertex jitter crumples the shell into high
			# frequency facets, half of which end up facing away from the light.
			var lump := _hash01(r, ss, salt) - 0.5
			var coarse := _hash01(r / 2, ss / 3, salt + 77) - 0.5
			var k: float = 1.0 + bump * (coarse * 1.6 + lump * 0.25)
			var v := Vector3(cos(phi) * ring_r, y * squash, sin(phi) * ring_r) * 0.5 * k
			# Flatten the underside SMOOTHLY.  Clamping y to a floor collapses
			# several rings onto one plane, which produces degenerate triangles
			# (dropped) and therefore holes in the shell.
			if v.y < 0.0:
				v.y *= underside
			row.append(v)
		grid.append(row)
	return grid


static func rock(salt: int, segments := 9, rings := 6, bump := 0.20) -> ArrayMesh:
	var grid := _blob_grid(salt, segments, rings, bump, 0.85, 0.48)
	var sn := _flat_surface(grid, segments, rings)
	return _build(sn[0], sn[1])


static func bush(salt: int) -> ArrayMesh:
	## Two overlapping squashed blobs: cheaper than one dense shell and the
	## intersection gives the silhouette a natural bite.
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for i in 2:
		var grid := _blob_grid(salt + i * 31, 8, 5, 0.18, 0.62, 0.85)
		var off := Vector3(
				(_hash01(i, 3, salt) - 0.5) * 0.55, 0.0,
				(_hash01(i, 7, salt) - 0.5) * 0.55)
		var sc: float = 1.0 - 0.25 * float(i)
		for r in grid.size():
			for s in grid[r].size():
				grid[r][s] = grid[r][s] * sc + off + Vector3(0.0, 0.28 * sc, 0.0)
		var sn := _flat_surface(grid, 8, 5)
		verts.append_array(sn[0])
		norms.append_array(sn[1])
	return _build(verts, norms)


static func trunk(salt: int, height := 3.0, radius := 0.22, sides := 6) -> ArrayMesh:
	## Tapered, slightly bent trunk. The bend matters: a perfectly straight
	## cylinder is the main reason placeholder trees look like lollipops.
	var segs := 4
	var lean := Vector3(_hash01(1, 1, salt) - 0.5, 0.0, _hash01(2, 2, salt) - 0.5) * 0.5
	var grid := []
	for r in segs + 1:
		var t := float(r) / float(segs)
		var row := []
		var rad: float = radius * lerp(1.35, 0.55, t)
		var centre: Vector3 = Vector3(0.0, height * t, 0.0) + lean * t * t
		for s in sides:
			var phi := TAU * float(s) / float(sides)
			var k: float = 1.0 + 0.18 * (_hash01(r, s, salt + 5) - 0.5)
			row.append(centre + Vector3(cos(phi), 0.0, sin(phi)) * rad * k)
		grid.append(row)
	var sn := _flat_surface(grid, sides, segs)
	return _build(sn[0], sn[1])


static func canopy(salt: int, blobs := 3, radius := 1.8, base_y := 2.6) -> ArrayMesh:
	## Several overlapping faceted blobs -- a layered crown rather than a ball.
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for i in blobs:
		var grid := _blob_grid(salt + i * 53, 9, 6, 0.16, 0.80, 1.0)
		var ang := TAU * float(i) / float(blobs) + _hash01(i, 9, salt)
		var spread: float = radius * (0.30 + 0.30 * _hash01(i, 11, salt))
		var sc: float = radius * (1.15 - 0.28 * float(i)) * (0.8 + 0.4 * _hash01(i, 13, salt))
		var off := Vector3(cos(ang) * spread,
				base_y + radius * (0.25 + 0.55 * _hash01(i, 17, salt)),
				sin(ang) * spread)
		for r in grid.size():
			for s in grid[r].size():
				grid[r][s] = grid[r][s] * sc + off
		var sn := _flat_surface(grid, 9, 6)
		verts.append_array(sn[0])
		norms.append_array(sn[1])
	return _build(verts, norms)
