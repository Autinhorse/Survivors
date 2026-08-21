# -*- coding: utf-8 -*-
"""
Milestone 1 greybox generator.

Emits scenes/VisualBenchmark.tscn: a primitive-only blockout whose composition
follows docs/target.png (Gatling Gears).  Everything is a Godot primitive
(Box/Sphere/Cylinder/Capsule/Prism/Plane, plus CSG for the river gorge).

Scene size note (2026-08-20): comparing on-screen size ratios of the mech, the
houses and the infantry against docs/target.png showed the reference frame
covers roughly 60 x 46 m of ground, NOT the 30 x 30 m assumed in
docs/GODOT_3D_可行性验证需求.md section 8.  Object dimensions were already
right -- what was wrong was the camera distance and how tightly the layout was
packed.  So: object sizes unchanged, layout spread out ~1.5x, camera raised.

Regenerate with:  python tools/gen_greybox.py [--pitch 60] [--height 44] [--fov 40]
NOTE: this OVERWRITES scenes/VisualBenchmark.tscn.  Once the scene is being
tweaked by hand in the Godot editor, stop using this script -- it is M1
scaffolding only.
"""
import math
import os
import random
import sys

random.seed(20260820)

SCENES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scenes")
OUT = os.path.join(SCENES, "VisualBenchmark.tscn")

# ---------------------------------------------------------------- resources --
subres = []
_sub_ids = set()


def sub(rtype, rid, props=None, **kw):
    if rid not in _sub_ids:
        _sub_ids.add(rid)
        merged = dict(props or {})
        merged.update(kw)
        lines = ["%s = %s" % (k.replace("__", "/"), v) for k, v in merged.items()]
        subres.append((rtype, rid, lines))
    return 'SubResource("%s")' % rid


extres = []
_ext_ids = {}


def ext(rtype, path):
    """Reference an on-disk resource (shader, script) from the scene."""
    if path not in _ext_ids:
        rid = "ext_%d_%s" % (len(extres) + 1,
                             path.rsplit("/", 1)[-1].split(".")[0])
        _ext_ids[path] = rid
        extres.append((rtype, path, rid))
    return 'ExtResource("%s")' % _ext_ids[path]


def noise_tex(tid, freq, lo=0.60, hi=1.0, octaves=4, size=256, **noise_props):
    """Seamless noise texture, ramped so it multiplies albedo gently."""
    n = sub("FastNoiseLite", tid + "N",
            dict(frequency="%g" % freq, fractal_octaves=str(octaves),
                 **noise_props))
    g = sub("Gradient", tid + "G",
            offsets="PackedFloat32Array(0, 1)",
            colors="PackedColorArray(%g, %g, %g, 1, %g, %g, %g, 1)"
                   % (lo, lo, lo, hi, hi, hi))
    return sub("NoiseTexture2D", tid, noise=n, color_ramp=g, seamless="true",
               width=str(size), height=str(size))


def noise_normal(tid, freq, octaves=4, size=256, strength=12.0, **noise_props):
    """同一份噪声的法线图。

    实测目标图的屋顶/墙面细节比我们高约 30%，而且差的主要不是 albedo 的花纹，
    是**受光**：平坦的法线让每个面成为一块均匀的色板。
    NoiseTexture2D 自带 as_normal_map，不需要额外美术资源、也不需要 UV
    （材质走世界空间三平面投影）。

    **strength（NoiseTexture2D 的 bump_strength）默认是 8，别往下调。**
    这里第一版填了 1.4-2.4，结果整条法线贴图路径看着像"完全没生效" ——
    把 normal_scale 从 0.8 拉到 8.0（10 倍）画面纹丝不动。
    根因是这个尺度的分形噪声梯度本来就很平缓，bump_strength 再压低，
    算出来的法线几乎等于 (0,0,1)。用一张普通灰度噪声当法线图做对照实验，
    画面立刻有 4.4% 的像素变化 —— 才定位到不是渲染路径的问题。"""
    n = sub("FastNoiseLite", tid + "N",
            dict(frequency="%g" % freq, fractal_octaves=str(octaves),
                 **noise_props))
    return sub("NoiseTexture2D", tid, noise=n, seamless="true",
               as_normal_map="true", bump_strength="%g" % strength,
               width=str(size), height=str(size))


def shader_mat(name, shader_path, **params):
    props = {"shader": ext("Shader", shader_path)}
    for k, v in params.items():
        props["shader_parameter/" + k] = v
    return sub("ShaderMaterial", name, props)


def col(r, g, b, a=1.0):
    return "Color(%g, %g, %g, %g)" % (r, g, b, a)


def mat(name, rgb, rough=1.0, metal=0.0, alpha=None, tex=None, tex_scale=0.30,
        nrm=None, nrm_scale=1.0):
    """Flat or noise-textured StandardMaterial3D.

    Textures are projected triplanar in WORLD space so the surface reads at a
    consistent density across primitives that are non-uniformly scaled --
    every rock here is a squashed unit sphere."""
    rgba = rgb + ((alpha,) if alpha is not None else ())
    p = {"albedo_color": col(*rgba), "roughness": rough, "metallic": metal}
    if tex is not None:
        p["albedo_texture"] = tex
        p["uv1_triplanar"] = "true"
        p["uv1_world_triplanar"] = "true"
        p["uv1_scale"] = "Vector3(%g, %g, %g)" % (tex_scale, tex_scale, tex_scale)
    if nrm is not None:
        p["normal_enabled"] = "true"
        p["normal_texture"] = nrm
        p["normal_scale"] = "%g" % nrm_scale
    if alpha is not None:
        p["transparency"] = 1
    return sub("StandardMaterial3D", name, p)


MAT = {}


