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
var _panel_bg: ColorRect
var _buttons: Array = []
var _panel_sig: String = ""
var _picked: int = -1        # 保险箱里选中的卡（-1 = 没选）

## 选中的武器卡 id（没选、或选的是装甲卡都返回 ""）
func _picked_weapon() -> String:
	if world == null or _picked < 0 or _picked >= world.shop.safe_box.size():
		return ""
	var c: Dictionary = world.shop.safe_box[_picked]
	if String(c.get("kind", "weapon")) != "weapon":
		return ""
	return String(c["id"])

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
	# §8.3：商店左边显示机甲底座，右侧是卡牌。开店时把世界视角左移腾地方。
	var want: Vector2 = Vector2(world.view_w, world.view_h) * 0.5 * PX
	if world.shop.open:
		want.x = world.view_w * PX * 0.24
	center = center.lerp(want, 1.0 - pow(0.001, delta))
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

## 商店里点底座的格子：把选中的卡装到那个位置
func _unhandled_input(event: InputEvent) -> void:
	if world == null or not world.shop.open or _picked < 0:
		return
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var m = world.mech
	var local: Vector2 = ((event.position - center) / PX).rotated(-m.rot)
	var half := float(m.base_size) * 0.5
	var cell := Vector2i(int(floor(local.x + half)), int(floor(local.y + half)))
	if cell.x < 0 or cell.y < 0 or cell.x >= m.base_size or cell.y >= m.base_size:
		return
	if _picked >= world.shop.safe_box.size():
		_picked = -1
		return
	var card: Dictionary = world.shop.safe_box[_picked]
	if String(card.get("kind", "weapon")) == "armor":
		# 装甲按方向装：点哪一格就算哪一面（局部方向 0=车头 1=右 2=车尾 3=左）
		var rel := Vector2(cell) + Vector2(0.5, 0.5) - Vector2(half, half)
		var side := 0
		if absf(rel.y) >= absf(rel.x):
			side = 0 if rel.y < 0.0 else 2
		else:
			side = 1 if rel.x > 0.0 else 3
		human.queued_action = {"type": "place", "index": _picked, "id": card["id"], "side": side}
	else:
		human.queued_action = {"type": "place", "index": _picked, "id": card["id"], "cell": cell}
	_picked = -1
	_panel_sig = ""
	get_viewport().set_input_as_handled()

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
		KEY_B:
			if world.shop.open:
				human.queued_action = {"type": "buy_all"}
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

	# 屏外的重甲炮台给个箭头。它 keep_distance 停在远处，眼前的杂兵又看不过来，
	# 手玩时根本不知道它在哪 —— 而它恰恰是唯一值得单发线出手的目标。
	for e in world.enemies:
		if not e.alive or e.wave_pos != 4:
			continue
		var ep := _screen(e.pos)
		if ep.x >= 0.0 and ep.y >= 0.0 and ep.x <= w and ep.y <= h:
			continue
		var to2 := (ep - center).normalized()
		var edge2 := center + to2 * (minf(w, h) * 0.42)
		var side2 := to2.orthogonal() * 9.0
		var tri2 := PackedVector2Array([edge2 + to2 * 20.0, edge2 + side2, edge2 - side2])
		draw_colored_polygon(tri2, Color(0.75, 0.45, 1.0, 0.9))

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
		if m.armor[i] <= 0.0 and m.armor_aura[i] <= 0.0:
			continue
		var n: Vector2 = SIDE_LOCAL[i].rotated(m.rot)
		var t: Vector2 = Vector2(-n.y, n.x)
		var col := Color(0.5, 0.8, 1.0).lerp(Color(1.0, 0.5, 0.3),
			clampf(m.armor_aura[i] / 200.0, 0.0, 1.0))
		draw_line(center + (n * hs + t * hs) * PX, center + (n * hs - t * hs) * PX,
			col, 2.0 + m.armor[i] * 30.0)
		# 链锯/齿轮/滚筒向外支出的那一圈（敌人挤不进来的范围）
		if m.armor_range[i] > 0.0:
			var out: float = hs + m.armor_range[i]
			draw_line(center + (n * out + t * out) * PX, center + (n * out - t * out) * PX,
				Color(1.0, 0.6, 0.2, 0.5), 2.0)

	# 底座格盘：空槽画虚框，中心禁区画叉
	var half := float(m.base_size) * 0.5
	var pick_weapon := _picked_weapon()
	for gy in m.base_size:
		for gx in m.base_size:
			var cell := Vector2i(gx, gy)
			var occupied := false
			for t2 in m.turrets:
				if m.cells_of(t2).has(cell):
					occupied = true
					break
			if occupied:
				continue
			var o := (Vector2(cell) + Vector2(0.5, 0.5) - Vector2(half, half)).rotated(m.rot)
			var cp := center + o * PX
			var in_center: bool = not m.can_place(cell, 1)
			var col2 := Color(1, 1, 1, 0.10) if in_center else Color(0.6, 0.9, 1.0, 0.30)
			if pick_weapon != "" and world.shop.open and not in_center:
				col2 = Color(0.5, 1.0, 0.6, 0.85)      # 选了卡，能放的格子亮起来
			var r := PX * 0.36
			var quad := PackedVector2Array()
			for corner in [Vector2(-r, -r), Vector2(r, -r), Vector2(r, r), Vector2(-r, r)]:
				quad.append(cp + corner.rotated(m.rot))
			quad.append(quad[0])
			draw_polyline(quad, col2, 1.0)
			if in_center:
				draw_line(quad[0], quad[2], col2, 1.0)
				draw_line(quad[1], quad[3], col2, 1.0)

	var pick_id := _picked_weapon()
	for t in m.turrets:
		var wp: Vector2 = center + m.turret_offset(t).rotated(m.rot) * PX
		var col := Color(String(world.db.weapons.get(t.weapon_id, {}).get("color", "#ffffff")))
		# 三条枪线用三种形状区分（手玩时全是圆点根本分不清哪门是哪门）：
		# 初始枪 + 机枪线 = 圆，单发线 = 三角，散弹线 = 方块。
		var line := String(world.db.weapons.get(t.weapon_id, {}).get("line", ""))
		var r0 := 9.0 * float(t.size)
		var face: Vector2 = m.turret_offset(t).rotated(m.rot)
		if face.length_squared() < 0.01:
			face = Vector2(0, -1).rotated(m.rot)
		face = face.normalized()
		if line == "rifle" and t.weapon_id != "gun":
			var tri := PackedVector2Array()
			for a in [0.0, TAU / 3.0, TAU * 2.0 / 3.0]:
				tri.append(wp + face.rotated(a) * r0 * 1.25)
			draw_colored_polygon(tri, col)
			tri.append(tri[0])
			draw_polyline(tri, col.darkened(0.4), 1.5)
		elif line == "spread":
			var sq := PackedVector2Array()
			var perp := face.orthogonal()
			for c in [face + perp, face - perp, -face - perp, -face + perp]:
				sq.append(wp + c * r0 * 0.78)
			draw_colored_polygon(sq, col)
			sq.append(sq[0])
			draw_polyline(sq, col.darkened(0.4), 1.5)
		else:
			draw_circle(wp, r0 * 0.9, col)
			draw_arc(wp, r0 * 0.9, 0, TAU, 20, col.darkened(0.4), 1.5)
		# 选中的卡能把这门塔顶上去一级：套个绿环，表示这里可以点
		if pick_id != "" and t.weapon_id == pick_id 				and t.level < world.db.weapon_max_level(pick_id):
			draw_arc(wp, 16.0 * float(t.size), 0, TAU, 24, Color(0.5, 1.0, 0.6, 0.9), 2.5)
		draw_string(ThemeDB.fallback_font, wp + Vector2(-4, 4), str(t.level),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0, 0, 0, 0.85))
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

	_panel_bg = ColorRect.new()
	_panel_bg.color = Color(0.05, 0.06, 0.09, 0.88)
	_panel_bg.position = Vector2(920, 100)
	_panel_bg.size = Vector2(960, 880)
	_panel_bg.visible = false
	layer.add_child(_panel_bg)

	_panel = VBoxContainer.new()
	_panel.position = Vector2(940, 120)
	_panel.custom_minimum_size = Vector2(900, 0)
	_panel.visible = false
	layer.add_child(_panel)

