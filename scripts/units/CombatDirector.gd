extends Node3D
## Drives the three representative weapons from doc section 22 / Milestone 3.
##
## This is presentation only.  There is no targeting AI, no pathfinding, no
## damage model beyond a hit counter -- Rule 3 and Rule 5 keep those out until
## the milestone that actually needs them.  The job here is to put the machine
## gun, the rocket and the tesla on screen at their specified rates so the
## combat can be judged: busy enough, readable, weapons distinguishable.
##
## Rates (section 22):
##   machine gun ~10 rounds/sec, rocket ~2/sec, tesla ~1 activation/sec

@export var vfx_path: NodePath
@export var player_path: NodePath
@export var enemies_path: NodePath

@export_group("Fire rates (rounds per second)")
@export var mg_rate: float = 10.0
@export var rocket_rate: float = 2.0
@export var tesla_rate: float = 1.0

@export_group("Placeholder combat")
@export var mg_damage: int = 1
@export var rocket_damage: int = 6
@export var tesla_damage: int = 3
@export var enemy_hp: int = 8
@export var respawn_delay: float = 3.5
## Presentation-only drift so the battlefield is not a static diorama; real
## movement/AI belongs to Milestone 4.
@export var enemy_drift: float = 1.1
@export var enemy_stop_radius: float = 7.0
@export var tesla_chain: int = 2
@export var tesla_chain_radius: float = 9.0
## Enemies shoot back.  One-way fire makes the "is the fight busy and readable"
## question of section 22 impossible to judge -- crossfire is what the reference
## screenshots actually show.  Still presentation only: nothing damages the player.
@export var enemy_fire: bool = true
@export var enemy_fire_period: float = 1.7
@export var enemy_fire_jitter: float = 1.1

var _vfx: Node3D
var _player: Node3D
var _enemies: Array = []          # [{node, home, hp, respawn}]
var _pending: Array = []          # [{pos, t, dmg, idx, kind}]
var _mg_t := 0.0
var _rocket_t := 0.0
var _tesla_t := 0.0
var _target_i := 0
var _rng := RandomNumberGenerator.new()

const MUZZLE_MG := Vector3(0.45, 2.3, -3.0)
const MUZZLE_ROCKET := Vector3(-0.45, 2.3, -2.6)
const MUZZLE_TESLA := Vector3(0.0, 2.75, -0.6)


func _ready() -> void:
	_rng.seed = 7788
	_vfx = get_node_or_null(vfx_path)
	_player = get_node_or_null(player_path)
	var holder := get_node_or_null(enemies_path)
	if _vfx == null or _player == null or holder == null:
		push_warning("CombatDirector: missing vfx/player/enemies path")
		set_process(false)
		return
	for c in holder.get_children():
		if c is Node3D:
			_enemies.append({
				"node": c, "home": (c as Node3D).global_position,
				"hp": enemy_hp, "respawn": 0.0,
				"fire_t": _rng.randf() * enemy_fire_period,
			})


func _process(delta: float) -> void:
	_update_enemies(delta)
	_update_pending(delta)

	if _alive_count() == 0:
		return

	_mg_t -= delta
	if _mg_t <= 0.0:
		_mg_t += 1.0 / maxf(mg_rate, 0.01)
		_fire_mg()

	_rocket_t -= delta
	if _rocket_t <= 0.0:
		_rocket_t += 1.0 / maxf(rocket_rate, 0.01)
		_fire_rocket()

	_tesla_t -= delta
	if _tesla_t <= 0.0:
		_tesla_t += 1.0 / maxf(tesla_rate, 0.01)
		_fire_tesla()


# ------------------------------------------------------------------- weapons
func _fire_mg() -> void:
	var i := _next_target()
	if i < 0:
		return
	var tgt: Vector3 = _aim_point(i)
	_face(tgt)
	var from: Vector3 = _muzzle(MUZZLE_MG)
	var speed := 130.0
	_vfx.fire_tracer(from, tgt, speed)
	_pending.append({
		"pos": tgt, "t": from.distance_to(tgt) / speed,
		"dmg": mg_damage, "idx": i, "kind": "mg",
	})


func _fire_rocket() -> void:
	var i := _next_target()
	if i < 0:
		return
	var tgt: Vector3 = _aim_point(i)
	var from: Vector3 = _muzzle(MUZZLE_ROCKET)
	var speed := 26.0
	_vfx.launch_rocket(from, tgt, speed)
	_pending.append({
		"pos": tgt, "t": from.distance_to(tgt) / speed,
		"dmg": rocket_damage, "idx": i, "kind": "rocket",
	})


