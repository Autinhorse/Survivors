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
@export var cluster_radius: float = 7.0    ## 一组摊开多大
@export var items_min: int = 2
@export var items_max: int = 5
## 一组里"全石头 / 全树 / 混着"的比例
@export var frac_rock: float = 0.40
@export var frac_tree: float = 0.40

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


func _one_cluster(rng: RandomNumberGenerator, cx: float, cz: float,
		out: Dictionary) -> void:
	var roll := rng.randf()
	var kinds: Array[String] = []
	var n: int = rng.randi_range(items_min, items_max)
	if roll < frac_rock:
		for _i in n:
			kinds.append("rock")
	elif roll < frac_rock + frac_tree:
		for _i in n:
			kinds.append("tree")
	else:
		for _i in n:
			kinds.append("rock" if rng.randf() < 0.5 else "tree")
	# 每组带一两件小装饰
	for _i in rng.randi_range(0, 2):
		kinds.append("bush" if rng.randf() < 0.6 else "pebble")

	for k in kinds:
		# 半径开方分布：均匀取 r 会把点全推到外圈，中心反而空
		var a: float = rng.randf() * TAU
		var r: float = cluster_radius * sqrt(rng.randf())
		var x: float = cx + cos(a) * r
		var z: float = cz + sin(a) * r
		var s: float = rng.randf_range(0.85, 1.35)
		if k == "bush" or k == "pebble":
			s = rng.randf_range(0.7, 1.1)
		var arr: PackedFloat32Array = out[k]
		arr.append(x); arr.append(0.0); arr.append(z)
		arr.append(rng.randf() * 360.0)
		arr.append(s); arr.append(s); arr.append(s)
		out[k] = arr


func _push(p: NodePath, arr: PackedFloat32Array) -> void:
	var n := get_node_or_null(p)
	if n == null:
		return
	n.placements = arr
	if n.has_method("_build"):
		n.call("_build")
