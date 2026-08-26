extends Node2D
## Demo 3「数值验证」的手玩前端。
## 它只做三件事：读键盘 → 喂 sim → 把 sim 的状态画成方块。
## 一行规则都不许写在这里；想改数值去 data/*.json。
##
## 相机固定在机甲上：屏幕中心永远是机甲，其他东西按环形最短向量画在它周围。
## 所以地图是不是接缝处，画面上完全看不出来 —— 这正是 200×100 环形地图要的效果。

const SimConfig = preload("res://sim/core/SimConfig.gd")
const SimWorld = preload("res://sim/core/SimWorld.gd")
const HumanAgent = preload("res://sim/agent/HumanAgent.gd")

const PX := 40.0            # 1 格 = 40 像素，视野 48×27 格正好铺满 1920×1080

var world = null
var human = null
var accum: float = 0.0
var speed_mult: float = 1.0
var center := Vector2(960, 540)

var _hud: Label
var _panel: VBoxContainer
var _buttons: Array = []

func _ready() -> void:
	_build_ui()
	_start(0)

func _start(seed_value: int) -> void:
	var cfg = SimConfig.new()
	cfg.seed_value = seed_value
	cfg.label = "play"
	human = HumanAgent.new()
	world = SimWorld.new()
	world.setup(cfg, human)
	accum = 0.0
	center = Vector2(world.view_w, world.view_h) * 0.5 * PX
	for e in world.db.errors:
		push_warning("[data] " + e)
	# 截图/调试用：`-- skip=120` 直接快进到第 120 秒
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("skip="):
			var until := String(a).substr(5).to_float()
			while world.time < until and not world.over:
				if not world.pending_options.is_empty():
					human.pending_choice = 0
				world.tick()

func _process(delta: float) -> void:
	if world == null:
		return
	_read_keys()
	if not world.over:
		accum += delta * speed_mult
		var step: float = world.dt
		var guard := 0
		while accum >= step and guard < 240:
			world.tick()
			accum -= step
			guard += 1
			if not world.pending_options.is_empty() or world.over:
				accum = 0.0
				break
	_sync_panel()
	_update_hud()
	queue_redraw()

func _read_keys() -> void:
	var mv := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): mv.y -= 1.0
	if Input.is_key_pressed(KEY_S): mv.y += 1.0
	if Input.is_key_pressed(KEY_A): mv.x -= 1.0
	if Input.is_key_pressed(KEY_D): mv.x += 1.0
	# 只允许 4 方向（§10.1）：同时按两个轴时取水平
	if mv.x != 0.0 and mv.y != 0.0:
		mv.y = 0.0
	human.move = mv

func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_Q: human.turn = -1
		KEY_E: human.turn = 1
		KEY_1, KEY_2, KEY_3:
			var i: int = event.keycode - KEY_1
			if not world.pending_options.is_empty() and i < world.pending_options.size():
				human.pending_choice = i
		KEY_SPACE:
			speed_mult = 4.0 if speed_mult == 1.0 else 1.0
		KEY_R:
			_start(world.cfg.seed_value + 1)
		KEY_ESCAPE:
			get_tree().quit()

# ---------------------------------------------------------------- 画面

## 世界坐标 → 屏幕坐标。走环形最短向量，接缝上的东西也画在该在的地方。
func _screen(p: Vector2) -> Vector2:
	return center + world.torus.delta(world.mech.pos, p) * PX

func _draw() -> void:
	if world == null:
		return
	var w: float = world.view_w * PX
	var h: float = world.view_h * PX
	draw_rect(Rect2(0, 0, w, h), Color(0.09, 0.10, 0.12))

	# 网格跟着世界走（机甲移动时能看出自己在动）
	var m: Vector2 = world.mech.pos
	var ox := fposmod(center.x - m.x * PX, PX)
	var oy := fposmod(center.y - m.y * PX, PX)
	var x := ox
	while x < w:
		draw_line(Vector2(x, 0), Vector2(x, h), Color(1, 1, 1, 0.05))
		x += PX
	var y := oy
	while y < h:
		draw_line(Vector2(0, y), Vector2(w, y), Color(1, 1, 1, 0.05))
		y += PX

	# 敌人：颜色按周期内的位置分（八种波型八个色），大小按血量
	const WAVE_COLOR := [
		Color("#8fb3d9"), Color("#7ec850"), Color("#c8a24a"), Color("#e0553f"),
		Color("#ff7ad9"), Color("#5ad2c8"), Color("#ffd24a"), Color("#b48cff"),
	]
	for e in world.enemies:
		var sp := _screen(e.pos)
		if sp.x < -40.0 or sp.y < -40.0 or sp.x > w + 40.0 or sp.y > h + 40.0:
			continue
		draw_circle(sp, e.radius * PX, WAVE_COLOR[clampi(e.wave_pos - 1, 0, 7)])
		if e.hp < e.max_hp:
			var frac: float = e.hp / e.max_hp
			var top := sp - Vector2(e.radius * PX, (e.radius + 0.25) * PX)
			draw_rect(Rect2(top, Vector2(e.radius * 2.0 * PX * frac, 3)), Color(1, 0.3, 0.3))

	for b in world.enemy_bullets:
		draw_circle(_screen(b.pos), 3.0, Color(1, 0.45, 0.35))
	for p in world.projectiles:
		draw_circle(_screen(p.pos), maxf(2.0, p.aoe_radius * PX * 0.15 + 2.0), Color(1, 0.95, 0.7))

	_draw_mech()