func _fire_tesla() -> void:
	var i := _next_target()
	if i < 0:
		return
	var from: Vector3 = _muzzle(MUZZLE_TESLA)
	var hit: Vector3 = _aim_point(i)
	var pts := PackedVector3Array([from, hit])
	_vfx.add_arc(pts, 0.20, 0.18)
	_vfx.hit_flash(hit, 1.3, false)
	_damage(i, tesla_damage)

	# chain to the nearest few others -- section 22 lists this as optional
	var last := hit
	var used := {i: true}
	for _c in tesla_chain:
		var j := _nearest_alive(last, tesla_chain_radius, used)
		if j < 0:
			break
		var p: Vector3 = _aim_point(j)
		_vfx.add_arc(PackedVector3Array([last, p]), 0.16, 0.13)
		_vfx.hit_flash(p, 1.0, false)
		_damage(j, tesla_damage)
		used[j] = true
		last = p


# -------------------------------------------------------------------- helpers
func _muzzle(local: Vector3) -> Vector3:
	return _player.global_transform * local


func _face(target: Vector3) -> void:
	var d := target - _player.global_position
	d.y = 0.0
	if d.length_squared() < 0.01:
		return
	_player.rotation.y = atan2(-d.x, -d.z)


func _aim_point(i: int) -> Vector3:
	var n: Node3D = _enemies[i]["node"]
	return n.global_position + Vector3(0.0, 0.9, 0.0)


func _next_target() -> int:
	for _k in _enemies.size():
		_target_i = (_target_i + 1) % _enemies.size()
		if _enemies[_target_i]["hp"] > 0:
			return _target_i
	return -1


func _nearest_alive(from: Vector3, radius: float, skip: Dictionary) -> int:
	var best := -1
	var best_d := radius
	for i in _enemies.size():
		if _enemies[i]["hp"] <= 0 or skip.has(i):
			continue
		var d: float = from.distance_to(_aim_point(i))
		if d < best_d:
			best_d = d
			best = i
	return best


func _alive_count() -> int:
	var n := 0
	for e in _enemies:
		if e["hp"] > 0:
			n += 1
	return n


func _enemy_shoot(n: Node3D) -> void:
	## Return fire aimed at the mech but deliberately scattered: perfectly
	## converging tracers read as a laser show, not as a firefight.
	var from: Vector3 = n.global_transform * Vector3(0.3, 1.0, -0.9)
	var to: Vector3 = _player.global_position + Vector3(
			_rng.randf_range(-1.2, 1.2), _rng.randf_range(0.8, 2.6),
			_rng.randf_range(-1.2, 1.2))
	var speed := 95.0
	_vfx.fire_tracer(from, to, speed)
	_pending.append({
		"pos": to, "t": from.distance_to(to) / speed,
		"dmg": 0, "idx": -1, "kind": "mg",
	})


func _update_pending(delta: float) -> void:
	var i := 0
	while i < _pending.size():
		var p: Dictionary = _pending[i]
		p["t"] -= delta
		if p["t"] > 0.0:
			i += 1
			continue
		if p["kind"] == "mg":
			_vfx.spark(p["pos"])
			_vfx.hit_flash(p["pos"], 0.7)
		# the rocket's own explosion VFX is fired by VfxManager on arrival
		if p["idx"] >= 0:
			_damage(p["idx"], p["dmg"])
		_pending.remove_at(i)


func _damage(i: int, amount: int) -> void:
	var e: Dictionary = _enemies[i]
	if e["hp"] <= 0:
		return
	e["hp"] -= amount
	var n: Node3D = e["node"]
	if e["hp"] > 0:
		n.scale = Vector3(1.12, 0.9, 1.12)      # hit punch, springs back below
		return
	_vfx.explosion(n.global_position + Vector3(0, 0.5, 0), 0.55)
	n.visible = false
	e["respawn"] = respawn_delay + _rng.randf() * 2.0


func _update_enemies(delta: float) -> void:
	var pp: Vector3 = _player.global_position
	for e in _enemies:
		var n: Node3D = e["node"]
		if e["hp"] <= 0:
			e["respawn"] -= delta
			if e["respawn"] <= 0.0:
				n.global_position = e["home"]
				n.visible = true
				n.scale = Vector3.ONE
				e["hp"] = enemy_hp
			continue
		n.scale = n.scale.lerp(Vector3.ONE, clampf(delta * 9.0, 0.0, 1.0))

		if enemy_fire:
			e["fire_t"] -= delta
			if e["fire_t"] <= 0.0:
				e["fire_t"] = enemy_fire_period + _rng.randf() * enemy_fire_jitter
				_enemy_shoot(n)

		var d: Vector3 = pp - n.global_position
		d.y = 0.0
		var dist := d.length()
		if dist > enemy_stop_radius:
			n.global_position += d / dist * enemy_drift * delta
			n.rotation.y = atan2(-d.x, -d.z)
