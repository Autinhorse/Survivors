extends RefCounted
## 地图状态评估（§7.6）。1 秒跑一次，产出四样东西：
##   1. 九宫格分区威胁 + 四方向威胁（§7.6.1 / §7.6.2）
##   2. 四方向的己方 DPS 与清场秒数（§7.6.3）
##   3. 高血量敌人列表（§7.6.4）—— 索敌方式 4 和大招选目标要用
##   4. 3×3 / 5×5 的敌人聚集度列表（§7.6.5）—— 索敌方式 5 要用
##
## 按文档的做法：**每次评估时以机甲当前中心为格心重新划格**，
## 机甲不在格子中心带来的偏差就落在一个格子以内，可以忽略。

const R := 14                       # 外边线：机甲半宽 1.5 + 向外 12 格，取整 14
const N := R * 2 + 1                # 29×29 的局部格盘
const BAND := 2.5                   # 中间带：装甲边线（1.5）再向外扩 1 格
const MELEE_FALLOFF := 0.1          # 每远一圈 -10%（§7.6.2）
const MELEE_MAX_RING := 10          # 10 格以外忽略

# 九宫格：0=左上 1=上 2=右上 3=左 4=中 5=右 6=左下 7=下 8=右下
var region_threat := PackedFloat32Array()
var region_hp := PackedFloat32Array()
var region_count := PackedInt32Array()

# 四方向：0=上 1=右 2=下 3=左（世界方向，不是机甲局部方向）
var dir_threat := PackedFloat32Array()
var dir_hp := PackedFloat32Array()
var dir_dps := PackedFloat32Array()
var dir_clear_sec := PackedFloat32Array()

var top_hp: Array = []              # 血量最高的敌人（降序），只留阈值以上的
var hp_threshold: float = 0.0
var cluster3: Array = []            # [{cell=Vector2i, count=int}]，降序
var cluster5: Array = []

var last_eval_time: float = -1.0
var interval: float = 1.0

const TOP_K := 16                   # 聚集度只留前 K 个，不做全量排序

var _torus = null
var _db = null
var _counts := PackedInt32Array()
var _in_range: Array = []           # 本次评估里在盘内的敌人，供第二趟复用
var _top3_cnt := PackedInt32Array()
var _top3_cell := PackedInt32Array()
var _top5_cnt := PackedInt32Array()
var _top5_cell := PackedInt32Array()
var _tophp_hp := PackedFloat32Array()   # 定长 top-K 的血量，配合 top_hp
var _sat := PackedInt32Array()      # 积分图，(N+1)×(N+1)，把 3×3/5×5 计数降到 O(1)

func setup(db, torus) -> void:
	_db = db
	_torus = torus
	_counts.resize(N * N)
	_sat.resize((N + 1) * (N + 1))
	region_threat.resize(9)
	region_hp.resize(9)
	region_count.resize(9)
	for a in [dir_threat, dir_hp, dir_dps, dir_clear_sec]:
		a.resize(4)
	_top3_cnt.resize(TOP_K)
	_top3_cell.resize(TOP_K)
	_top5_cnt.resize(TOP_K)
	_top5_cell.resize(TOP_K)
	_tophp_hp.resize(TOP_K)

func maybe_evaluate(world) -> bool:
	if last_eval_time >= 0.0 and world.time - last_eval_time < interval:
		return false
	evaluate(world)
	last_eval_time = world.time
	return true

