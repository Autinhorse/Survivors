@tool
extends Node3D
## 风格 "hellrider" 的大地图：**一整块可玩区 + 四面包一圈熔岩**。
##
## 取代了原来的 HellField（那是一条南北向的走廊，只有左右两侧有熔岩）。
## 走廊的形状来自参考图，但参考图是 45° 等距投影的赛道；我们是正面 90°、
## 四向自由移动，所以是一块四面封边的方形地图。
##
## 全部建在**格子**上，格边长 `cell`：
##
##   可玩区   名义矩形 play_w x play_d，四条边各自沿格随机进出 0..edge_jitter 格
##   熔岩     可玩区之外、向外 lava_out 格以内的所有格子，一格一个方块
##   黄边     沿"可玩区/熔岩"那条阶梯边界铺一条窄带
##
## 三件事都跟着同一条边界走，所以不会出现缝。这一点比看上去重要 ——
## 上一个风格里"判据坐标和实际可见边界对不上"这个坑踩了三次。
##
## **熔岩方块是轴向的正方形，不是 45° 菱形。** 参考图的菱形是等距投影的
## 产物；见 styles/hellrider/README.md「四条不能破的规则」第 4 条。

const RIM_Y := 0.03            ## 黄边抬高一点，避免和熔岩方块 z-fighting

@export var rebuild: bool = false:
	set(v):
		rebuild = false
		if v:
			_build()

@export_group("地图")
@export var cell: float = 4.0               ## 格边长（也是熔岩方块的边长）
@export var play_w: float = 526.0           ## 可玩区名义宽（X）
@export var play_d: float = 461.0           ## 可玩区名义深（Z）
## 边界沿格随机进出几格。**这就是"随机凸凹"**：熔岩带的宽度因此在
## lava_out .. lava_out + edge_jitter 格之间变化。
@export var edge_jitter: int = 3
## 凸凹的**段长**（几格换一次深度）。逐格独立随机会碎成锯齿噪声 ——
## 石头顶环的抖动上踩过同一个坑，那里的解法是沿环平滑，这里是走"段"。
@export var edge_run_min: int = 2
@export var edge_run_max: int = 5

@export_group("熔岩")
@export var lava_out: int = 10              ## 从名义边界再向外几格
@export var rim_inner_w: float = 0.55       ## 亮黄那道（米）
@export var rim_outer_w: float = 1.30       ## 外面那道橙（米）

@export_group("余烬")
## 熔岩里飘的小方块，参考图里数量不少，是这个风格的签名之一。
## 由这里生成而不是 layout 摆死：边界是随机的，只有这里知道熔岩落在哪些格。
@export var ember_per_cell: float = 0.06
@export var ember_size_min: float = 0.35
@export var ember_size_max: float = 1.05

@export_group("材质")
@export var ground_material: Material
@export var lava_material: Material

@export var map_seed: int = 20260822

var _cols: int = 0
var _rows: int = 0
var _lo: PackedInt32Array            ## 每列的上边界（格）
var _hi: PackedInt32Array            ## 每列的下边界（格，不含）
var _le: PackedInt32Array            ## 每行的左边界（格）
var _re: PackedInt32Array            ## 每行的右边界（格，不含）
var _dist: PackedInt32Array          ## 到最近可玩格的格距（含 lava_out 边距）
var _dw: int = 0
var _dh: int = 0


func _ready() -> void:
	_build()


func reroll(new_seed: int = -1) -> void:
	map_seed = new_seed if new_seed >= 0 else randi()
	_build()


## 可玩区的世界范围，给相机夹取和散布用
func play_rect() -> Rect2:
	return Rect2(-play_w * 0.5, -play_d * 0.5, play_w, play_d)


func _cx(i: int) -> float:
	return -play_w * 0.5 + i * cell


func _cz(j: int) -> float:
	return -play_d * 0.5 + j * cell


func _runs(rng: RandomNumberGenerator, n: int) -> PackedInt32Array:
	## 一条边的逐格深度：按"段"走，一段 edge_run_min..max 格用同一个深度。
	var out := PackedInt32Array()
	out.resize(n)
	var i := 0
	while i < n:
		var run: int = rng.randi_range(edge_run_min, edge_run_max)
		var d: int = rng.randi_range(0, edge_jitter)
		for k in range(i, mini(i + run, n)):
			out[k] = d
		i += run
	return out


func _inside(i: int, j: int) -> bool:
	if i < 0 or j < 0 or i >= _cols or j >= _rows:
		return false
	return j >= _lo[i] and j < _hi[i] and i >= _le[j] and i < _re[j]