func _draw_mech() -> void:
	var m = world.mech
	var hs: float = m.half_size
	var pts := PackedVector2Array()
	for corner in [Vector2(-hs, -hs), Vector2(hs, -hs), Vector2(hs, hs), Vector2(-hs, hs)]:
		pts.append(center + corner.rotated(m.rot) * PX)
	draw_colored_polygon(pts, Color(0.22, 0.24, 0.30))
	pts.append(pts[0])
	draw_polyline(pts, Color(0.8, 0.85, 1.0) if m.can_fire() else Color(1.0, 0.6, 0.2), 2.0)

	# 四面装甲厚度可视化（局部 0=车头 1=右 2=车尾 3=左）
	const SIDE_LOCAL := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]
	for i in 4:
		if m.armor[i] <= 0.0 and m.contact_damage[i] <= 0.0:
			continue
		var n: Vector2 = SIDE_LOCAL[i].rotated(m.rot)
		var t: Vector2 = Vector2(-n.y, n.x)
		var col := Color(0.5, 0.8, 1.0).lerp(Color(1.0, 0.5, 0.3),
			clampf(m.contact_damage[i] / 30.0, 0.0, 1.0))
		draw_line(center + (n * hs + t * hs) * PX, center + (n * hs - t * hs) * PX,
			col, 2.0 + m.armor[i] * 30.0)

	for t in m.turrets:
		var wp := center + Mech_offset(m, t) * PX
		var col := Color(String(world.db.weapons.get(t.weapon_id, {}).get("color", "#ffffff")))
		draw_circle(wp, 8.0, col)
		draw_arc(wp, 12.0, 0, TAU, 16, col.darkened(0.3), 1.5)
	# 车头指示
	draw_line(center, center + Vector2(0, -hs - 0.6).rotated(m.rot) * PX, Color(1, 0.9, 0.2), 3.0)

func Mech_offset(m, t) -> Vector2:
	return m.SLOT_OFFSETS[t.slot].rotated(m.rot)

# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 8)
	_hud.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_hud.add_theme_font_size_override("font_size", 16)
	layer.add_child(_hud)

	_panel = VBoxContainer.new()
	_panel.position = Vector2(660, 380)
	_panel.custom_minimum_size = Vector2(600, 0)
	_panel.visible = false
	layer.add_child(_panel)
	var title := Label.new()
	title.text = "升级（点按钮或按 1/2/3）　※ P6 会换成金币商店"
	title.add_theme_font_size_override("font_size", 20)
	_panel.add_child(title)
	for i in 3:
		var b := Button.new()
		b.custom_minimum_size = Vector2(600, 48)
		b.pressed.connect(func() -> void: human.pending_choice = i)
		_panel.add_child(b)
		_buttons.append(b)

func _sync_panel() -> void:
	var show: bool = not world.pending_options.is_empty()
	_panel.visible = show
	if not show:
		return
	for i in _buttons.size():
		var b: Button = _buttons[i]
		if i < world.pending_options.size():
			b.visible = true
			b.text = "%d. %s" % [i + 1, String(world.pending_options[i].get("text", "?"))]
		else:
			b.visible = false

func _update_hud() -> void:
	var m = world.mech
	var wave: int = world.spawner.current_wave()
	var st: Dictionary = world.spawner.wave_stats(maxi(1, wave))
	var lines: Array = []
	lines.append("t %5.1fs   第 %d 波（周期 %d 第 %d 位·%s）   HP %.0f/%.0f   金币 %d" % [
		world.time, wave, int(st.get("cycle", 1)), int(st.get("pos", 1)),
		String(st.get("name", "")), m.hp, m.max_hp, int(m.coins)])
	lines.append("本波 数量 %d  单只血量 %.0f  攻击力 %.0f  金币 %.0f   |   场上 %d  峰值 %d  击杀 %d  受伤 %.0f" % [
		int(round(float(st.get("count", 0)))), float(st.get("hp", 0)),
		float(st.get("attack", 0)), float(st.get("coin", 0)),
		world.enemies.size(), world.log.peak_enemies, world.log.kills_total, world.log.damage_taken])
	var turret_txt: Array = []
	for t in m.turrets:
		turret_txt.append("%s Lv%d(槽%d)" % [world.db.weapon_name(t.weapon_id), t.level, t.slot])
	lines.append("炮塔 " + "  ".join(turret_txt) + ("   ⟲ 转向中·停火" if m.turning else ""))
	const SIDE := ["头", "右", "尾", "左"]
	var armor_txt: Array = []
	for i in 4:
		armor_txt.append("%s %d%%/%d" % [SIDE[i], int(m.armor[i] * 100.0), int(m.contact_damage[i])])
	lines.append("装甲 " + "  ".join(armor_txt) + "   位置 %.0f,%.0f / %.0fx%.0f" % [
		m.pos.x, m.pos.y, world.torus.w, world.torus.h])
	lines.append("WASD 移动   Q/E 转 90°   空格 4 倍速   R 换种子重开   Esc 退出")
	if world.over:
		lines.append(">>> %s   存活 %.1fs   推到第 %d 波   击杀 %d   （R 重开）" % [
			world.log.result, world.log.run_duration, world.log.wave_reached, world.log.kills_total])
	_hud.text = "\n".join(lines)
