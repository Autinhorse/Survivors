@tool
extends Node3D
## 成簇散布：**平均每屏一组**，一组几件挤在一起，其余全是空地。
##
## 这个密度是**玩法定的**，不是从参考图量的 —— 参考图那种疏密对应的是
## 赛车关卡，我们要的是"一屏 1-2 组聚在一起"。见
## styles/hellrider/README.md 的「已知待办」。
##
## 簇心用**抖动网格**取：一屏一格，在格内随机偏移。纯随机撒点会又结团又留洞，
## 抖动网格保证"平均每屏一组"这件事在**每一屏上**都成立，而不只是全局平均。
##
## 生成出来的位置直接写进子节点的 ScatterField.placements 再重建 ——
## 散布逻辑在这里，MultiMesh 批处理和 blob 阴影仍归 ScatterField。

const STRIDE := 7          ## 和 ScatterField 一致：x, y, z, yaw, sx, sy, sz

@export var rebuild: bool = false:
	set(v):
		rebuild = false
		if v:
			regenerate()

@export_group("密度")
@export var screen_w: float = 65.8         ## 一屏在地面上有多宽（正交视宽）
@export var screen_d: float = 57.6         ## 一屏的可见纵深
@export var clusters_per_screen: float = 1.0
@export var margin: float = 16.0           ## 簇心离可玩区边界留多远

@export_group("一组长什么样")
@export var cluster_radius: float = 10.0   ## 一组摊开多大
@export var items_min: int = 2
@export var items_max: int = 4
## 一组里"全石头 / 全树 / 混着"的比例
@export var frac_rock: float = 0.40
@export var frac_tree: float = 0.40

@export_group("占地半径（互不穿插用）")
## **每一件都有自己的占地半径，摆之前要查重。**
## 一个石头"变体"其实是一整组石头（一大配两三小，跨 3 m 左右），
## 不查重的话组和组会叠在一起 —— 小石头就从大石头身上冒出来，
## 树也会插进石头里。
@export var r_rock: float = 3.2
@export var r_tree: float = 2.2
@export var r_bush: float = 1.1
@export var r_pebble: float = 0.9
## 允许挨多近：1.0 = 刚好不碰，小于 1 = 可以挤一点（成组才自然）
@export var pack: float = 0.85
@export var tries: int = 24                ## 每件最多试几个位置

@export_group("石头边上的灌木")
## 大石头周围放几团半埋进地面的球，当低矮灌木。
@export var bushes_per_rock_min: int = 1
@export var bushes_per_rock_max: int = 3
## 往地里埋多深（米，按缩放）。
## 灌木本体是个扁球（`bush()`：ico 半径 r，压扁到 0.72r，中心抬到 0.446r），
## 本来就有 0.27r 在地面以下。再埋 0.42 左右，最宽处刚好落在地面上，
## 读出来才是"一丛低矮的灌木"而不是"地上放了个球"。
@export var bush_sink: float = 0.42
@export var bush_scale_min: float = 1.0
@export var bush_scale_max: float = 1.6
## 贴石头贴多近：按石头**占地半径**的比例。石头的占地半径比它的可见轮廓大，
## 所以 0.6-1.0 正好落在石头脚边，而不是离着老远。
@export var bush_ring_min: float = 0.60
@export var bush_ring_max: float = 1.00

@export_group("接线")
@export var map_path: NodePath             ## HellMap，问它要可玩区范围
@export var rocks_path: NodePath
@export var trees_path: NodePath
@export var bushes_path: NodePath
@export var pebbles_path: NodePath

@export var scatter_seed: int = 20260822


func _ready() -> void:
	regenerate()


func regenerate(new_seed: int = -1) -> void:
	if new_seed >= 0:
		scatter_seed = new_seed
	var rect := Rect2(-200.0, -200.0, 400.0, 400.0)
	var map := get_node_or_null(map_path)
	if map and map.has_method("play_rect"):
		rect = map.play_rect()
	rect = rect.grow(-margin)

	var rng := RandomNumberGenerator.new()
	rng.seed = scatter_seed

	var out := {"rock": PackedFloat32Array(), "tree": PackedFloat32Array(),
			"bush": PackedFloat32Array(), "pebble": PackedFloat32Array()}

	# 抖动网格：一屏一格
	var nx := maxi(1, int(round(rect.size.x / screen_w)))
	var nz := maxi(1, int(round(rect.size.y / screen_d)))
	var gw := rect.size.x / float(nx)
	var gd := rect.size.y / float(nz)
	for gz in nz:
		for gx in nx:
			var n_here := 1
			if clusters_per_screen != 1.0:
				n_here = int(floor(clusters_per_screen))
				if rng.randf() < clusters_per_screen - floor(clusters_per_screen):
					n_here += 1
			for _c in n_here:
				# 格内偏移收一点（0.15..0.85），簇心才不会紧贴格边成行
				var cx: float = rect.position.x + (gx + rng.randf_range(0.15, 0.85)) * gw
				var cz: float = rect.position.y + (gz + rng.randf_range(0.15, 0.85)) * gd
				_one_cluster(rng, cx, cz, out)

	_push(rocks_path, out["rock"])
	_push(trees_path, out["tree"])
	_push(bushes_path, out["bush"])
	_push(pebbles_path, out["pebble"])


