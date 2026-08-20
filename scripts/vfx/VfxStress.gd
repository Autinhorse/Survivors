extends Node3D
## Section 23 VFX stress driver.
##
## Deliberately NOT gameplay: it holds a target number of live projectiles and a
## target explosion rate over the arena, so the VFX load can be dialled
## independently of the crowd.  Section 23 is explicit that enemy-count testing
## and VFX testing must not be mixed, because the two bottlenecks are different
## (crowd = CPU/draw calls, VFX = overdraw/fill rate).
##
## Levels from section 23:
##   0  off
##   1  ~100 projectiles,  ~10 explosions/sec
##   2  ~300 projectiles,  ~30 explosions/sec
##   3  ~500 projectiles,  ~50 explosions/sec
##   4  ~1000 projectiles, ~100 explosions/sec

@export var vfx_path: NodePath
@export var center_path: NodePath

@export_group("Load")
## Live projectiles held on screen (not shots per second -- concurrency is what
## costs, and it is what section 23 specifies).
@export var target_projectiles: int = 0
@export var explosions_per_sec: float = 0.0
## Share of projectiles that are rockets: a mesh body plus a continuous smoke
## trail, i.e. the expensive kind.  Tracers are the cheap kind.
@export var rocket_fraction: float = 0.05
## Diagnostic: run explosions only, so smoke density can be judged on its own.
@export var projectiles_disabled: bool = false

@export_group("Arena")
@export var radius: float = 22.0
@export var height: float = 1.5

var _vfx: Node3D
var _center: Node3D
var _rng := RandomNumberGenerator.new()
var _live := 0
var _expl_acc := 0.0
var _tracer_life := 0.0


func _ready() -> void:
	_rng.seed = 31337
	_vfx = get_node_or_null(vfx_path)
	_center = get_node_or_null(center_path)
	if _vfx == null:
		set_process(false)


func level(n: int) -> void:
	match n:
		0:
			target_projectiles = 0
			explosions_per_sec = 0.0
		1:
			target_projectiles = 100
			explosions_per_sec = 10.0
		2:
			target_projectiles = 300
			explosions_per_sec = 30.0
		3:
			target_projectiles = 500
			explosions_per_sec = 50.0
		4:
			target_projectiles = 1000
			explosions_per_sec = 100.0


func _origin() -> Vector3:
	return _center.global_position if _center else Vector3.ZERO


func _point() -> Vector3:
	var a := _rng.randf() * TAU
	var d: float = radius * sqrt(_rng.randf())
	var c := _origin()
	return Vector3(c.x + cos(a) * d, 0.0, c.z + sin(a) * d)


func _process(delta: float) -> void:
	# --- projectiles: keep `target_projectiles` in flight ---------------------
	# A tracer lives distance/speed seconds, so holding N alive means firing
	# N/lifetime per second.  Measured from the actual travel distance rather
	# than assumed, so the concurrency figure in the CSV is honest.
	if target_projectiles > 0 and not projectiles_disabled:
		var speed := 130.0
		var span: float = radius * 1.2
		_tracer_life = span / speed
		var per_sec: float = float(target_projectiles) / maxf(_tracer_life, 0.001)
		var shots: int = int(per_sec * delta)
		if _rng.randf() < per_sec * delta - float(shots):
			shots += 1
		for i in shots:
			var from := _point() + Vector3(0.0, height, 0.0)
			var to := _point() + Vector3(0.0, height, 0.0)
			if _rng.randf() < rocket_fraction:
				_vfx.launch_rocket(from, to, 26.0)
			else:
				_vfx.fire_tracer(from, to, speed)

	# --- explosions ----------------------------------------------------------
	if explosions_per_sec > 0.0:
		_expl_acc += explosions_per_sec * delta
		while _expl_acc >= 1.0:
			_expl_acc -= 1.0
			_vfx.explosion_mass(_point(), _rng.randf_range(0.7, 1.4))


func live_projectiles() -> int:
	return target_projectiles


func explosion_rate() -> float:
	return explosions_per_sec