## 只跑清零 + 主扫描，供 EvalProf 分段计时
func prof_scan(world) -> void:
	var mech = world.mech
	var origin: Vector2 = mech.pos
	var half: float = mech.half_size

	for i in N * N:
		_counts[i] = 0
	for i in 9:
		region_threat[i] = 0.0
		region_hp[i] = 0.0
		region_count[i] = 0
	_in_range.clear()
	top_hp.clear()
	top_hp.resize(TOP_K)
	for i in TOP_K:
		_tophp_hp[i] = -1.0
		top_hp[i] = null

	# 热循环里一律不调用其他函数：1000 只敌人 × 4 次跨对象调用就是 2-3 ms，
	# 而 GDScript 的调用开销远大于这里的算术。环形 delta、九宫格归属、威胁衰减
	# 全部内联在这里，改动时要同步 Torus.delta / _region_of / _threat_weight。
	var max_hp_seen := 0.0
	var tw: float = _torus.w
	var th: float = _torus.h
	var hw: float = tw * 0.5
	var hh: float = th * 0.5
	var rf := float(R)
	for e in world.enemies:
		if not e.alive:
			continue
		var dx: float = fposmod(e.pos.x - origin.x + hw, tw) - hw
		if dx > rf or dx < -rf:
			continue
		var dy: float = fposmod(e.pos.y - origin.y + hh, th) - hh
		if dy > rf or dy < -rf:
			continue
		_counts[(int(round(dy)) + R) * N + int(round(dx)) + R] += 1
		_in_range.append(e)

		var col := 1
		if dx < -BAND:
			col = 0
		elif dx > BAND:
			col = 2
		var row := 1
		if dy < -BAND:
			row = 0
		elif dy > BAND:
			row = 2
		var reg := row * 3 + col

		var dist := sqrt(dx * dx + dy * dy)
		var wgt := 0.0
		if e.attack_kind == "ranged":
			var over: float = dist - e.attack_range
			wgt = 1.0 if over <= 0.0 else maxf(0.0, 1.0 - MELEE_FALLOFF * ceil(over))
		else:
			var ring: float = ceil(maxf(0.0, dist - half))
			if ring <= float(MELEE_MAX_RING):
				wgt = maxf(0.0, 1.0 - MELEE_FALLOFF * maxf(0.0, ring - 1.0))
		region_threat[reg] += e.attack / maxf(0.01, e.attack_interval) * wgt
		region_hp[reg] += e.hp
		region_count[reg] += 1
		if e.hp > max_hp_seen:
			max_hp_seen = e.hp
		# §7.6.4 只关心"最硬的那几个"（索敌方式 4、大招选目标），
		# 全量排序 1000 个要 1ms —— 定长插入把它压到接近零。
		if e.hp > _tophp_hp[TOP_K - 1]:
			var k := TOP_K - 1
			while k > 0 and _tophp_hp[k - 1] < e.hp:
				_tophp_hp[k] = _tophp_hp[k - 1]
				top_hp[k] = top_hp[k - 1]
				k -= 1
			_tophp_hp[k] = e.hp
			top_hp[k] = e


func evaluate(world) -> void:
	var mech = world.mech
	var origin: Vector2 = mech.pos
	var half: float = mech.half_size

	for i in N * N:
		_counts[i] = 0
	for i in 9:
		region_threat[i] = 0.0
		region_hp[i] = 0.0
		region_count[i] = 0
	_in_range.clear()
	top_hp.clear()
	top_hp.resize(TOP_K)
	for i in TOP_K:
		_tophp_hp[i] = -1.0
		top_hp[i] = null

	# 热循环里一律不调用其他函数：1000 只敌人 × 4 次跨对象调用就是 2-3 ms，
	# 而 GDScript 的调用开销远大于这里的算术。环形 delta、九宫格归属、威胁衰减
	# 全部内联在这里，改动时要同步 Torus.delta / _region_of / _threat_weight。
	var max_hp_seen := 0.0
	var tw: float = _torus.w
	var th: float = _torus.h
	var hw: float = tw * 0.5
	var hh: float = th * 0.5
	var rf := float(R)
	for e in world.enemies:
		if not e.alive:
			continue
		var dx: float = fposmod(e.pos.x - origin.x + hw, tw) - hw
		if dx > rf or dx < -rf:
			continue
		var dy: float = fposmod(e.pos.y - origin.y + hh, th) - hh
		if dy > rf or dy < -rf:
			continue
		_counts[(int(round(dy)) + R) * N + int(round(dx)) + R] += 1
		_in_range.append(e)

		var col := 1
		if dx < -BAND:
			col = 0
		elif dx > BAND:
			col = 2
		var row := 1
		if dy < -BAND:
			row = 0
		elif dy > BAND:
			row = 2
		var reg := row * 3 + col

		var dist := sqrt(dx * dx + dy * dy)
		var wgt := 0.0
		if e.attack_kind == "ranged":
			var over: float = dist - e.attack_range
			wgt = 1.0 if over <= 0.0 else maxf(0.0, 1.0 - MELEE_FALLOFF * ceil(over))
		else:
			var ring: float = ceil(maxf(0.0, dist - half))
			if ring <= float(MELEE_MAX_RING):
				wgt = maxf(0.0, 1.0 - MELEE_FALLOFF * maxf(0.0, ring - 1.0))
		region_threat[reg] += e.attack / maxf(0.01, e.attack_interval) * wgt
		region_hp[reg] += e.hp
		region_count[reg] += 1
		if e.hp > max_hp_seen:
			max_hp_seen = e.hp
		# §7.6.4 只关心"最硬的那几个"（索敌方式 4、大招选目标），
		# 全量排序 1000 个要 1ms —— 定长插入把它压到接近零。
		if e.hp > _tophp_hp[TOP_K - 1]:
			var k := TOP_K - 1
			while k > 0 and _tophp_hp[k - 1] < e.hp:
				_tophp_hp[k] = _tophp_hp[k - 1]
				top_hp[k] = top_hp[k - 1]
				k -= 1
			_tophp_hp[k] = e.hp
			top_hp[k] = e

	# §7.6.4：阈值取"当前最高血量的 50%"，砍掉不够硬的（此时只剩 TOP_K 个，很便宜）
	hp_threshold = max_hp_seen * 0.5
	var keep := 0
	for i in TOP_K:
		if top_hp[i] == null or _tophp_hp[i] < hp_threshold:
			break
		keep += 1
	top_hp.resize(keep)

	# §7.6.2：斜角区域各按 50% 计入两个相邻的正方向
	dir_threat[0] = region_threat[1] + (region_threat[0] + region_threat[2]) * 0.5
	dir_threat[1] = region_threat[5] + (region_threat[2] + region_threat[8]) * 0.5
	dir_threat[2] = region_threat[7] + (region_threat[6] + region_threat[8]) * 0.5
	dir_threat[3] = region_threat[3] + (region_threat[0] + region_threat[6]) * 0.5
	dir_hp[0] = region_hp[1] + (region_hp[0] + region_hp[2]) * 0.5
	dir_hp[1] = region_hp[5] + (region_hp[2] + region_hp[8]) * 0.5
	dir_hp[2] = region_hp[7] + (region_hp[6] + region_hp[8]) * 0.5
	dir_hp[3] = region_hp[3] + (region_hp[0] + region_hp[6]) * 0.5

	_eval_own_dps(mech)
	for i in 4:
		# 文档原文是"DPS 超过这个方向敌人的血量"——量纲不对（每秒 vs 总量），
		# 这里按"清场需要几秒"来判，再和敌人到达时间比才有意义。
		dir_clear_sec[i] = dir_hp[i] / maxf(1.0, dir_dps[i])

	_eval_clusters()