## 商店面板只在状态真的变化时重建。
## **不能每帧重建**：按钮的按下和松开分属两帧，每帧 queue_free 会让按下时的
## 那个按钮实例在松开前被销毁，pressed 信号永远不触发——点了没反应就是这么来的。
## §8.3 的拖拽版留到数值验证完再做。
func _shop_signature() -> String:
	var shop = world.shop
	var parts: Array = [str(_picked), str(int(world.mech.coins)), str(shop.safe_box.size()),
		str(shop.pending_line_choice.size()), str(world.mech.base_size)]
	for c in shop.cards:
		parts.append("-" if c == null else String(c["id"]))
	for c in shop.safe_box:
		parts.append(String(c["id"]))
	for t in world.mech.turrets:
		parts.append("%s%d@%d,%d" % [t.weapon_id, t.level, t.cell.x, t.cell.y])
	for i in 4:
		parts.append("%d.%d" % [world.mech.armor_tier[i], world.mech.armor_level[i]])
	return "|".join(parts)

func _sync_panel() -> void:
	var shop = world.shop
	_panel.visible = shop.open
	_panel_bg.visible = shop.open
	if not shop.open:
		_panel_sig = ""
		return
	var sig := _shop_signature()
	if sig == _panel_sig:
		return
	_panel_sig = sig
	for c in _panel.get_children():
		_panel.remove_child(c)
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

	_row("卡槽（点击购买，买走自动补货）", 16)
	# 有 7000 金币而卡只要 100 时，一张一张点是手指劳动不是决策
	var cheapest := 1.0e9
	for c0 in shop.cards:
		if c0 != null:
			cheapest = minf(cheapest, float(c0["price"]))
	_btn("全买（买到没钱或保险箱满）",
		func(): human.queued_action = {"type": "buy_all"},
		m.coins >= cheapest and shop.safe_box.size() < shop.safe_box_cap())
	for i in shop.cards.size():
		var c = shop.cards[i]
		if c == null:
			continue
		var idx: int = i
		var afford: bool = m.coins >= float(c["price"])
		_btn("%s　%d 金币%s" % [c["name"], int(c["price"]), "" if afford else "（买不起）"],
			func(): human.queued_action = {"type": "buy", "index": idx}, afford)

	if not shop.safe_box.is_empty():
		_row("保险箱 %d/%d（点卡选中 → 再点左边底座的格子放置；右边是卖掉）"
			% [shop.safe_box.size(), shop.safe_box_cap()], 16)
		for i in mini(shop.safe_box.size(), 8):
			var c2 = shop.safe_box[i]
			var idx2: int = i
			var h := HBoxContainer.new()
			_panel.add_child(h)
			var b1 := Button.new()
			var is_armor: bool = String(c2.get("kind", "weapon")) == "armor"
			b1.text = ("▶ " if idx2 == _picked else "") + String(c2["name"]) 				+ ("　（选中后点底座某一面）" if is_armor else "　（选中后点底座空格）")
			b1.custom_minimum_size = Vector2(660, 34)
			b1.pressed.connect(func() -> void:
				_picked = -1 if _picked == idx2 else idx2
				_panel_sig = "")
			h.add_child(b1)
			var b2 := Button.new()
			b2.text = "卖 %d" % int(float(c2["price"]) * 0.25)
			b2.custom_minimum_size = Vector2(240, 34)
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
	lines.append("WASD 移动   Q/E 转 90°   1-4 买卡   B 全买   空格 4 倍速   R 换种子重开   Esc 退出")
	if world.over:
		lines.append(">>> %s   存活 %.1fs   推到第 %d 波   击杀 %d   （R 重开）" % [
			world.log.result, world.log.run_duration, world.log.wave_reached, world.log.kills_total])
	_hud.text = "\n".join(lines)