func _build() -> void:
	for c in get_children():
		c.queue_free()
	if cell <= 0.0:
		return
	_cols = maxi(4, int(round(play_w / cell)))
	_rows = maxi(4, int(round(play_d / cell)))

	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed
	var top := _runs(rng, _cols)
	var bot := _runs(rng, _cols)
	var lef := _runs(rng, _rows)
	var rig := _runs(rng, _rows)
	_lo = PackedInt32Array(); _lo.resize(_cols)
	_hi = PackedInt32Array(); _hi.resize(_cols)
	_le = PackedInt32Array(); _le.resize(_rows)
	_re = PackedInt32Array(); _re.resize(_rows)
	for i in _cols:
		_lo[i] = top[i]
		_hi[i] = _rows - bot[i]
	for j in _rows:
		_le[j] = lef[j]
		_re[j] = _cols - rig[j]

	_build_dist()
	_ground()
	_lava()
	_rim()
	_embers(rng)


func _make(nm: String, verts: PackedVector3Array, uvs: PackedVector2Array,
		idx: PackedInt32Array, m: Material) -> void:
	if idx.is_empty():
		return
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
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# 不设 owner：运行时生成的，写进 .tscn 会和重建冲突


func _quad(verts: PackedVector3Array, uvs: PackedVector2Array,
		idx: PackedInt32Array, x0: float, z0: float, x1: float, z1: float,
		y: float, u0: float, u1: float) -> void:
	## 缠绕方向：Godot 的正面和"按右手定则法线朝上"是**反的**。
	## 这个坑在 RiverSurface / ProcMesh / HellField 里各踩过一次。
	var a := verts.size()
	verts.append(Vector3(x0, y, z0))
	verts.append(Vector3(x1, y, z0))
	verts.append(Vector3(x0, y, z1))
	verts.append(Vector3(x1, y, z1))
	uvs.append(Vector2(u0, z0)); uvs.append(Vector2(u1, z0))
	uvs.append(Vector2(u0, z1)); uvs.append(Vector2(u1, z1))
	idx.append(a); idx.append(a + 1); idx.append(a + 2)
	idx.append(a + 1); idx.append(a + 3); idx.append(a + 2)


func _ground() -> void:
	## 逐行把连续的格并成一条长条 —— 132x116 个格子逐个建面是 30k 三角形，
	## 而地面是平的，一行一条就够。
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in _rows:
		var i := 0
		while i < _cols:
			if not _inside(i, j):
				i += 1
				continue
			var s := i
			while i < _cols and _inside(i, j):
				i += 1
			_quad(verts, uvs, idx, _cx(s), _cz(j), _cx(i), _cz(j + 1),
					0.0, 0.0, 1.0)
	_make("Ground", verts, uvs, idx, ground_material)


func _lava() -> void:
	## 熔岩：可玩区之外、离可玩区 lava_out 格以内的每一个格子各一个方块。
	## UV.x 携带**到可玩区的距离（米）**，着色器靠它把颜色往外压暗。
	## 逐格用切比雪夫距离（格数），够用而且不用做 BFS。
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in range(-lava_out, _rows + lava_out):
		for i in range(-lava_out, _cols + lava_out):
			if _inside(i, j):
				continue
			var d := _dist_cells(i, j)
			if d > lava_out:
				continue
			var u := (float(d) - 0.5) * cell
			_quad(verts, uvs, idx, _cx(i), _cz(j), _cx(i + 1), _cz(j + 1),
					0.0, u, u)
	_make("Lava", verts, uvs, idx, lava_material)


func _build_dist() -> void:
	## 到最近"可玩格"的格距，**一次 BFS 铺满**，存成一张表。
	##
	## 第一版是逐格向外搜一圈一圈找（O(r²) 每格）：2.4M 次 _inside 调用，
	## 而且 _lava 和 _embers 各要一遍 —— 实测把整场景的生成拖到分钟级，
	## 而 R 重掷是**运行时**的，这个代价不能有。BFS 是 O(格数)。
	_dw = _cols + 2 * lava_out + 2
	_dh = _rows + 2 * lava_out + 2
	_dist = PackedInt32Array()
	_dist.resize(_dw * _dh)
	for k in _dist.size():
		_dist[k] = 0x7fffffff
	var q := PackedInt32Array()
	for j in range(-lava_out - 1, _rows + lava_out + 1):
		for i in range(-lava_out - 1, _cols + lava_out + 1):
			if _inside(i, j):
				var k := _di(i, j)
				_dist[k] = 0
				q.append(k)
	var head := 0
	while head < q.size():
		var k: int = q[head]
		head += 1
		var d: int = _dist[k] + 1
		if d > lava_out + 1:
			continue
		var x := k % _dw
		var y := k / _dw
		for o in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
			var nx: int = x + o[0]
			var ny: int = y + o[1]
			if nx < 0 or ny < 0 or nx >= _dw or ny >= _dh:
				continue
			var nk := ny * _dw + nx
			if _dist[nk] > d:
				_dist[nk] = d
				q.append(nk)


