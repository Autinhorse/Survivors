extends RefCounted
## 种子化随机。sim 里禁止用 randf() / randi()——那是全局状态，会毁掉可复现性。
## 同一个 seed 必须跑出完全一样的一局，否则批量模拟的结论不可信。

var _r := RandomNumberGenerator.new()
var seed_value: int = 0

func _init(p_seed: int = 0) -> void:
	seed_value = p_seed
	_r.seed = p_seed

func f() -> float:
	return _r.randf()

func range_f(a: float, b: float) -> float:
	return _r.randf_range(a, b)

func range_i(a: int, b: int) -> int:
	return _r.randi_range(a, b)

func angle() -> float:
	return _r.randf_range(-PI, PI)

func pick(arr: Array):
	if arr.is_empty():
		return null
	return arr[_r.randi_range(0, arr.size() - 1)]

## 按权重取下标；weights 全 0 时退化为均匀。
func pick_weighted(weights: Array) -> int:
	var total := 0.0
	for w in weights:
		total += maxf(0.0, float(w))
	if total <= 0.0:
		return _r.randi_range(0, weights.size() - 1)
	var roll := _r.randf() * total
	for i in weights.size():
		roll -= maxf(0.0, float(weights[i]))
		if roll <= 0.0:
			return i
	return weights.size() - 1
