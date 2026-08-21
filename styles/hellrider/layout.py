# -*- coding: utf-8 -*-
"""风格 "hellrider" 的布局：熔岩夹着的方形场地里的一座村庄。

和 gatling 的布局**不共用**，理由是美术语言差得太远：
参考图是 45° 等距投影的熔岩走廊，村庄的构图逻辑完全不同。

三条来自需求的约束：

  1. **正交轴向**。参考图是 45° 菱形网格（等距投影的产物），
     本项目是方形世界，所以场地、方格铺地、河流全部沿轴，不做菱形旋转。
     只有熔岩外侧那层纯装饰的菱形色块保留 45°，那是图形层不是世界层。
  2. **河流直来直去**。gatling 那条正弦蜿蜒的河在这里是错的语言。
     一条笔直的、沿 Z 的河道，边界是硬的。
  3. **相机不变**（60° 俯角、44 m、FOV 40）。那是玩法决定，不是美术风格决定，
     换风格不该动它 —— 否则两个风格连"看到多大范围"都不一样了。

场地宽度取 40 m，而相机可见宽度是 65.7 m，所以两侧各露出约 13 m 熔岩 ——
参考图里熔岩大约占画面三分之一，这是这个风格最强的识别元素，必须进画面。
"""
import math
import random

from tscnlib import *          # noqa: F401,F403

random.seed(20260821)

# ------------------------------------------------------------------ 场地 --
FIELD_HALF = 20.0            # 场地半宽（不含锯齿）
FIELD_Z0, FIELD_Z1 = -46.0, 36.0
# 锯齿的尺寸靠量，不靠"看着够不够明显"。
# 判据：熔岩边界的**逐行抖动 std**。参考图是 9-55 px（画面宽 565-596 px），
# 折算到我们 1920 px 的画面约是 30-180 px；
# 我凭感觉调到 5.2 m 时实测 std 133-200 px，已经超出上限 ——
# 而且巨齿会把"两条边平不平行"的拟合带偏。
TOOTH_LEN, TOOTH_DEPTH = 5.0, 2.8

# ------------------------------------------------------------------ 河流 --
# 笔直、沿 Z、轴向。没有曲线，没有宽窄变化 —— 那是上一个风格的语言。
RIVER_X = 9.5
RIVER_W = 7.0
RIVER_Y = 0.03               # **在地面之上**。不透明的平面直接盖住地面，
                             # 这个风格不需要挖河床 —— 参考图的水域就是一块平色。
                             # 第一版放在 -0.10，整条河被地面挡住了。
BANK_W = 0.7                 # 深色岸线的宽度

# -------------------------------------------------------------------- 桥 --
BRIDGE_Z = -6.0
BRIDGE_L = 14.0
BRIDGE_W = 6.0

# ------------------------------------------------------------------ 相机 --
# **正交投影**。实测参考图：通道宽度从画面顶端到底端完全不变
# （收敛斜率 −0.005 px/行），只有正交做得到；我们原来的透视是 +1.06 px/行。
CAM_ORTHO = True
CAM_ORTHO_SIZE = 37.0        # 纵向世界高度；16:9 下横向 = 37*16/9 = 65.8 m
# 俯角 40°。参考图里石头和树的**侧面露得很多、树干看得见**，60° 做不到这个。
# 用三档（60/48/38）并排比出来的，见 styles/hellrider/pitch_compare.png。
#
# **这一条不只是观感，是玩法参数**：正交下可见纵深 = size / sin(俯角)，
#   60° -> 42.7 m      40° -> 57.6 m
# 看得更远，屏幕外生成半径要跟着重算（见 spawn_radius()）。
CAM_PITCH = 40.0
CAM_HEIGHT = 44.0
CAM_FOV = 40.0
CAM_FOCUS_Z = 0.5

FORWARD_PLUS = False


def camera_z():
    return CAM_FOCUS_Z + CAM_HEIGHT / math.tan(math.radians(CAM_PITCH))


