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
##   亮边     沿阶梯边界的两条纯色带（外橙在下、内黄在上）+ 凸角补丁
##
## 三件事都跟着同一条边界走，所以不会出现缝。这一点比看上去重要 ——
## 上一个风格里"判据坐标和实际可见边界对不上"这个坑踩了三次。
##
## **熔岩方块是轴向的正方形，不是 45° 菱形。** 参考图的菱形是等距投影的
## 产物；见 styles/hellrider/README.md「四条不能破的规则」第 4 条。

## 三层各抬高一点点。**顺序是有意的**：黄边必须压在橙边上面，
## 否则在转角重叠处会看到红压黄。
const RIM_OUT_Y := 0.020       ## 外面那道橙
const RIM_IN_Y := 0.035        ## 里面那道亮黄
const EMBER_Y := 0.050         ## 余烬压在最上面

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
@export var rim_inner_w: float = 0.55       ## 亮黄那道有多宽（米）
@export var rim_outer_w: float = 1.30       ## 外面那道橙有多宽（米）

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


func _vert_dist(vi: int, vj: int) -> float:
	## 一个**格顶点**到可玩区的距离（米）。
	## 四周任何一格是可玩格，这个顶点就在边界上，距离 0；
	## 否则取四周格子里最小的格距乘格边长。
	if (_inside(vi - 1, vj - 1) or _inside(vi, vj - 1)
			or _inside(vi - 1, vj) or _inside(vi, vj)):
		return 0.0
	var d := mini(mini(_dist_cells(vi - 1, vj - 1), _dist_cells(vi, vj - 1)),
			mini(_dist_cells(vi - 1, vj), _dist_cells(vi, vj)))
	return float(d) * cell


func _lava() -> void:
	## 熔岩：可玩区之外、离可玩区 lava_out 格以内的每一个格子各一个方块。
	##
	## UV.x 携带到可玩区的距离（米），着色器靠它把颜色往外压暗。
	## 距离逐顶点算，所以渐变是连续的，不会一格一个色阶。
	##
	## **但距离在这里要夹到亮边宽度之外**：亮边由 `_rim()` 单独画。
	## 试过让亮边直接从熔岩格身上长出来（靠同一条 UV），不行 ——
	## 地面凹进去一格时，那个熔岩格有三个顶点距离都是 0，线性插值把大半个
	## 格子算成"离边界很近"，黄色摊成一个大三角，转角被斜切掉。
	## 4 m 的格子撑不住 0.55 m 的细带。
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in range(-lava_out, _rows + lava_out):
		for i in range(-lava_out, _cols + lava_out):
			if _inside(i, j):
				continue
			if _dist_cells(i, j) > lava_out:
				continue
			var a := verts.size()
			var x0 := _cx(i)
			var x1 := _cx(i + 1)
			var z0 := _cz(j)
			var z1 := _cz(j + 1)
			var lo := rim_outer_w + 0.01
			var da: float = maxf(_vert_dist(i, j), lo)
			var db: float = maxf(_vert_dist(i + 1, j), lo)
			var dc: float = maxf(_vert_dist(i, j + 1), lo)
			var dd: float = maxf(_vert_dist(i + 1, j + 1), lo)
			verts.append(Vector3(x0, 0.0, z0))
			verts.append(Vector3(x1, 0.0, z0))
			verts.append(Vector3(x0, 0.0, z1))
			verts.append(Vector3(x1, 0.0, z1))
			uvs.append(Vector2(da, z0))
			uvs.append(Vector2(db, z0))
			uvs.append(Vector2(dc, z1))
			uvs.append(Vector2(dd, z1))
			# **对角线要挑**：距离在三角形内是线性插值的，所以对角线切在哪
			# 决定了亮边在转角上是什么形状。固定切法会把"距离 0 的那个角"
			# 单独切成一个三角形，等值线就成了一条 45° 斜线 —— 转角被斜切掉。
			# 让对角线**穿过**距离最小的那个角，转角就变成两段折线，接近圆角。
			if da + dd <= db + dc:
				idx.append(a); idx.append(a + 1); idx.append(a + 3)
				idx.append(a); idx.append(a + 3); idx.append(a + 2)
			else:
				idx.append(a); idx.append(a + 1); idx.append(a + 2)
				idx.append(a + 1); idx.append(a + 3); idx.append(a + 2)
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
	## 两道亮边，各自一层**纯色**：外橙在下，内黄在上。
	##
	## 纯色是关键。上一版这两道是靠一条 UV 渐变画出来的，转角处两条带
	## 互相重叠又共面，z-fighting 让同一块像素一会儿黄一会儿橙 ——
	## 拖动画面就闪。纯色的话重叠也看不出来，因为重叠的两片长得一样。
	##
	## 缺口靠**凸角补丁**补：一条边一条带的话，地面向外凸的角上会缺一个
	## w x w 的方块，黄线就在转角断开。
	_rim_band(rim_outer_w, RIM_OUT_Y, rim_outer_w - 0.01, "RimOuter")
	_rim_band(rim_inner_w, RIM_IN_Y, 0.0, "RimInner")


func _rim_band(w: float, y: float, u: float, nm: String) -> void:
	## u 是写进 UV.x 的常数距离，着色器按它选颜色：
	## < rim_inner_w -> 亮黄，< rim_outer_w -> 橙。
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in range(-1, _rows + 1):
		for i in range(-1, _cols + 1):
			if not _inside(i, j):
				continue
			var x0 := _cx(i)
			var x1 := _cx(i + 1)
			var z0 := _cz(j)
			var z1 := _cz(j + 1)
			var n := not _inside(i, j - 1)
			var so := not _inside(i, j + 1)
			var we := not _inside(i - 1, j)
			var ea := not _inside(i + 1, j)
			if n:
				_flat(verts, uvs, idx, x0, z0 - w, x1, z0, y, u)
			if so:
				_flat(verts, uvs, idx, x0, z1, x1, z1 + w, y, u)
			if we:
				_flat(verts, uvs, idx, x0 - w, z0, x0, z1, y, u)
			if ea:
				_flat(verts, uvs, idx, x1, z0, x1 + w, z1, y, u)
			# 凸角补丁
			if n and we:
				_flat(verts, uvs, idx, x0 - w, z0 - w, x0, z0, y, u)
			if n and ea:
				_flat(verts, uvs, idx, x1, z0 - w, x1 + w, z0, y, u)
			if so and we:
				_flat(verts, uvs, idx, x0 - w, z1, x0, z1 + w, y, u)
			if so and ea:
				_flat(verts, uvs, idx, x1, z1, x1 + w, z1 + w, y, u)
	_make(nm, verts, uvs, idx, lava_material)


func _flat(verts: PackedVector3Array, uvs: PackedVector2Array,
		idx: PackedInt32Array, x0: float, z0: float, x1: float, z1: float,
		y: float, u: float) -> void:
	var a := verts.size()
	verts.append(Vector3(x0, y, z0))
	verts.append(Vector3(x1, y, z0))
	verts.append(Vector3(x0, y, z1))
	verts.append(Vector3(x1, y, z1))
	for _k in 4:
		uvs.append(Vector2(u, 0.0))
	idx.append(a); idx.append(a + 1); idx.append(a + 2)
	idx.append(a + 1); idx.append(a + 3); idx.append(a + 2)


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
					Vector3(x, EMBER_Y, z)))
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