func _radius_of(kind: String) -> float:
	match kind:
		"rock":
			return r_rock
		"tree":
			return r_tree
		"bush":
			return r_bush
	return r_pebble


func _one_cluster(rng: RandomNumberGenerator, cx: float, cz: float,
		out: Dictionary) -> void:
	# 这一组已经占掉的位置：(x, z, 半径)
	var taken: Array = []

	var roll := rng.randf()
	var main := "rock"
	if roll >= frac_rock and roll < frac_rock + frac_tree:
		main = "tree"
	elif roll >= frac_rock + frac_tree:
		main = "mix"

	var n: int = rng.randi_range(items_min, items_max)
	var rocks: Array = []
	for _i in n:
		var k := main
		if main == "mix":
			k = "rock" if rng.randf() < 0.5 else "tree"
		var s: float = rng.randf_range(0.85, 1.35)
		var spot: Array = _find(rng, cx, cz, cluster_radius,
				_radius_of(k) * s, taken, k)
		if spot.is_empty():
			continue
		_emit(out, k, spot[0], 0.0, spot[1], rng.randf() * 360.0, s)
		if k == "rock":
			rocks.append([spot[0], spot[1], _radius_of(k) * s])

	# 大石头周围的灌木：贴着石头的外沿摆，半埋进地面
	for r in rocks:
		for _b in rng.randi_range(bushes_per_rock_min, bushes_per_rock_max):
			var s: float = rng.randf_range(bush_scale_min, bush_scale_max)
			var a: float = rng.randf() * TAU
			var d: float = r[2] * rng.randf_range(bush_ring_min, bush_ring_max)
			var x: float = r[0] + cos(a) * d
			var z: float = r[1] + sin(a) * d
			# 只避开别的灌木和树，石头是**故意**贴着的
			if not _free(x, z, r_bush * s, taken, "rock"):
				continue
			taken.append([x, z, r_bush * s, "bush"])
			_emit(out, "bush", x, -bush_sink * s, z, rng.randf() * 360.0, s)

	# 撒几粒卵石
	for _p in rng.randi_range(1, 3):
		var s: float = rng.randf_range(0.7, 1.1)
		var spot: Array = _find(rng, cx, cz, cluster_radius * 1.15,
				r_pebble * s, taken, "pebble")
		if spot.is_empty():
			continue
		_emit(out, "pebble", spot[0], 0.0, spot[1], rng.randf() * 360.0, s)


func _find(rng: RandomNumberGenerator, cx: float, cz: float, spread: float,
		r: float, taken: Array, kind: String) -> Array:
	## 在簇心附近找一个不和别人穿插的位置，找不到就返回空数组。
	## 半径取 sqrt(random)：均匀取 r 会把点全推到外圈，中心反而空。
	for _t in tries:
		var a: float = rng.randf() * TAU
		var d: float = spread * sqrt(rng.randf())
		var x: float = cx + cos(a) * d
		var z: float = cz + sin(a) * d
		if _free(x, z, r, taken, ""):
			taken.append([x, z, r, kind])
			return [x, z]
	return []


func _free(x: float, z: float, r: float, taken: Array, skip: String) -> bool:
	for t in taken:
		if skip != "" and t.size() > 3 and t[3] == skip:
			continue
		var dx: float = x - t[0]
		var dz: float = z - t[1]
		if dx * dx + dz * dz < pow((r + t[2]) * pack, 2.0):
			return false
	return true


func _emit(out: Dictionary, kind: String, x: float, y: float, z: float,
		yaw: float, s: float) -> void:
	var arr: PackedFloat32Array = out[kind]
	arr.append(x); arr.append(y); arr.append(z)
	arr.append(yaw)
	arr.append(s); arr.append(s); arr.append(s)
	out[kind] = arr


func _push(p: NodePath, arr: PackedFloat32Array) -> void:
	var n := get_node_or_null(p)
	if n == null:
		return
	n.placements = arr
	if n.has_method("_build"):
		n.call("_build")