def materials():
    # --- shared noise ---------------------------------------------------------
    macro = noise_tex("NoiseMacro", 0.010, lo=0.0, hi=1.0, octaves=4, size=512)
    detail = noise_tex("NoiseDetail", 0.035, lo=0.0, hi=1.0, octaves=3, size=256)
    # 叶片图集（tools/gen_leaf_atlas.py 生成）：RGB 是叶片自身的明暗，
    # alpha 是叶片形状。颜色来自顶点色，所以一张灰度图集能长出所有色系变体。
    leaf_atlas = ext("Texture2D", "res://assets/environment/leaf_atlas.png")
    rock_n = noise_tex("NoiseRock", 0.055, lo=0.62, hi=1.05, octaves=4)
    rock_nn = noise_normal("NrmRock", 0.055, octaves=4, strength=16.0)
    wood_nn = noise_normal("NrmWood", 0.090, octaves=2, strength=12.0)
    plaster_nn = noise_normal("NrmPlaster", 0.030, octaves=3, strength=14.0)
    wood_n = noise_tex("NoiseWood", 0.090, lo=0.70, hi=1.08, octaves=2)
    plaster_n = noise_tex("NoisePlaster", 0.030, lo=0.80, hi=1.06, octaves=3)
    water_n = noise_tex("NoiseWater", 0.011, lo=0.12, hi=0.88, octaves=3)
    fleck_n = noise_tex("NoiseFleck", 0.085, lo=0.0, hi=1.0, octaves=2, size=256)
    # Ridged fractal: the thin bright veins read as grass strands, which
    # smooth value noise never does.
    grass_n = noise_tex("NoiseGrass", 0.020, lo=0.0, hi=1.0, octaves=3,
                        size=512, fractal_type="2", fractal_gain="0.55",
                        fractal_lacunarity="2.4")

    # --- terrain --------------------------------------------------------------
    # One material covers ground, banks and cliff faces: the shader picks rock
    # vs grass from the surface slope, so the CSG cut faces need no second pass.
    MAT["grass"] = shader_mat("MatTerrain", "res://shaders/ground.gdshader",
                              macro_noise=macro, detail_noise=detail,
                              grass_detail=grass_n,
                              grass_scale="0.85", grass_contrast="0.70",
                              bump_strength="1.5", bump_epsilon="0.055",
                              grass_dark=col(0.145, 0.141, 0.063),
                              grass_light=col(0.373, 0.333, 0.145),
                              dirt_color=col(0.361, 0.259, 0.145),
                              rock_color=col(0.235, 0.212, 0.184),
                              macro_scale="0.022", detail_scale="0.30",
                              dirt_threshold="0.74",
                              rock_scale="0.14", rock_stretch="4.5",
                              rock_contrast="0.30", rock_bump="0.38",
                              slope_grass="0.82", slope_rock="0.48")
    MAT["cliff"] = MAT["grass"]

    MAT["dirt"] = shader_mat("MatPatch", "res://shaders/ground_patch.gdshader",
                             detail_noise=detail,
                             dirt_dark=col(0.208, 0.153, 0.094),
                             dirt_light=col(0.365, 0.271, 0.161),
                             noise_scale="0.42", edge_softness="0.42",
                             edge_break="0.60", coverage="0.70")

    MAT["water"] = shader_mat("MatWater", "res://shaders/water.gdshader",
                              wave_noise=water_n, fleck_noise=fleck_n,
                              water_bright=col(0.365, 0.376, 0.392),
                              water_dark=col(0.169, 0.212, 0.239),
                              foam_color=col(0.804, 0.816, 0.827),
                              flow_speed="0.35", fleck_scale="2.2",
                              swell_scale="0.35", streak_stretch="2.5",
                              foam_threshold="0.78", foam_softness="0.075",
                              bank_width="0.42", bank_strength="1.0",
                              bank_break="0.55", bank_churn="1.6",
                              normal_strength="0.45",
                              base_alpha="0.95")

    # --- foliage: wind sway + noise break-up ---------------------------------
    MAT["leafA"] = shader_mat("MatLeafA", "res://shaders/foliage.gdshader",
                              detail_noise=detail,
                              leaf_dark=col(0.114, 0.176, 0.055),
                              leaf_light=col(0.349, 0.427, 0.161),
                              noise_scale="0.55", wind_strength="0.10",
                              wind_speed="1.1", ao_strength="0.45",
                              sway_height="4.4", use_vertex_colour="1.0",
                              leaf_atlas=leaf_atlas, use_atlas="1.0",
                              alpha_cut="0.34", normal_flatten="0.62")
    MAT["leafB"] = shader_mat("MatLeafB", "res://shaders/foliage.gdshader",
                              detail_noise=detail,
                              leaf_dark=col(0.110, 0.165, 0.055),
                              leaf_light=col(0.353, 0.400, 0.145),
                              noise_scale="0.70", wind_strength="0.13",
                              wind_speed="1.35", ao_strength="0.40",
                              sway_height="4.4")
    MAT["bush"] = shader_mat("MatBush", "res://shaders/foliage.gdshader",
                             detail_noise=detail,
                             leaf_dark=col(0.106, 0.145, 0.051),
                             leaf_light=col(0.318, 0.353, 0.125),
                             noise_scale="0.95", wind_strength="0.07",
                             wind_speed="1.6", ao_strength="0.35",
                             sway_height="0.7", use_vertex_colour="1.0",
                             leaf_atlas=leaf_atlas, use_atlas="1.0",
                             alpha_cut="0.34", normal_flatten="0.55")
    MAT["tuft"] = shader_mat("MatTuft", "res://shaders/grass_tuft.gdshader",
                             base_color=col(0.216, 0.259, 0.094),
                             tip_color=col(0.392, 0.427, 0.169),
                             dry_color=col(0.451, 0.396, 0.180),
                             wind_strength="0.16", wind_speed="1.6",
                             fade_start="55.0", fade_end="78.0")

    # --- solid props ----------------------------------------------------------
    MAT["rock"] = mat("MatRock", (0.255, 0.235, 0.231), rough=0.88,
                      tex=rock_n, tex_scale=0.55, nrm=rock_nn, nrm_scale=0.7)
    MAT["wood"] = mat("MatWood", (0.286, 0.192, 0.110), rough=0.92,
                      tex=wood_n, tex_scale=0.85, nrm=wood_nn, nrm_scale=0.8)
    MAT["woodlt"] = mat("MatWoodLt", (0.443, 0.318, 0.180), rough=0.90,
                        tex=wood_n, tex_scale=0.85, nrm=wood_nn, nrm_scale=0.8)
    MAT["wall"] = mat("MatWall", (0.616, 0.573, 0.478), rough=0.94,
                      tex=plaster_n, tex_scale=0.40, nrm=plaster_nn,
                      nrm_scale=1.0)
    MAT["roof"] = mat("MatRoof", (0.318, 0.310, 0.176), rough=0.96,
                      tex=wood_n, tex_scale=1.30, nrm=wood_nn, nrm_scale=1.2)
    MAT["metal"] = mat("MatMetal", (0.298, 0.310, 0.337), rough=0.42, metal=0.65,
                       tex=rock_n, tex_scale=1.20)
    # 硬表面道具（房屋）：颜色来自顶点色，细节和法线扰动在着色器里算。
    # 不走 StandardMaterial3D 的法线贴图 —— 程序化网格没有 UV，
    # Godot 没 UV 就生成不了切线，那条路会静默失效。
    MAT["prop"] = shader_mat("MatProp", "res://shaders/prop.gdshader",
                             detail_noise=detail,
                             scale_stone="0.55", scale_wood="0.75",
                             contrast_stone="0.38", contrast_wood="0.22",
                             bump_stone="1.40", bump_wood="0.90",
                             epsilon="0.06",
                             surface_roughness="0.94")

    MAT["player"] = mat("MatPlayer", (0.706, 0.290, 0.098), rough=0.48, metal=0.35)
    MAT["enemy"] = mat("MatEnemy", (0.502, 0.161, 0.129), rough=0.58, metal=0.25)


# --------------------------------------------------------------- transforms --
def _emit(ax, ay, az, pos):
    """ax/ay/az are the basis COLUMNS (the transformed X/Y/Z axes).

    The .tscn text format serialises Transform3D by ROWS, i.e. the transpose of
    the column list -- verified against ResourceSaver output on Godot 4.7.
    """
    v = (ax[0], ay[0], az[0],
         ax[1], ay[1], az[1],
         ax[2], ay[2], az[2],
         pos[0], pos[1], pos[2])
    return "Transform3D(" + ", ".join("%.5f" % f for f in v) + ")"


def T(pos=(0.0, 0.0, 0.0), ry=0.0, scale=(1.0, 1.0, 1.0), rx=0.0):
    """Basis = Ry(ry) * Rx(rx) * Scale."""
    cy, sy = math.cos(math.radians(ry)), math.sin(math.radians(ry))
    cx, sx = math.cos(math.radians(rx)), math.sin(math.radians(rx))
    s = scale
    ax = tuple(c * s[0] for c in (cy, 0.0, -sy))
    ay = tuple(c * s[1] for c in (sy * sx, cx, cy * sx))
    az = tuple(c * s[2] for c in (sy * cx, -sx, cy * cx))
    return _emit(ax, ay, az, pos)


