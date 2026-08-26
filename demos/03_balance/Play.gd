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
				if world.shop.open:
					_auto_shop()
				world.tick()

## skip= 快进时没人点商店，用一套最简自动采购把店逛完
func _auto_shop() -> void:
	var guard := 40
	while world.shop.open and guard > 0:
		guard -= 1
		var ms: Array = world.shop.mergeable(world.mech)
		if not ms.is_empty():
			var kids: Array = world.shop.children_of(String(ms[0]["id"]))
			human.queued_action = {"type": "merge", "a": int(ms[0]["a"]), "b": int(ms[0]["b"]),
				"choice": String(kids[0]) if kids.size() > 1 else ""}
		elif not world.shop.safe_box.is_empty():
			human.queued_action = {"type": "place", "index": 0, "id": world.shop.safe_box[0]["id"]}
		else:
			var bought := false
			for i in world.shop.cards.size():
				var c = world.shop.cards[i]
				if c != null and world.mech.coins >= float(c["price"]):
					human.queued_action = {"type": "buy", "index": i}
					bought = true
					break
			if not bought:
				human.queued_action = {"type": "leave"}
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
			if world.shop.open or world.over:
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
		KEY_1, KEY_2, KEY_3, KEY_4:
			var i: int = event.keycode - KEY_1
			if world.shop.open and i < world.shop.cards.size() and world.shop.cards[i] != null:
				human.queued_action = {"type": "buy", "index": i}
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

	# 地上的金币（§4：死亡掉落，要走过去捡）
	for c in world.shop.coins:
		var cp := _screen(c.pos)
		if cp.x > -20.0 and cp.y > -20.0 and cp.x < w + 20.0 and cp.y < h + 20.0:
			draw_circle(cp, 4.0, Color(1.0, 0.85, 0.2))

	# 商店 + 保护罩；在屏外时给个方向箭头（§8）
	var site = world.shop.site
	if site != null:
		var sp := _screen(site.pos)
		draw_arc(sp, site.shield_radius * PX, 0, TAU, 48, Color(0.4, 0.9, 1.0, 0.35), 2.0)
		draw_rect(Rect2(sp - Vector2(site.size, site.size) * 0.5 * PX,
			Vector2(site.size, site.size) * PX), Color(0.3, 0.8, 1.0))
		if sp.x < 0.0 or sp.y < 0.0 or sp.x > w or sp.y > h:
			var to := (sp - center).normalized()
			var edge := center + to * (minf(w, h) * 0.45)
			draw_line(edge, edge + to * 28.0, Color(0.3, 0.8, 1.0), 4.0)

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
		var wp: Vector2 = center + m.turret_offset(t).rotated(m.rot) * PX
		var col := Color(String(world.db.weapons.get(t.weapon_id, {}).get("color", "#ffffff")))
		draw_circle(wp, 8.0 * float(t.size), col)
		draw_arc(wp, 12.0 * float(t.size), 0, TAU, 16, col.darkened(0.3), 1.5)
	# 车头指示
	draw_line(center, center + Vector2(0, -hs - 0.6).rotated(m.rot) * PX, Color(1, 0.9, 0.2), 3.0)

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
	_panel.position = Vector2(560, 200)
	_panel.custom_minimum_size = Vector2(800, 0)
	_panel.visible = false
	layer.add_child(_panel)