def frame_size(aspect=16.0 / 9.0):
    if CAM_ORTHO:
        # 正交：可见区域是**矩形**。横向 = size*aspect（1:1 映射到地面），
        # 纵向 = size / sin(俯角)（地面被俯角压缩）。
        w = CAM_ORTHO_SIZE * aspect
        depth = CAM_ORTHO_SIZE / math.sin(math.radians(CAM_PITCH))
        # 中心是相机在地面上的**注视点**，不是相机自身的 z
        return CAM_FOCUS_Z - depth * 0.5, CAM_FOCUS_Z + depth * 0.5, w
    half = CAM_FOV / 2.0
    far = CAM_HEIGHT / math.tan(math.radians(max(CAM_PITCH - half, 1.0)))
    near = CAM_HEIGHT / math.tan(math.radians(min(CAM_PITCH + half, 89.0)))
    d = CAM_HEIGHT / math.sin(math.radians(CAM_PITCH))
    width = 2.0 * d * math.tan(math.atan(math.tan(math.radians(half)) * aspect))
    return camera_z() - far, camera_z() - near, width


def spawn_radius(margin=1.1, aspect=16.0 / 9.0):
    """屏幕外生成的最小世界半径。

    **正交下可见区域是矩形**，比透视简单得多 ——
    gatling 那边是梯形（近边 ±27.2 m、远边 ±41.6 m），要按最远的角算。
    这里只需要矩形的半对角线。
    """
    zf, zn, w = frame_size(aspect)
    return math.hypot(w * 0.5, (zn - zf) * 0.5) * margin


def in_river(x, margin=1.5):
    return abs(x - RIVER_X) < RIVER_W * 0.5 + margin


def clearance_items():
    return [
        ("Bridge", footprint(RIVER_X, BRIDGE_Z, BRIDGE_L, BRIDGE_W, 0.0)),
        ("HouseA", footprint(-11.0, -8.0, 6.1, 4.9, 0.0)),
        ("HouseB", footprint(-4.0, -16.0, 4.9, 4.3, 0.0)),
        ("HouseC", footprint(-13.5, 4.0, 6.9, 5.3, 0.0)),
        ("HouseD", footprint(-3.0, 2.0, 6.1, 4.9, 0.0)),
    ]