## 炮塔弧覆盖某个世界方向时，它的 DPS 才算在那个方向上（§7.6.3）
func _eval_own_dps(mech) -> void:
	const DIR_ANGLE := [-PI * 0.5, 0.0, PI * 0.5, PI]      # 上 右 下 左（数学角，y 向下）
	for i in 4:
		dir_dps[i] = 0.0
	for t in mech.turrets:
		var arc_center: float = mech.slot_arc_center(t)
		var half_arc := deg_to_rad(mech.SLOT_ARC_DEG) * 0.5
		var dps: float = _db.weapon_damage(t.weapon_id, t.level) \
			/ _db.weapon_interval(t.weapon_id, t.level) \
			* float(maxi(1, _db.weapon_burst(t.weapon_id, t.level)))
		for i in 4:
			if absf(wrapf(DIR_ANGLE[i] - arc_center, -PI, PI)) <= half_arc:
				dir_dps[i] += dps

## §7.6.5：每个格子为中心的 3×3 和 5×5 内有多少敌人，各出一张降序表。
## 用积分图把每格的计数降到 O(1)，并且只留前 TOP_K 个 —— 全量排序 841 个格子
## 在 1000 敌人时要 6ms，超出 §7.6 的"1 秒一次也不能卡"预算。
func _build_sat() -> void:
	var w := N + 1
	for x in w:
		_sat[x] = 0
	for y in N:
		_sat[(y + 1) * w] = 0
		var row_sum := 0
		for x in N:
			row_sum += _counts[y * N + x]
			_sat[(y + 1) * w + x + 1] = _sat[y * w + x + 1] + row_sum

func _box_count(cx: int, cy: int, r: int) -> int:
	var w := N + 1
	var x0 := maxi(0, cx - r)
	var y0 := maxi(0, cy - r)
	var x1 := mini(N - 1, cx + r)
	var y1 := mini(N - 1, cy + r)
	return _sat[(y1 + 1) * w + x1 + 1] - _sat[y0 * w + x1 + 1] - _sat[(y1 + 1) * w + x0] + _sat[y0 * w + x0]

func _eval_clusters() -> void:
	_build_sat()
	for i in TOP_K:
		_top3_cnt[i] = 0
		_top5_cnt[i] = 0
	var w := N + 1
	for cy in N:
		var y0a := maxi(0, cy - 1) * w
		var y1a := (mini(N - 1, cy + 1) + 1) * w
		var y0b := maxi(0, cy - 2) * w
		var y1b := (mini(N - 1, cy + 2) + 1) * w
		for cx in N:
			var x0a := maxi(0, cx - 1)
			var x1a := mini(N - 1, cx + 1) + 1
			var c3: int = _sat[y1a + x1a] - _sat[y0a + x1a] - _sat[y1a + x0a] + _sat[y0a + x0a]
			if c3 > _top3_cnt[TOP_K - 1]:
				_insert_top(_top3_cnt, _top3_cell, c3, cy * N + cx)
			var x0b := maxi(0, cx - 2)
			var x1b := mini(N - 1, cx + 2) + 1
			var c5: int = _sat[y1b + x1b] - _sat[y0b + x1b] - _sat[y1b + x0b] + _sat[y0b + x0b]
			if c5 > _top5_cnt[TOP_K - 1]:
				_insert_top(_top5_cnt, _top5_cell, c5, cy * N + cx)
	cluster3 = _to_list(_top3_cnt, _top3_cell)
	cluster5 = _to_list(_top5_cnt, _top5_cell)