## 商店面板每次重建 —— 内容变化频繁，UI 又小，重建比增量同步简单可靠。
## §8.3 的拖拽版留到数值验证完再做。
func _sync_panel() -> void:
	var shop = world.shop
	_panel.visible = shop.open
	if not shop.open:
		return
	for c in _panel.get_children():
		c.queue_free()
	var m = world.mech

	_row("商店　金币 %d　保险箱 %d/%d　刷新价 %d" % [
		int(m.coins), shop.safe_box.size(),
		int(world.db.shop.get("slots", {}).get("safe_box", 8)), int(shop.refresh_cost())], 20)

	if not shop.pending_line_choice.is_empty():
		_row("选择升级线路：", 18)
		for wid in shop.pending_line_choice:
			var w2: String = wid
			_btn("→ %s" % world.db.weapon_name(w2), func(): human.queued_action = {"type": "line", "choice": w2})
		return

	for mm in shop.mergeable(m):
		var a: int = int(mm["a"])
		var b: int = int(mm["b"])
		var nm: String = world.db.weapon_name(String(mm["id"]))
		_btn("合并两个 3 级 %s（免费，空出一个槽）" % nm,
			func(): human.queued_action = {"type": "merge", "a": a, "b": b})

	_row("卡槽（点击购买）", 16)
	for i in shop.cards.size():
		var c = shop.cards[i]
		if c == null:
			continue
		var idx: int = i
		var afford: bool = m.coins >= float(c["price"])
		_btn("%s　%d 金币%s" % [c["name"], int(c["price"]), "" if afford else "（买不起）"],
			func(): human.queued_action = {"type": "buy", "index": idx}, afford)

	if not shop.safe_box.is_empty():
		_row("保险箱（点击装到底座 / 右边卖掉）", 16)
		for i in mini(shop.safe_box.size(), 8):
			var c2 = shop.safe_box[i]
			var idx2: int = i
			var h := HBoxContainer.new()
			_panel.add_child(h)
			var b1 := Button.new()
			b1.text = "装 %s" % c2["name"]
			b1.custom_minimum_size = Vector2(560, 34)
			b1.pressed.connect(func(): human.queued_action = {"type": "place", "index": idx2, "id": c2["id"]})
			h.add_child(b1)
			var b2 := Button.new()
			b2.text = "卖 %d" % int(float(c2["price"]) * 0.25)
			b2.custom_minimum_size = Vector2(220, 34)
			b2.pressed.connect(func(): human.queued_action = {"type": "sell_card", "index": idx2})
			h.add_child(b2)

	_btn("刷新（%d 金币）" % int(shop.refresh_cost()),
		func(): human.queued_action = {"type": "refresh"}, m.coins >= shop.refresh_cost())
	_btn("离开商店", func(): human.queued_action = {"type": "leave"})

func _row(text: String, size: int) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	_panel.add_child(l)

func _btn(text: String, cb: Callable, enabled: bool = true) -> void:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.custom_minimum_size = Vector2(800, 34)
	b.pressed.connect(cb)
	_panel.add_child(b)

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
		turret_txt.append("%s Lv%d%s" % [world.db.weapon_name(t.weapon_id), t.level,
			"[2x2]" if t.size > 1 else ""])
	lines.append("底座 %dx%d　炮塔 " % [m.base_size, m.base_size] + "  ".join(turret_txt)
		+ ("   ⟲ 转向中·停火" if m.turning else ""))
	lines.append("商店 %d 次　合并 %d 次　地上金币 %d 堆" % [
		world.shop.visits, world.log.merge_count, world.shop.coins.size()])
	const SIDE := ["头", "右", "尾", "左"]
	const ARMOR_NAME := ["无", "甲", "刺", "锯", "齿", "滚"]
	var armor_txt: Array = []
	for i in 4:
		var nm: String = ARMOR_NAME[0] if m.armor_level[i] == 0 else ARMOR_NAME[m.armor_tier[i] + 1]
		armor_txt.append("%s %s%d 减%d%%" % [SIDE[i], nm, m.armor_level[i], int(m.armor[i] * 100.0)])
	lines.append("装甲 " + "  ".join(armor_txt) + "   位置 %.0f,%.0f / %.0fx%.0f" % [
		m.pos.x, m.pos.y, world.torus.w, world.torus.h])
	lines.append("WASD 移动   Q/E 转 90°   1-4 买卡   空格 4 倍速   R 换种子重开   Esc 退出")
	if world.over:
		lines.append(">>> %s   存活 %.1fs   推到第 %d 波   击杀 %d   （R 重开）" % [
			world.log.result, world.log.run_duration, world.log.wave_reached, world.log.kills_total])
	_hud.text = "\n".join(lines)