def T_segment(p0, p1, thickness):
    """Unit box stretched along the XY-plane segment p0 -> p1 (cables, braces)."""
    (x0, y0, z0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    ln = math.hypot(dx, dy)
    ux, uy = dx / ln, dy / ln
    return _emit((ux * ln, uy * ln, 0.0),
                 (-uy * thickness, ux * thickness, 0.0),
                 (0.0, 0.0, thickness),
                 ((x0 + x1) / 2.0, (y0 + y1) / 2.0, z0))


# -------------------------------------------------------------------- nodes --
nodes = []


def node(name, ntype, parent, props=None, transform=None):
    head = '[node name="%s" type="%s" parent="%s"]' % (name, ntype, parent)
    body = []
    if transform:
        body.append("transform = " + transform)
    for k, v in (props or {}).items():
        body.append("%s = %s" % (k.replace("__", "/"), v))
    nodes.append(head + "\n" + "\n".join(body))
    return (parent + "/" + name) if parent != "." else name


def instance(name, parent, packed, transform=None, child=None, override=None):
    """实例化一个外部场景（GLB 导入后就是 PackedScene）。

    child/override：给实例内部的某个子节点挂 material_override。
    .tscn 里覆盖实例的子节点属性要单独起一个 [node] 段，
    名字必须和 GLB 里的节点名一致。"""
    head = '[node name="%s" parent="%s" instance=%s]' % (name, parent, packed)
    if transform:
        head = head + chr(10) + "transform = " + transform
    nodes.append(head)
    path = (parent + "/" + name) if parent != "." else name
    if child and override:
        nodes.append('[node name="%s" parent="%s" index="0"]%smaterial_override = %s'
                     % (child, path, chr(10), override))
    return path


def mesh(name, parent, meshres, material, pos=(0.0, 0.0, 0.0), ry=0.0,
         scale=(1.0, 1.0, 1.0), rx=0.0, cast_shadow=None, xform=None):
    p = {"mesh": meshres, "surface_material_override/0": material}
    if cast_shadow is not None:
        p["cast_shadow"] = cast_shadow
    return node(name, "MeshInstance3D", parent, p, xform or T(pos, ry, scale, rx))


# ------------------------------------------------------------------- layout --
GROUND = 160.0                   # CSG ground block; sized only so the fixed
                                 # camera never sees the edge of the world

# River: centerline x = RX0 + RSLOPE * z, running from upper-middle to
# lower-right as in docs/target.png.
RX0, RSLOPE = 10.0, 0.28
RANG = math.degrees(math.atan(RSLOPE))
RIVER_W = 7.5                    # 基准宽度
# 河道不是直线：参考图的河是蜿蜒的、宽窄变化的。等宽直带子读起来像运河。
RIVER_AMP = 2.6                  # 蜿蜒振幅（米）
RIVER_FREQ = 0.085               # 蜿蜒频率（弧度/米）
RIVER_W_AMP = 0.28               # 宽度起伏比例


def spawn_radius(margin=1.1, aspect=16.0 / 9.0):
    """保证"屏幕外生成"的最小世界半径。

    因为项目已锁定可见范围（project.godot 的 stretch mode=viewport / aspect=keep，
    左右加黑边），这个半径是**一个固定的世界常量**，与玩家的分辨率无关 ——
    这正是加黑边的实际收益：刷怪逻辑不用再关心屏幕。

    注意透视：远边比近边宽得多（本项目 ±41.6 m vs ±27.2 m），
    所以决定半径的是**远端的两个角**，不是画面宽度的一半。
    """
    vh = math.radians(CAM_FOV / 2.0)
    hh = math.atan(math.tan(vh) * aspect)
    p = math.radians(CAM_PITCH)
    best = 0.0
    for sy in (-1.0, 1.0):
        for sx in (-1.0, 1.0):
            dx, dy, dz = sx * math.tan(hh), sy * math.tan(vh), -1.0
            wy = dy * math.cos(-p) - dz * math.sin(-p)
            wz = dy * math.sin(-p) + dz * math.cos(-p)
            t = -CAM_HEIGHT / wy
            best = max(best, math.hypot(dx * t, camera_z() + wz * t))
    return best * margin


def river_x(z):
    return RX0 + RSLOPE * z + RIVER_AMP * math.sin(z * RIVER_FREQ)


def river_w(z):
    """宽窄变化：窄处水更急，正好放急流白水。"""
    return RIVER_W * (1.0 + RIVER_W_AMP * math.sin(z * RIVER_FREQ * 1.7 + 1.1))


def river_ang(z):
    """局部切线方向（度）。河道弯了之后，挖槽的盒子必须逐段跟着转，
    否则外侧会豁口。"""
    dxdz = RSLOPE + RIVER_AMP * RIVER_FREQ * math.cos(z * RIVER_FREQ)
    return math.degrees(math.atan(dxdz))


# 岸线抖动。**两岸各自独立**，这是关键 ——
# 之前两岸共用一个正弦，于是永远同步变宽变窄，河道读起来还是"一条等宽的带子
# 被正弦调制过"，规则感一点没少。给两岸错开相位之后，一侧凸出时另一侧可能也凸，
# 河道才会出现真正的宽窄段和不对称的弯。
#
# 单一正弦是另一个问题：它只有一个尺度。真实岸线在每个尺度上都是碎的，
# 所以叠三个倍频。改这里必须同步改 scripts/environment/RiverSurface.gd 里
# 同名的函数 —— 水面网格的 UV 要让 0/1 精确落在**实际**岸线上，
# 否则岸边浪花会漂在河中间或者埋进地形（这个坑踩过两次）。
BANK_JIT = 0.24                  # 半宽抖动比例


def bank_noise(z, side):
    ph = 0.0 if side < 0 else 11.7
    return (0.55 * math.sin(z * 0.130 + 0.70 + ph)
            + 0.30 * math.sin(z * 0.370 + 2.10 + ph * 1.3)
            + 0.15 * math.sin(z * 0.910 + 4.30 + ph * 0.7))


def river_hw(z, side):
    """某一岸的垂直半宽（米）。side: -1 左岸 / +1 右岸。"""
    return river_w(z) * 0.5 * (1.0 + BANK_JIT * bank_noise(z, side))


def river_perp(z):
    """河道法向在 XZ 平面里的单位向量（指向右岸）。"""
    a = math.radians(river_ang(z))
    return (math.cos(a), -math.sin(a))


def bank_point(z, side):
    """实际岸线上的一点。石头、植被都按它摆，才会贴着真正的水边。"""
    px, pz = river_x(z), z
    ex, ez = river_perp(z)
    hw = river_hw(z, side)
    return (px + side * hw * ex, pz + side * hw * ez)
FAR_BANK_Y = 2.0                 # top of the far-bank plateau
WATER_Y = -2.55
BED_Y = -3.4

# Bridge
BRIDGE_Z = -8.0
DECK_L = 13.0                     # gorge is 7.5 m; ~2.7 m of overhang each side
DECK_W = 4.2
DECK_Y = 2.1                     # meets the far-bank plateau top

# Village loop road
LOOP_C, LOOP_A, LOOP_B = (-7.0, -2.0), 9.3, 6.9

# ------------------------------------------------------------------- camera --
# Fixed high-angle gameplay camera (doc section 9).  CAM_Z is derived so the
# camera always aims at CAM_FOCUS_Z on the ground plane -- changing the pitch
# re-frames around the same point instead of sliding the composition.
# Height 44 m reproduces the reference frame's ~60 m visible ground width.
CAM_PITCH = 60.0        # degrees below horizontal (confirmed 2026-08-20)
CAM_HEIGHT = 44.0       # metres
CAM_FOV = 40.0
CAM_FOCUS_Z = 0.5


FORWARD_PLUS = False     # emit the Forward+-only environment keys (--forward-plus)
# Doc section 25: the visual scene stays stable as the reference; the crowd
# benchmark lives in its own copy so stress testing never disturbs it.
PERFORMANCE = False      # emit scenes/PerformanceBenchmark.tscn (--performance)


def _cli_overrides():
    global CAM_PITCH, CAM_HEIGHT, CAM_FOV, FORWARD_PLUS, PERFORMANCE, OUT
    a = sys.argv[1:]
    if "--forward-plus" in a:
        FORWARD_PLUS = True
    if "--performance" in a:
        PERFORMANCE = True
        OUT = os.path.join(SCENES, "PerformanceBenchmark.tscn")
    for i, tok in enumerate(a):
        if tok == "--pitch":
            CAM_PITCH = float(a[i + 1])
        elif tok == "--height":
            CAM_HEIGHT = float(a[i + 1])
        elif tok == "--fov":
            CAM_FOV = float(a[i + 1])


def camera_z():
    return CAM_FOCUS_Z + CAM_HEIGHT / math.tan(math.radians(CAM_PITCH))


def frame_size(aspect=16.0 / 9.0):
    """Ground-plane extents the camera can see, for sanity-checking the setup."""
    half = CAM_FOV / 2.0
    far = CAM_HEIGHT / math.tan(math.radians(max(CAM_PITCH - half, 1.0)))
    near = CAM_HEIGHT / math.tan(math.radians(min(CAM_PITCH + half, 89.0)))
    d = CAM_HEIGHT / math.sin(math.radians(CAM_PITCH))
    width = 2.0 * d * math.tan(math.atan(math.tan(math.radians(half)) * aspect))
    return camera_z() - far, camera_z() - near, width


def build():
    materials()
    box = sub("BoxMesh", "MeshBox", size="Vector3(1, 1, 1)")
    cyl = sub("CylinderMesh", "MeshCyl", top_radius="0.5", bottom_radius="0.5",
              height="1.0", radial_segments="12")
    cap = sub("CapsuleMesh", "MeshCap", radius="0.5", height="2.0",
              radial_segments="10", rings="4")
    prism = sub("PrismMesh", "MeshPrism", size="Vector3(1, 1, 1)")
    plane = sub("PlaneMesh", "MeshPlane", size="Vector2(1, 1)")

    nodes.append('[node name="VisualBenchmark" type="Node3D"]')

    # ------------------------------------------------------------ environment
    sky_mat = sub("ProceduralSkyMaterial", "SkyMat",
                  sky_top_color=col(0.361, 0.435, 0.588),
                  sky_horizon_color=col(0.882, 0.663, 0.435),
                  sky_curve="0.09",
                  ground_bottom_color=col(0.180, 0.145, 0.125),
                  ground_horizon_color=col(0.741, 0.573, 0.404),
                  sun_angle_max="26.0", sun_curve="0.10",
                  energy_multiplier="1.15")
    sky = sub("Sky", "Sky", sky_material=sky_mat)
    env = sub("Environment", "Env",
              background_mode="2", sky=sky,
              ambient_light_source="3", ambient_light_sky_contribution="1.0",
              ambient_light_energy="1.35",
              tonemap_mode="3", tonemap_exposure="1.34", tonemap_white="9.0",
              glow_enabled="true", glow_intensity="0.7", glow_strength="1.1",
              glow_bloom="0.12", glow_hdr_threshold="0.95",
              glow_blend_mode="1",
              # Mobile renderer has no SSAO/SSIL/SDFGI; depth fog is the only
              # atmospheric depth cue available here (doc section 10).
              fog_enabled="true", fog_mode="0",
              fog_light_color=col(0.788, 0.635, 0.463),
              fog_light_energy="0.8", fog_sun_scatter="0.15",
              fog_density="0.0011", fog_sky_affect="0.0",
              fog_height="-6.0", fog_height_density="0.02",
              adjustment_enabled="true", adjustment_saturation="0.94",
              adjustment_contrast="1.02", adjustment_brightness="1.0")
    if FORWARD_PLUS:
        # High preset.  These keys are Forward+ only -- under Mobile the engine
        # prints a warning and ignores them, so they are emitted on demand
        # rather than always (doc section 24: Low / Medium / High presets).
        subres[-1][2].extend([
            'ssao_enabled = true', 'ssao_radius = 1.4', 'ssao_intensity = 2.2',
            'ssao_power = 1.6', 'ssao_light_affect = 0.15',
            'volumetric_fog_enabled = true', 'volumetric_fog_density = 0.004',
            'volumetric_fog_albedo = ' + col(0.82, 0.74, 0.60),
            'volumetric_fog_emission = ' + col(0.10, 0.075, 0.045),
            'volumetric_fog_emission_energy = 0.35',
            'volumetric_fog_anisotropy = 0.35',
            'volumetric_fog_length = 140.0',
            'volumetric_fog_ambient_inject = 0.15',
        ])
    node("WorldEnvironment", "WorldEnvironment", ".", {"environment": env})

    # Key light from the far upper-left; shadows fall to the lower-right, as in
    # docs/target.png.
    node("Sun", "DirectionalLight3D", ".",
         {"light_color": col(1.0, 0.804, 0.588), "light_energy": "3.4",
          "light_angular_distance": "1.4", "shadow_enabled": "true",
          "shadow_opacity": "0.50",
          "shadow_bias": "0.035", "shadow_normal_bias": "1.2",
          "shadow_blur": "1.2",
          "directional_shadow_max_distance": "130.0",
          "directional_shadow_split_1": "0.07",
          "directional_shadow_split_2": "0.22",
          "directional_shadow_blend_splits": "true"},
         T((0.0, 20.0, 0.0), ry=-136.0, rx=-38.0))

    node("GameplayCamera", "Camera3D", ".",
         {"script": ext("Script",
                        "res://scripts/environment/GameplayCameraPolicy.gd"),
          "fov": "%.1f" % CAM_FOV, "near": "0.5", "far": "300.0",
          "current": "true",
          # 默认 KEEP_HEIGHT 会让 32:9 玩家看到两倍宽的战场（131.5m vs 65.7m），
          # 那是玩法优势而不只是画面问题
          "aspect_policy": '"clamp"',
          "design_fov_vertical": "%.1f" % CAM_FOV},
         T((0.0, CAM_HEIGHT, camera_z()), rx=-CAM_PITCH))

    # ---------------------------------------------------------------- terrain
    ter = node("Terrain", "CSGCombiner3D", ".", {"use_collision": "false"})
    node("GroundBlock", "CSGBox3D", ter,
         {"size": "Vector3(%g, 6, %g)" % (GROUND, GROUND),
          "material": MAT["grass"]},
         T((0.0, -3.0, 0.0)))
    # Raised far bank -> a real cliff face on the river's far side.
    perp = (math.cos(math.radians(RANG)), -math.sin(math.radians(RANG)))
    off = RIVER_W / 2.0 + 0.5 + 25.0                       # 50 m wide plateau
    pc = (river_x(0.0) + off * perp[0], FAR_BANK_Y - 3.0, off * perp[1])
    node("FarBankPlateau", "CSGBox3D", ter,
         {"size": "Vector3(50, 6, 190)", "material": MAT["grass"],
          "operation": "0"},
         T(pc, ry=RANG))
    # 用一串重叠的圆柱挖河道，而不是盒子。
    # 盒子无论怎么逐段旋转，在弯道外侧都会露出方角和直边 ——
    # 人眼对"一段一段的直线 + 方形突起"极其敏感。圆柱的 footprint 是圆的，
    # 重叠起来自然形成圆润不规则的岸线。
    # 半径的抖动必须是**低频**的。高频抖动会让相邻圆柱互相探出，
    # 形成扇贝状锯齿 —— 那正是"一段一段"的来源。
    # 边数也要够（14 边的多边形轮廓在这个机位下能看出直边）。
    step = 0.9
    zi = -48.0
    i = 0
    while zi <= 48.0:
        # 圆柱是对称的，但两岸要独立抖动 —— 于是把半径取两岸的平均，
        # 再把圆心沿法向偏移两岸之差的一半。这样切出来的左右边界
        # 精确等于 river_hw(z, -1) 和 river_hw(z, +1)。
        hwl, hwr = river_hw(zi, -1.0), river_hw(zi, 1.0)
        ex, ez = river_perp(zi)
        coff = (hwr - hwl) * 0.5
        node("RiverCut%d" % i, "CSGCylinder3D", ter,
             {"radius": "%g" % ((hwl + hwr) * 0.5),
              "height": "9.0", "sides": "32", "smooth_faces": "true",
              "operation": "2", "material": MAT["cliff"]},
             T((river_x(zi) + coff * ex, BED_Y + 4.5, zi + coff * ez)))
        zi += step
        i += 1

    # ------------------------------------------------------------------ water
    # 一条沿河道生成的带状网格，UV 顺流。
    # 之前是一片片独立 plane，着色器只能按世界坐标滚动噪声 ——
    # 河道拐弯处水流会横穿河岸（静帧看不出来，跑起来一眼就错）。
    node("River", "MeshInstance3D", ".", {
        "script": ext("Script", "res://scripts/environment/RiverSurface.gd"),
        "material_override": MAT["water"],
        "river_x0": "%g" % RX0,
        "river_slope": "%g" % RSLOPE,
        "river_amp": "%g" % RIVER_AMP,
        "river_freq": "%g" % RIVER_FREQ,
        "river_w": "%g" % RIVER_W,
        "river_w_amp": "%g" % RIVER_W_AMP,
        "river_w_freq_mul": "1.7",
        "river_w_phase": "1.1",
        "water_y": "%g" % WATER_Y,
        "z_start": "-50.0", "z_end": "50.0", "step": "1.5",
        "overhang": "3.2", "v_scale": "6.0", "u_metre_scale": "4.0",
        "bank_jitter": "%g" % BANK_JIT,
    })

    # ------------------------------------------------------------ dirt tracks
    paths = node("Paths", "Node3D", ".")
    n = 0
    for a in range(0, 360, 9):
        r = math.radians(a)
        px = LOOP_C[0] + LOOP_A * math.cos(r)
        pz = LOOP_C[1] + LOOP_B * math.sin(r)
        mesh("Path%d" % n, paths, box, MAT["dirt"], (px, 0.04, pz),
             ry=-a + 90, scale=(3.0, 0.08, 2.4), cast_shadow="0")
        n += 1
    for t in range(7):                                     # spur to the bridge
        f = t / 6.0
        mesh("Path%d" % n, paths, box, MAT["dirt"],
             (-3.4 + f * 4.4, 0.04, -4.4 - f * 3.2), ry=32,
             scale=(2.6, 0.08, 2.2), cast_shadow="0")
        n += 1
    for i, (px, pz, w, d, ry) in enumerate([               # worn yards
            (-10.4, -12.6, 7.0, 4.6, -8.0), (-2.4, -8.4, 4.6, 3.4, 16.0),
            (3.9, -14.2, 4.4, 3.2, 6.0), (3.4, -7.4, 6.0, 3.0, -26.0)]):
        mesh("Yard%d" % i, paths, box, MAT["dirt"], (px, 0.03, pz), ry=ry,
             scale=(w, 0.06, d), cast_shadow="0")

    # ----------------------------------------------------------------- bridge
    bz, bcx = BRIDGE_Z, river_x(BRIDGE_Z)
    br = node("Bridge", "Node3D", ".")
    x0 = bcx - DECK_L / 2.0                                # near end of deck
    mesh("Deck", br, box, MAT["wood"], (x0 + DECK_L / 2.0, DECK_Y, bz),
         ry=RANG, scale=(DECK_L, 0.30, DECK_W))
    nplank = int(DECK_L / 1.55)
    for i in range(nplank):
        mesh("Plank%d" % i, br, box, MAT["woodlt"],
             (x0 + (i + 0.5) * DECK_L / nplank, DECK_Y + 0.18, bz), ry=RANG,
             scale=(0.38, 0.10, DECK_W + 0.2))
    for i, offz in enumerate((-DECK_W / 2.0 + 0.5, DECK_W / 2.0 - 0.5)):
        for j, dx in enumerate((-RIVER_W / 2.0 + 0.9, RIVER_W / 2.0 - 0.9)):
            mesh("Pylon%d%d" % (i, j), br, cyl, MAT["wood"],
                 (bcx + dx, (DECK_Y + BED_Y) / 2.0, bz + offz),
                 scale=(0.6, DECK_Y - BED_Y, 0.6))
    npost = int(DECK_L / 1.9)
    for i in range(npost):
        for k, s in enumerate((-DECK_W / 2.0 + 0.2, DECK_W / 2.0 - 0.2)):
            mesh("Post%d_%d" % (i, k), br, box, MAT["wood"],
                 (x0 + (i + 0.5) * DECK_L / npost, DECK_Y + 0.75, bz + s),
                 ry=RANG, scale=(0.16, 1.2, 0.16))
    for k, s in enumerate((-DECK_W / 2.0 + 0.2, DECK_W / 2.0 - 0.2)):
        mesh("Rail%d" % k, br, box, MAT["wood"],
             (x0 + DECK_L / 2.0, DECK_Y + 1.3, bz + s), ry=RANG,
             scale=(DECK_L - 0.4, 0.16, 0.16))
    # Near-side abutment: stepped ramp from ground level up to the deck.
    for i, (dx, f) in enumerate(((-1.2, 0.75), (-3.0, 0.42), (-4.8, 0.16))):
        mesh("Abut%d" % i, br, box, MAT["woodlt"],
             (x0 + dx, f * DECK_Y / 2.0, bz), ry=RANG,
             scale=(2.0, f * DECK_Y, DECK_W))
    # A-frame mast + stay cables (silhouette from target.png)
    mast_x, mast_top = x0 + 0.3, DECK_Y + 5.6
    for k, s in enumerate((-DECK_W / 2.0 + 0.6, DECK_W / 2.0 - 0.6)):
        mesh("Mast%d" % k, br, box, MAT["wood"],
             (mast_x, (mast_top + DECK_Y) / 2.0 - 0.4, bz + s), ry=RANG,
             scale=(0.5, mast_top - DECK_Y + 1.6, 0.5))
    mesh("MastTop", br, box, MAT["wood"], (mast_x, mast_top, bz), ry=RANG,
         scale=(0.44, 0.44, DECK_W))
    for i, dx in enumerate((3.2, 6.4, 9.6, 12.8)):
        mesh("Cable%d" % i, br, box, MAT["metal"], cast_shadow="0",
             xform=T_segment((mast_x, mast_top, bz), (mast_x + dx, DECK_Y), 0.07))
    mesh("CableBack", br, box, MAT["metal"], cast_shadow="0",
         xform=T_segment((mast_x, mast_top, bz), (mast_x - 6.5, 0.0), 0.07))

    # -------------------------------------------------------------- buildings
    bl = node("Buildings", "Node3D", ".")

    def building(nm, pos, w, d, h, ry, chim):
        mesh(nm + "Walls", bl, box, MAT["wall"], (pos[0], h / 2.0, pos[1]),
             ry=ry, scale=(w, h, d))
        mesh(nm + "Roof", bl, prism, MAT["roof"], (pos[0], h + 1.1, pos[1]),
             ry=ry, scale=(w + 0.8, 2.2, d + 0.8))
        mesh(nm + "Chimney", bl, box, MAT["wall"],
             (pos[0] + chim[0], h + 1.6, pos[1] + chim[1]), ry=ry,
             scale=(0.7, 2.4, 0.7))

    # 建筑改用 Blender 程序化生成的资产（tools/gen_assets_blender.py）：
    # 出檐、屋脊、门窗凹陷、转角立柱、门廊 —— 这些是 M2 判定的最大视觉短板，
    # 每样只花几十个面。GLB 里三栋房子摆在 x = -9 / 0 / 9，
    # 用一个偏移把需要的那栋挪到父节点原点，其余两栋跟着挪出画面外。
    for nm, px, pz, ry, src in [
            ("HouseA", -12.9, -13.2, -8.0, "house_large"),
            ("HouseB", -2.7, -11.1, 14.0, "house_small"),
            ("HouseC", -21.5, -6.5, 22.0, "house_tall")]:
        instance(nm, bl, ext("PackedScene", "res://assets/environment/%s.glb" % src),
                 T((px, 0.0, pz), ry=ry), child=src, override=MAT["prop"])

    mesh("ShedFloor", bl, box, MAT["woodlt"], (3.9, 0.6, -14.4), ry=6.0,
         scale=(3.6, 0.2, 3.0))
    for i, (dx, dz) in enumerate(((-1.6, -1.3), (1.6, -1.3),
                                  (-1.6, 1.3), (1.6, 1.3))):
        mesh("ShedPost%d" % i, bl, box, MAT["wood"],
             (3.9 + dx, 1.2, -14.4 + dz), scale=(0.2, 1.4, 0.2))
    mesh("ShedRoof", bl, box, MAT["wood"], (3.9, 2.0, -14.4), ry=6.0,
         scale=(4.0, 0.2, 3.4))

    # ------------------------------------------------------------------ props
    pr = node("Props", "Node3D", ".")
    for i, (px, pz, s, ry) in enumerate([
            (-18.6, -9.0, 1.0, 12.0), (-17.4, -10.2, 0.8, -20.0),
            (-18.3, -10.5, 0.7, 35.0), (-6.9, -15.9, 0.9, 8.0),
            (6.0, -12.6, 0.8, -14.0), (-14.4, -6.9, 0.75, 25.0),
            (-24.0, -3.0, 0.9, -8.0), (5.4, -16.5, 0.7, 18.0),
            (-9.0, -17.4, 0.85, 30.0)]):
        mesh("Crate%d" % i, pr, box, MAT["woodlt"], (px, s * 0.5, pz), ry=ry,
             scale=(s, s, s))
    for i in range(14):                                    # fence line
        mesh("Fence%d" % i, pr, box, MAT["wood"],
             (-20.4 + i * 1.35, 0.6, -3.6 + i * 0.42), ry=-16.0,
             scale=(0.14, 1.2, 0.14))
    for i in range(9):                                     # second fence
        mesh("FenceB%d" % i, pr, box, MAT["wood"],
             (-16.0 + i * 1.3, 0.6, -18.6 - i * 0.2), ry=8.0,
             scale=(0.14, 1.2, 0.14))
    for i, (px, pz) in enumerate(((5.1, -19.5), (-5.4, -18.0), (-16.5, -14.0))):
        mesh("Pole%d" % i, pr, cyl, MAT["wood"], (px, 3.2, pz),
             scale=(0.34, 6.4, 0.34))
        mesh("PoleArm%d" % i, pr, box, MAT["wood"], (px, 5.9, pz), ry=20.0,
             scale=(2.2, 0.16, 0.16))

    # ------------------------------------------------- scatter (rejection map)
    # Shared occupancy list so rocks/trees/bushes never pile into each other or
    # into gameplay space (roads, meadow, bridge approach, player).
    taken = [(-12.9, -13.2, 6.4), (-2.7, -11.1, 5.0), (-21.5, -6.5, 5.2),
             (3.9, -14.4, 3.4), (-1.2, 3.6, 7.5), (bcx, bz, 11.0),
             (5.1, -19.5, 1.6), (-5.4, -18.0, 1.6), (-16.5, -14.0, 1.6)]

    def blocked(px, pz, r):
        if abs(px - river_x(pz)) < RIVER_W / 2.0 + 1.0 + r * 0.3:
            return True                                    # in the gorge
        ex = (px - LOOP_C[0]) / LOOP_A
        ez = (pz - LOOP_C[1]) / LOOP_B
        if math.hypot(ex, ez) < 1.20:                      # road + open meadow
            return True
        for tx, tz, tr_ in taken:
            if math.hypot(px - tx, pz - tz) < tr_ + r:
                return True
        return False

    def claim(px, pz, r):
        taken.append((px, pz, r))

    def bank_y(px, pz):
        return FAR_BANK_Y if px > river_x(pz) + RIVER_W / 2.0 else 0.0

    def cluster(n, cx, cz, spread, sr, r_mul=1.0, tries=30):
        """Gaussian clump: the reference art clumps props, it never scatters
        them uniformly."""
        out = []
        for _ in range(n):
            for _t in range(tries):
                px = cx + random.gauss(0.0, spread)
                pz = cz + random.gauss(0.0, spread)
                s = random.uniform(*sr)
                if not blocked(px, pz, s * r_mul):
                    claim(px, pz, s * r_mul)
                    out.append((px, pz, s))
                    break
        return out

    # rocks: boulder field lower-left, gorge lip, far bank, frame-filling clumps
    spots = []
    for cx, cz, n, sp in [(-17.0, 12.0, 11, 3.6), (-11.0, 19.5, 8, 3.4),
                          (-22.0, 3.0, 6, 3.0), (-20.0, -8.0, 4, 2.6),
                          (-5.0, 22.0, 5, 3.2), (-28.0, 16.0, 5, 3.4)]:
        spots += cluster(n, cx, cz, sp, (0.45, 1.55), r_mul=0.9)
    # 少数几块显眼的大石，作为视觉锚点 —— 参考图也是这个结构
    for cx, cz in ((-15.5, 14.5), (-8.0, 20.5), (-24.0, 6.0)):
        spots += cluster(1, cx, cz, 1.0, (2.1, 2.6), r_mul=1.2)
    # 岸线：参考图的水陆边界**整条被石头砌满** —— 大块的半沉在水里，
    # 草皮直接压到石头上，没有一段裸露的土坡。这是目标图和我们差得最远的地方，
    # 也是最有效的一招：石头一铺，岸线是否规则就不再由挖槽的曲线决定了。
    #
    # 关键是按 bank_point() 摆，也就是**实际**岸线（带两岸独立抖动），
    # 而不是名义半宽 river_w/2 —— 后者在河道倾斜时本身就有 cos 误差，
    # 石头会整体偏进水里。
    zb = -26.0
    while zb <= 26.0:
        for side in (-1.0, 1.0):
            ex, ez = river_perp(zb)
            for _k in range(3):
                off = random.uniform(-1.3, 1.9)      # 负值 = 探进水里
                bx, bz = bank_point(zb, side)
                px = bx + side * off * ex + random.uniform(-0.4, 0.4)
                pz = bz + side * off * ez + random.uniform(-0.7, 0.7)
                sc = random.uniform(0.55, 1.9)
                if off < 0.0 or not blocked(px, pz, sc * 0.55):
                    if off >= 0.0:
                        claim(px, pz, sc * 0.55)
                    spots.append((px, pz, sc if off >= 0.0 else -sc))
        zb += 1.6
    for cz in (-17.0, -2.0, 13.0):                         # far bank
        spots += cluster(4, river_x(cz) + 9.0, cz, 4.0, (0.6, 1.6), r_mul=0.9)
    for cx, cz in ((-40.0, 20.0), (30.0, -34.0), (-42.0, -22.0), (38.0, 22.0),
                   (0.0, 34.0), (-30.0, -34.0)):
        spots += cluster(6, cx, cz, 6.0, (0.7, 1.9), r_mul=0.9)
    rock_pl = []
    for px, pz, s in spots:
        in_water = s < 0.0
        s = abs(s)
        sy = s * random.uniform(0.55, 0.85)
        base = WATER_Y + 0.10 if in_water else bank_y(px, pz) - 0.18 * sy
        rock_pl += [px, base, pz,
                    random.uniform(0.0, 360.0),
                    s, sy, s * random.uniform(0.7, 1.2)]
    node("Rocks", "Node3D", ".", {
        "script": ext("Script", "res://scripts/environment/ScatterField.gd"),
        "kind": '"rock"',
        "source_scene": ext("PackedScene", "res://assets/environment/rocks_lp.glb"),
        "variants": "8",
        "placements": "PackedFloat32Array(%s)" % ", ".join("%.3f" % v for v in rock_pl),
    })

    # 碎石：参考图的地面几乎没有空白，除了大石块还有满地小石子。
    # 单独一层、不投影、成簇跟着大石块和路边走。
    pebble_pl = []
    for cx, cz, n, sp in [(-17.0, 11.0, 22, 5.0), (-10.0, 19.0, 18, 4.5),
                          (-21.0, 2.0, 14, 4.0), (-4.0, 21.0, 12, 4.5),
                          (-27.0, 16.0, 12, 4.5), (-19.5, -8.0, 10, 3.5),
                          (12.0, 6.0, 12, 5.0), (16.0, -12.0, 10, 5.0),
                          (-8.0, -3.0, 9, 6.0), (2.0, 8.0, 9, 6.0)]:
        for px, pz, sc in cluster(n, cx, cz, sp, (0.35, 0.95), r_mul=0.2):
            pebble_pl += [px, bank_y(px, pz) - 0.04, pz,
                          random.uniform(0.0, 360.0),
                          sc, sc * random.uniform(0.6, 1.0), sc]
    node("Pebbles", "Node3D", ".", {
        "script": ext("Script", "res://scripts/environment/ScatterField.gd"),
        "kind": '"rock"',
        "source_scene": ext("PackedScene", "res://assets/environment/pebbles.glb"),
        "variants": "6",
        "cast_shadows": "false",
        "placements": "PackedFloat32Array(%s)" % ", ".join("%.3f" % v for v in pebble_pl),
    })

    # trees: authored singles inside the core, groves filling the frame edges
    tree_spots = []
    for px, pz, s in [(-3.0, 17.0, 1.1), (2.4, 20.0, 0.9), (-20.0, -19.0, 1.05),
                      (-14.4, -20.7, 0.9), (12.0, 21.0, 0.95), (-23.0, 6.0, 0.95),
                      (23.0, -19.0, 1.1), (20.0, 16.0, 1.0), (-28.0, -12.0, 1.0),
                      (16.0, 8.0, 0.95), (-9.0, 23.0, 1.0)]:
        claim(px, pz, 2.4 * s)
        tree_spots.append((px, pz, s))
    for cx, cz, n in [(-40.0, -3.0, 7), (-28.0, -32.0, 6), (9.0, -38.0, 6),
                      (40.0, -9.0, 7), (34.0, 25.0, 6), (-12.0, 32.0, 5),
                      (-44.0, 25.0, 5), (26.0, 34.0, 5), (44.0, 6.0, 5)]:
        tree_spots += cluster(n, cx, cz, 7.0, (0.85, 1.25), r_mul=2.4)
    tree_pl = []
    for px, pz, s in tree_spots:
        tree_pl += [px, bank_y(px, pz), pz, random.uniform(0.0, 360.0), s, s, s]
    node("Trees", "Node3D", ".", {
        "script": ext("Script", "res://scripts/environment/ScatterField.gd"),
        "kind": '"tree"',
        "source_scene": ext("PackedScene", "res://assets/environment/trees.glb"),
        "variants": "4",
        "material": MAT["leafA"],
        "placements": "PackedFloat32Array(%s)" % ", ".join("%.3f" % v for v in tree_pl),
    })

    # bushes: skirt the rock clumps and the gorge, never the open meadow
    bush_spots = []
    for cx, cz, n, sp in [(-16.5, 12.0, 8, 5.0), (-8.0, 19.5, 6, 4.4),
                          (-20.0, -6.0, 6, 4.0), (4.5, -16.5, 5, 4.0),
                          (20.0, 6.0, 7, 5.5), (18.5, -13.5, 6, 5.0),
                          (-33.0, 9.0, 7, 7.0), (24.0, -27.0, 7, 7.0),
                          (-26.0, 24.0, 6, 6.0), (6.0, 28.0, 6, 6.0)]:
        bush_spots += cluster(n, cx, cz, sp, (0.6, 1.2), r_mul=1.1)
    bush_pl = []
    for px, pz, s in bush_spots:
        bush_pl += [px, bank_y(px, pz), pz, random.uniform(0.0, 360.0),
                    s * 1.7, s * 1.1, s * 1.5]
    node("Bushes", "Node3D", ".", {
        "script": ext("Script", "res://scripts/environment/ScatterField.gd"),
        "kind": '"bush"',
        "source_scene": ext("PackedScene", "res://assets/environment/bushes.glb"),
        "variants": "6",
        "material": MAT["bush"],
        "placements": "PackedFloat32Array(%s)" % ", ".join("%.3f" % v for v in bush_pl),
    })

    # ------------------------------------------------------- ground clutter
    # One MultiMesh of real (tiny) blade geometry -- no alpha, no overdraw.
    # `taken` at this point holds every prop already placed, so tufts never
    # grow through a rock or a wall.
    excl = ", ".join("%.2f, %.2f, %.2f" % (tx, tz, max(tr_ * 0.8, 0.6))
                     for tx, tz, tr_ in taken)
    node("GrassField", "MultiMeshInstance3D", ".",
         {"script": ext("Script", "res://scripts/environment/GrassField.gd"),
          "material_override": MAT["tuft"],
          "cast_shadow": "0",
          "tuft_count": "2600",
          "area_min": "Vector2(-36, -32)",
          "area_max": "Vector2(32, 24)",
          "far_bank_y": "%g" % FAR_BANK_Y,
          "river_x0": "%g" % RX0,
          "river_slope": "%g" % RSLOPE,
          "river_half": "%g" % (RIVER_W / 2.0 + 0.7),
          "loop_center": "Vector2(%g, %g)" % LOOP_C,
          "loop_radii": "Vector2(%g, %g)" % (LOOP_A, LOOP_B),
          "loop_band": "Vector2(0.80, 1.20)",
          "exclusions": "PackedVector3Array(%s)" % excl,
          "blade_height": "0.42",
          "rng_seed": "20260820"})

    # ------------------------------------------------------ player placeholder
    pl = node("Player", "Node3D", ".", None, T((-1.2, 0.0, 3.6), ry=28.0))
    mesh("Torso", pl, box, MAT["player"], (0.0, 1.55, 0.0), scale=(1.9, 1.2, 2.3))
    mesh("Turret", pl, cyl, MAT["player"], (0.0, 2.35, -0.2), scale=(1.3, 0.7, 1.3))
    mesh("Gun", pl, cyl, MAT["metal"], (0.45, 2.3, -1.7), rx=90.0,
         scale=(0.28, 2.4, 0.28))
    mesh("Gun2", pl, cyl, MAT["metal"], (-0.45, 2.3, -1.5), rx=90.0,
         scale=(0.24, 2.0, 0.24))
    for i, dx in enumerate((-0.95, 0.95)):
        mesh("Hip%d" % i, pl, box, MAT["metal"], (dx, 1.0, 0.0),
             scale=(0.5, 0.7, 1.2))
        mesh("Leg%d" % i, pl, box, MAT["metal"], (dx, 0.45, 0.1),
             scale=(0.42, 0.9, 0.5))
        mesh("Foot%d" % i, pl, box, MAT["metal"], (dx, 0.12, 0.15),
             scale=(0.6, 0.25, 1.5))

    if PERFORMANCE:
        # ------------------------------------------------------ crowd benchmark
        node("Crowd", "Node3D", ".", {
            "script": ext("Script", "res://scripts/units/EnemyCrowd.gd"),
            "target_path": 'NodePath("../Player")',
            "count": "0",
            "spawn_radius": "%.1f" % spawn_radius(),
            "move_speed": "1.6",
            "stop_radius": "6.0",
            "churn_per_sec": "10.0",
            "shadow_mode": '"B"',
        })
        node("CrowdMM", "Node3D", ".", {
            "script": ext("Script", "res://scripts/units/EnemyCrowdMM.gd"),
            "target_path": 'NodePath("../Player")',
            "variant": '"merged"',
            "count": "0",
            "spawn_radius": "%.1f" % spawn_radius(),
            "move_speed": "1.6",
            "stop_radius": "6.0",
            "churn_per_sec": "10.0",
            "shadow_mode": '"B"',
        })
        node("Vfx", "Node3D", ".", {
            "script": ext("Script", "res://scripts/vfx/VfxManager.gd"),
            "explosion_light": "false",
            # 只有压测场景需要大容量手动投放池（见 VfxManager.mass_pool）
            "mass_pool": "8192",
        })
        node("VfxStress", "Node3D", ".", {
            "script": ext("Script", "res://scripts/vfx/VfxStress.gd"),
            "vfx_path": 'NodePath("../Vfx")',
            "center_path": 'NodePath("../Player")',
            "target_projectiles": "0",
            "explosions_per_sec": "0.0",
            "radius": "22.0",
        })
        node("Benchmark", "Node", ".", {
            "script": ext("Script", "res://benchmark/BenchmarkManager.gd"),
            "crowd_path": 'NodePath("../Crowd")',
            "crowd_mm_path": 'NodePath("../CrowdMM")',
            "stress_path": 'NodePath("../VfxStress")',
            "warmup_sec": "5.0",
            "measure_sec": "20.0",
            "label": '"M4-node"',
        })
        return

    # ----------------------------------------------------- enemy placeholders
    en = node("Enemies", "Node3D", ".")
    for i, (px, pz) in enumerate([
            (-9.3, -5.1), (-6.6, -7.8), (-3.0, -3.9), (0.9, -1.8), (3.3, -5.7),
            (-12.0, 0.6), (-9.0, 4.2), (-4.5, 6.9), (2.1, 4.8), (5.4, 1.5),
            (6.9, -9.6), (-15.6, -3.0), (-2.4, 10.5), (-13.5, 9.0), (3.0, 12.6),
            (8.1, 7.5), (-18.0, 2.4), (-7.5, 14.7), (10.5, -3.0), (-19.5, 12.0),
            (1.5, 17.0), (-11.0, 18.0), (12.5, 3.0), (-16.0, 6.5), (6.5, -2.0),
            (-5.0, 20.0)]):
        g = node("Enemy%d" % i, "Node3D", en, None,
                 T((px, 0.0, pz), ry=random.uniform(0.0, 360.0)))
        # ~1.6 m tall: readable as a silhouette from the gameplay camera
        mesh("Body", g, cap, MAT["enemy"], (0.0, 0.92, 0.0),
             scale=(0.78, 0.62, 0.78))
        mesh("Head", g, box, MAT["metal"], (0.0, 1.44, 0.0), scale=(0.5, 0.36, 0.5))
        mesh("Gun", g, box, MAT["metal"], (0.3, 1.02, -0.62), scale=(0.18, 0.18, 1.1))
        for j, dx in enumerate((-0.3, 0.3)):
            mesh("Leg%d" % j, g, box, MAT["metal"], (dx, 0.26, 0.0),
                 scale=(0.24, 0.52, 0.3))

    # ------------------------------------------------------------ combat VFX
    # Milestone 3: presentation only -- pooled/batched VFX plus a director that
    # fires the three reference weapons at the rates from doc section 22.
    node("Vfx", "Node3D", ".", {
        "script": ext("Script", "res://scripts/vfx/VfxManager.gd"),
        "explosion_light": "false",
    })
    node("Combat", "Node3D", ".", {
        "script": ext("Script", "res://scripts/units/CombatDirector.gd"),
        "vfx_path": 'NodePath("../Vfx")',
        "player_path": 'NodePath("../Player")',
        "enemies_path": 'NodePath("../Enemies")',
        "mg_rate": "10.0",
        "rocket_rate": "2.0",
        "tesla_rate": "1.0",
    })

    # One mid-sized enemy on the bridge, for scale reference.
    md = node("MidEnemy", "Node3D", ".", None,
              T((bcx + 4.5, DECK_Y + 0.15, bz), ry=-108.0))
    mesh("Hull", md, box, MAT["enemy"], (0.0, 1.1, 0.0), scale=(2.6, 1.5, 3.2))
    mesh("Turret", md, cyl, MAT["metal"], (0.0, 2.1, 0.0), scale=(1.8, 0.8, 1.8))
    mesh("Barrel", md, cyl, MAT["metal"], (0.0, 2.1, -2.0), rx=90.0,
         scale=(0.3, 3.0, 0.3))
    for j, dx in enumerate((-1.5, 1.5)):
        mesh("Track%d" % j, md, box, MAT["metal"], (dx, 0.45, 0.0),
             scale=(0.7, 0.9, 3.4))


_cli_overrides()
build()

with open(os.path.abspath(OUT), "w", encoding="utf-8") as f:
    f.write("[gd_scene load_steps=%d format=3]\n\n"
            % (len(extres) + len(subres) + 1))
    for rtype, path, rid in extres:
        f.write('[ext_resource type="%s" path="%s" id="%s"]\n'
                % (rtype, path, rid))
    if extres:
        f.write("\n")
    for rtype, rid, lines in subres:
        f.write('[sub_resource type="%s" id="%s"]\n' % (rtype, rid))
        f.write("\n".join(lines) + "\n\n")
    f.write("\n\n".join(nodes) + "\n")

_zf, _zn, _w = frame_size()
print("wrote %s : %d ext + %d sub_resources, %d nodes"
      % (os.path.normpath(OUT), len(extres), len(subres), len(nodes)))
print("camera: pitch %.1f deg, height %.1f m, fov %.1f, z %.2f"
      % (CAM_PITCH, CAM_HEIGHT, CAM_FOV, camera_z()))
print("visible ground: %.1f m wide, depth z %.1f .. %.1f (%.1f m)"
      % (_w, _zf, _zn, _zn - _zf))