def build(MAT, MESH, performance=False):
    box = sub("BoxMesh", "MeshBox", size="Vector3(1, 1, 1)")
    cyl = sub("CylinderMesh", "MeshCyl", top_radius="0.5", bottom_radius="0.5",
              height="1.0", radial_segments="10")
    plane = sub("PlaneMesh", "MeshPlane", size="Vector2(1, 1)")

    nodes.append('[node name="HellRiderBenchmark" type="Node3D"]')

    # ----------------------------------------------------------- 环境与光 --
    # 平面着色风格的环境是**刻意贫瘠**的：没有天空渐变做氛围、没有雾、
    # 环境光压得很低。gatling 那套（夕阳天光 + 深度雾 + 饱和度微调）
    # 在这里会把纯色块糊掉，风格就散了。
    env = sub("Environment", "Env",
              background_mode="1",
              background_color=col(0.086, 0.055, 0.075),
              ambient_light_source="2",
              ambient_light_color=col(0.400, 0.360, 0.420),
              ambient_light_energy="0.62",
              tonemap_mode="2", tonemap_exposure="1.0", tonemap_white="6.0",
              # 不开 glow。平面着色风格里 bloom 会给纯色块镶一圈光晕，
              # 白色的小兵直接变成发光的团 —— 纯色块的干净感就没了。
              glow_enabled="false",
              fog_enabled="false",
              adjustment_enabled="true", adjustment_saturation="0.90",
              adjustment_contrast="1.0", adjustment_brightness="1.0")
    node("WorldEnvironment", "WorldEnvironment", ".", {"environment": env})

    # 光源接近正上方偏一侧：分档着色下，斜光会让同一块石头出现太多台阶，
    # 参考图里每块石头只有 3 个明确的面
    node("Sun", "DirectionalLight3D", ".",
         {"light_color": col(1.0, 0.96, 0.90), "light_energy": "1.75",
          "shadow_enabled": "true", "shadow_opacity": "0.22",
          "shadow_bias": "0.03", "shadow_normal_bias": "1.0",
          "shadow_blur": "2.4",
          "directional_shadow_max_distance": "120.0"},
         T((0.0, 24.0, 0.0), ry=-150.0, rx=-58.0))

    node("GameplayCamera", "Camera3D", ".",
         {"script": ext("Script",
                        "res://scripts/environment/GameplayCameraPolicy.gd"),
          "fov": "%.1f" % CAM_FOV, "near": "0.5", "far": "300.0",
          "current": "true", "aspect_policy": '"clamp"',
          "design_fov_vertical": "%.1f" % CAM_FOV,
          "orthographic": "true" if CAM_ORTHO else "false",
          "ortho_size": "%.1f" % CAM_ORTHO_SIZE},
         T((0.0, CAM_HEIGHT, camera_z()), rx=-CAM_PITCH))

    # ------------------------------------------------------- 场地与熔岩带 --
    node("Field", "Node3D", ".",
         {"script": ext("Script", "res://scripts/environment/HellField.gd"),
          "half_width": "%g" % FIELD_HALF,
          "z_start": "%g" % FIELD_Z0, "z_end": "%g" % FIELD_Z1,
          "tooth_len": "%g" % TOOTH_LEN, "tooth_depth": "%g" % TOOTH_DEPTH,
          # lava_drop 必须是 0：熔岩和地面共用同一条边界曲线，一旦有高差，
          # 俯视下就会从缝里漏出背景色，沿着锯齿描出一条黑线
          # （0.12 m 的落差在 60° 下是 0.07 m 水平缝 = 2 px，正好看得见）。
          # 两者 X 范围不重叠，共面也不会 z-fighting。
          "lava_width": "34.0", "lava_drop": "0.0", "lava_rows": "3",
          "ground_material": MAT["ground"], "lava_material": MAT["lava"]})

    # 熔岩里飘的小方块：参考图里数量不少，是这个风格的签名之一
    em = node("Embers", "Node3D", ".")
    for i in range(46):
        side = -1.0 if i % 2 else 1.0
        d = random.uniform(2.0, 26.0)
        x = side * (FIELD_HALF + TOOTH_DEPTH + d)
        z = random.uniform(FIELD_Z0 + 4.0, FIELD_Z1 - 4.0)
        s = random.uniform(0.35, 1.05)
        mesh("Ember%d" % i, em, box, MAT["lava"], (x, 0.02, z),
             ry=45.0, scale=(s, 0.06, s), cast_shadow="0")

    # ------------------------------------------------------------ 河与桥 --
    ri = node("River", "Node3D", ".")
    z_mid = (FIELD_Z0 + FIELD_Z1) * 0.5
    z_len = FIELD_Z1 - FIELD_Z0
    mesh("Water", ri, plane, MAT["water"], (RIVER_X, RIVER_Y, z_mid),
         scale=(RIVER_W, 1.0, z_len), cast_shadow="0")
    # 两条深色岸线：平面着色风格里，"边界"要靠一条硬的深色带交代，
    # 不能靠渐变或者法线
    for s in (-1.0, 1.0):
        mesh("Bank%s" % ("R" if s > 0 else "L"), ri, plane, MAT["waterdeep"],
             (RIVER_X + s * (RIVER_W * 0.5 + BANK_W * 0.5), RIVER_Y + 0.01,
              z_mid),
             scale=(BANK_W, 1.0, z_len), cast_shadow="0")
    # 水里的石头：参考图的水域里散着几块，打破笔直河道的单调
    for i, (dz, dx, sc) in enumerate(((-30.0, -1.6, 1.1), (-14.0, 1.9, 0.8),
                                      (4.0, -1.2, 0.9), (18.0, 2.0, 1.2),
                                      (28.0, -2.0, 0.7))):
        instance("WaterRock%d" % i, ri,
                 ext("PackedScene", MESH("rocks.glb")),
                 T((RIVER_X + dx, RIVER_Y + 0.02, dz), ry=i * 37.0,
                   scale=(sc, sc * 0.8, sc)),
                 child="rock_block_0", override=MAT["flat"])

    br = node("Bridge", "Node3D", ".")
    instance("Deck", br, ext("PackedScene", MESH("bridge.glb")),
             T((RIVER_X, 0.16, BRIDGE_Z), ry=90.0),
             child="bridge", override=MAT["flat"])

    # ------------------------------------------------------------ 村庄 --
    bl = node("Buildings", "Node3D", ".")
    for nm, src, px, pz, ry in (("HouseA", "house_c", -11.0, -8.0, 12.0),
                                ("HouseB", "house_b", -4.0, -16.0, -8.0),
                                ("HouseC", "house_c", -13.5, 4.0, -6.0),
                                ("HouseD", "house_a", -3.0, 2.0, 16.0)):
        instance(nm, bl, ext("PackedScene", MESH("%s.glb" % src)),
                 T((px, 0.0, pz), ry=ry), child=src, override=MAT["flat"])

    # 房屋的 blob 阴影（它们是单独实例，不走 ScatterField）
    for nm, _src, px, pz, _ry, bs in (("HouseA", "", -11.0, -8.0, 0, 8.0),
                                      ("HouseB", "", -4.0, -16.0, 0, 6.6),
                                      ("HouseC", "", -13.5, 4.0, 0, 8.6),
                                      ("HouseD", "", -3.0, 2.0, 0, 7.6)):
        mesh("Blob" + nm, bl, plane, MAT["blob"], (px, 0.03, pz),
             scale=(bs, 1.0, bs * 0.85), cast_shadow="0")

    # --------------------------------------------------------- 散布 --
    # 疏密：参考图有大片空地，物件成组出现。上一个风格实测"安静块占比"只有
    # 目标的 5/13，这次一开始就按成组 + 留空来摆。
    taken = [(RIVER_X, 0.0, RIVER_W * 0.5 + 2.5)]
    for _n, _s, px, pz, _r in (("A", "", -11.0, -8.0, 0), ("B", "", -4.0, -16.0, 0),
                               ("C", "", -13.5, 4.0, 0), ("D", "", -3.0, 2.0, 0)):
        taken.append((px, pz, 5.0))

    def free(x, z, r):
        if in_river(x, 2.0):
            return False
        if abs(x) > FIELD_HALF - 2.0:
            return False
        for tx, tz, tr in taken:
            if math.hypot(x - tx, z - tz) < tr + r:
                return False
        return True

    def cluster(node_name, parent, src, child_names, spots, scale_range,
                y=0.0, blob=2.1):
        pl = []
        for cx, cz, n, spread in spots:
            for _k in range(n):
                a = random.uniform(0.0, math.tau)
                d = random.uniform(0.0, spread)
                x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
                s = random.uniform(*scale_range)
                if not free(x, z, s * 0.8):
                    continue
                taken.append((x, z, s * 0.8))
                pl += [x, y, z, random.uniform(0.0, 360.0), s, s, s]
        node(node_name, "Node3D", parent, {
            "script": ext("Script", "res://scripts/environment/ScatterField.gd"),
            "kind": '"rock"',
            "source_scene": ext("PackedScene", MESH(src)),
            "variants": str(len(child_names)),
            "material": MAT["flat"],
            "blob_material": MAT["blob"],
            "blob_scale": "%g" % blob,
            "placements": "PackedFloat32Array(%s)"
                          % ", ".join("%.3f" % v for v in pl)})
        return len(pl) // 7

    sc = node("Scatter", "Node3D", ".")
    n_rock = cluster("Rocks", sc, "rocks.glb", range(8),
                     [(-16.0, -30.0, 7, 5.0), (14.0, -34.0, 5, 4.5),
                      (-17.0, 20.0, 6, 5.0), (13.0, 24.0, 5, 4.0),
                      (-8.0, -26.0, 4, 3.5), (16.0, 8.0, 4, 3.5)],
                     (0.8, 2.0))
    n_tree = cluster("Trees", sc, "trees.glb", range(4),
                     [(-15.0, -18.0, 5, 4.0), (-16.0, 12.0, 6, 5.0),
                      (4.0, -30.0, 5, 4.5), (-6.0, 22.0, 5, 4.0),
                      (15.0, -12.0, 4, 3.5)],
                     (0.85, 1.25), blob=2.6)
    n_bush = cluster("Bushes", sc, "bushes.glb", range(6),
                     [(-12.0, -12.0, 6, 4.0), (-2.0, -8.0, 5, 4.0),
                      (-14.0, 16.0, 6, 4.5), (8.0, 14.0, 5, 4.0),
                      (2.0, -24.0, 5, 4.0), (17.0, -2.0, 4, 3.0)],
                     (0.7, 1.3))
    n_peb = cluster("Pebbles", sc, "pebbles.glb", range(4),
                    [(-16.0, -30.0, 8, 6.0), (-17.0, 20.0, 8, 6.0),
                     (-9.0, -6.0, 6, 5.0), (12.0, 26.0, 6, 5.0)],
                    (0.6, 1.1), blob=1.5)
    print("scatter: %d rocks, %d trees, %d bushes, %d pebbles"
          % (n_rock, n_tree, n_bush, n_peb))

    # --------------------------------------------------------- 单位 --
    # 玩家和几个敌人，只为给尺度参照。这个风格的单位也是纯色块。
    pl = node("Player", "Node3D", ".", None, T((-6.0, 0.0, -2.0), ry=24.0))
    mesh("Body", pl, box, MAT["player"], (0.0, 1.0, 0.0), scale=(1.5, 1.6, 2.1))
    mesh("Head", pl, box, MAT["player"], (0.0, 2.1, 0.15), scale=(0.9, 0.7, 0.9))
    mesh("GunL", pl, box, MAT["enemydark"], (-0.95, 1.35, -1.1),
         scale=(0.28, 0.28, 2.2))
    mesh("GunR", pl, box, MAT["enemydark"], (0.95, 1.35, -1.1),
         scale=(0.28, 0.28, 2.2))
    for i, dx in enumerate((-0.55, 0.55)):
        mesh("Leg%d" % i, pl, box, MAT["enemydark"], (dx, 0.3, 0.1),
             scale=(0.45, 0.6, 0.6))

    en = node("Enemies", "Node3D", ".")
    n_en = 0
    for i in range(34):
        a = random.uniform(0.0, math.tau)
        d = random.uniform(5.0, 22.0)
        x, z = -6.0 + math.cos(a) * d, -2.0 + math.sin(a) * d
        if in_river(x, 1.0) or abs(x) > FIELD_HALF - 1.5:
            continue
        eb = node("E%d" % i, "Node3D", en, None,
                  T((x, 0.0, z), ry=random.uniform(0.0, 360.0)))
        mesh("Body", eb, box, MAT["enemy"], (0.0, 0.55, 0.0),
             scale=(0.55, 1.1, 0.45))
        mesh("Head", eb, box, MAT["enemy"], (0.0, 1.25, 0.0),
             scale=(0.42, 0.4, 0.42))
        mesh("Arm", eb, box, MAT["enemydark"], (0.0, 0.75, -0.45),
             scale=(0.16, 0.16, 1.0))
        n_en += 1
    print("units: 1 player + %d enemies" % n_en)