func _di(i: int, j: int) -> int:
	return (j + lava_out + 1) * _dw + (i + lava_out + 1)


func _dist_cells(i: int, j: int) -> int:
	var x := i + lava_out + 1
	var y := j + lava_out + 1
	if x < 0 or y < 0 or x >= _dw or y >= _dh:
		return lava_out + 1
	return mini(_dist[y * _dw + x], lava_out + 1)


func _rim() -> void:
	## 黄边：沿"可玩格 / 非可玩格"之间的每一条格边铺一条窄带，往熔岩那侧长。
	## 用和熔岩同一个材质 —— 着色器按 UV.x（到边界的距离）画亮边，
	## 所以这里只要把距离写对，两道边（内亮黄、外橙）就自动出来。
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var w := rim_outer_w
	for j in range(-1, _rows + 1):
		for i in range(-1, _cols + 1):
			if not _inside(i, j):
				continue
			var x0 := _cx(i)
			var x1 := _cx(i + 1)
			var z0 := _cz(j)
			var z1 := _cz(j + 1)
			if not _inside(i, j - 1):
				_strip(verts, uvs, idx, x0, z0 - w, x1, z0, true)
			if not _inside(i, j + 1):
				_strip(verts, uvs, idx, x0, z1, x1, z1 + w, false)
			if not _inside(i - 1, j):
				_strip(verts, uvs, idx, x0 - w, z0, x0, z1, true, true)
			if not _inside(i + 1, j):
				_strip(verts, uvs, idx, x1, z0, x1 + w, z1, false, true)
	_make("Rim", verts, uvs, idx, lava_material)


func _embers(rng: RandomNumberGenerator) -> void:
	var xf: Array[Transform3D] = []
	for j in range(-lava_out, _rows + lava_out):
		for i in range(-lava_out, _cols + lava_out):
			if _inside(i, j) or rng.randf() > ember_per_cell:
				continue
			var d := _dist_cells(i, j)
			# 贴着边界那一格不放：会和黄边打架
			if d < 2 or d > lava_out:
				continue
			var sz: float = rng.randf_range(ember_size_min, ember_size_max)
			var x: float = _cx(i) + rng.randf() * cell
			var z: float = _cz(j) + rng.randf() * cell
			xf.append(Transform3D(
					Basis(Vector3.UP, rng.randf() * TAU).scaled(
							Vector3(sz, 1.0, sz)),
					Vector3(x, RIM_Y, z)))
	if xf.is_empty():
		return
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.orientation = PlaneMesh.FACE_Y
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = xf.size()
	for k in xf.size():
		mm.set_instance_transform(k, xf[k])
	var mi := MultiMeshInstance3D.new()
	mi.name = "Embers"
	mi.multimesh = mm
	mi.material_override = lava_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _strip(verts: PackedVector3Array, uvs: PackedVector2Array,
		idx: PackedInt32Array, x0: float, z0: float, x1: float, z1: float,
		flip: bool, vertical: bool = false) -> void:
	## 一条窄带，UV.x 从 0（贴着可玩区）线性到 rim_outer_w（外侧）。
	var a := verts.size()
	var u0 := 0.0
	var u1 := rim_outer_w
	if flip:
		u0 = rim_outer_w
		u1 = 0.0
	verts.append(Vector3(x0, RIM_Y, z0))
	verts.append(Vector3(x1, RIM_Y, z0))
	verts.append(Vector3(x0, RIM_Y, z1))
	verts.append(Vector3(x1, RIM_Y, z1))
	if vertical:
		uvs.append(Vector2(u0, z0)); uvs.append(Vector2(u1, z0))
		uvs.append(Vector2(u0, z1)); uvs.append(Vector2(u1, z1))
	else:
		uvs.append(Vector2(u0, z0)); uvs.append(Vector2(u0, z0))
		uvs.append(Vector2(u1, z1)); uvs.append(Vector2(u1, z1))
	idx.append(a); idx.append(a + 1); idx.append(a + 2)
	idx.append(a + 1); idx.append(a + 3); idx.append(a + 2)