## 定长降序插入，避免在 841 次循环里造字典和排序
func _insert_top(cnt: PackedInt32Array, cell: PackedInt32Array, v: int, c: int) -> void:
	var i := TOP_K - 1
	while i > 0 and cnt[i - 1] < v:
		cnt[i] = cnt[i - 1]
		cell[i] = cell[i - 1]
		i -= 1
	cnt[i] = v
	cell[i] = c

func _to_list(cnt: PackedInt32Array, cell: PackedInt32Array) -> Array:
	var out: Array = []
	for i in TOP_K:
		if cnt[i] <= 1:
			break
		out.append({"cell": Vector2i(cell[i] % N - R, cell[i] / N - R), "count": cnt[i]})
	return out

func _region_of(rel: Vector2) -> int:
	var col := 1
	if rel.x < -BAND:
		col = 0
	elif rel.x > BAND:
		col = 2
	var row := 1
	if rel.y < -BAND:
		row = 0
	elif rel.y > BAND:
		row = 2
	return row * 3 + col

## 近战按"离车体边缘第几圈"衰减，远程按"超出自己射程几格"衰减（§7.6.2）
func _threat_weight(e, dist: float, half: float) -> float:
	if e.attack_kind == "ranged":
		var over: float = dist - e.attack_range
		if over <= 0.0:
			return 1.0
		return maxf(0.0, 1.0 - MELEE_FALLOFF * ceil(over))
	var ring: float = ceil(maxf(0.0, dist - half))
	if ring > float(MELEE_MAX_RING):
		return 0.0
	return maxf(0.0, 1.0 - MELEE_FALLOFF * maxf(0.0, ring - 1.0))

## 某个局部格附近有多少敌人（索敌方式 5 用）。
## 用外接方框近似圆——判断"哪一坨最密"够用，而且是 O(1)。
func count_near(rel: Vector2, radius: float) -> int:
	var cx := int(round(rel.x)) + R
	var cy := int(round(rel.y)) + R
	if cx < 0 or cy < 0 or cx >= N or cy >= N:
		return 0
	return _box_count(cx, cy, int(ceil(radius)))

# ---------------------------------------------------------------- 给索敌用

## 索敌方式 5（范围杀伤最大）和 6（对自己 DPS 最高）
func pick_for(mode: int, turret, candidates: Array, mech_pos: Vector2):
	if candidates.is_empty():
		return null
	var best = null
	var best_score := -INF
	if mode == 5:
		var radius: float = maxf(0.5, _db.weapon_aoe(turret.weapon_id, turret.level))
		for e in candidates:
			var rel: Vector2 = _torus.delta(mech_pos, e.pos)
			var score := float(count_near(rel, radius))
			if score > best_score:
				best_score = score
				best = e
	else:
		for e in candidates:
			var rel2: Vector2 = _torus.delta(mech_pos, e.pos)
			var score2: float = e.attack / maxf(0.01, e.attack_interval) \
				* _threat_weight(e, rel2.length(), 1.5)
			if score2 > best_score:
				best_score = score2
				best = e
	return best

## 调试快照
func snapshot() -> String:
	var lines: Array = []
	const RN := ["左上", "上", "右上", "左", "中", "右", "左下", "下", "右下"]
	lines.append("九宫格   威胁DPS / 敌人血量 / 数量")
	for r in 3:
		var row: Array = []
		for c in 3:
			var i := r * 3 + c
			row.append("%s %.0f/%.0f/%d" % [RN[i], region_threat[i], region_hp[i], region_count[i]])
		lines.append("  " + "   ".join(row))
	const DN := ["上", "右", "下", "左"]
	for i in 4:
		lines.append("%s：威胁 %.0f DPS   敌人血量 %.0f   己方 DPS %.0f   清场 %.1f 秒"
			% [DN[i], dir_threat[i], dir_hp[i], dir_dps[i], dir_clear_sec[i]])
	lines.append("高血量目标 %d 个（阈值 %.0f）   3×3 最密 %s   5×5 最密 %s"
		% [top_hp.size(), hp_threshold,
			str(cluster3[0]["count"]) if not cluster3.is_empty() else "-",
			str(cluster5[0]["count"]) if not cluster5.is_empty() else "-"])
	return "\n".join(lines)
