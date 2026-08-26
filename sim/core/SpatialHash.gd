extends RefCounted
## 每 tick 重建的均匀网格，按环形地图取模分桶。
## 敌人上千个时，弹丸/接触/索敌查询从 O(n·m) 降到邻域扫描 ——
## 批量模拟要跑上千局，这一层直接决定能不能在可接受时间内跑完。

var _cells: Dictionary = {}
var cell_size: float = 2.0
var _nx: int = 100
var _ny: int = 50
var _torus = null

func setup(torus, p_cell_size: float = 2.0) -> void:
	_torus = torus
	cell_size = p_cell_size
	_nx = maxi(1, int(ceil(torus.w / cell_size)))
	_ny = maxi(1, int(ceil(torus.h / cell_size)))

func rebuild(items: Array) -> void:
	_cells.clear()
	for it in items:
		if not it.alive:
			continue
		var k := _key(int(floor(it.pos.x / cell_size)), int(floor(it.pos.y / cell_size)))
		if _cells.has(k):
			_cells[k].append(it)
		else:
			_cells[k] = [it]

func _key(cx: int, cy: int) -> int:
	return posmod(cx, _nx) * _ny + posmod(cy, _ny)

## 半径 r 内的候选（未做精确距离过滤，调用方自己判）
func query(p: Vector2, r: float) -> Array:
	var out: Array = []
	var span := int(ceil(r / cell_size))
	# 半径大到绕地图一圈时，分桶已经没有意义，直接全取避免重复
	if span * 2 + 1 >= _nx or span * 2 + 1 >= _ny:
		for bucket in _cells.values():
			out.append_array(bucket)
		return out
	var cx := int(floor(p.x / cell_size))
	var cy := int(floor(p.y / cell_size))
	for dx in range(-span, span + 1):
		for dy in range(-span, span + 1):
			var k := _key(cx + dx, cy + dy)
			if _cells.has(k):
				out.append_array(_cells[k])
	return out
