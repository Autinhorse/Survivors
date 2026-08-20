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


def shader_mat(name, shader_path, **params):
    props = {"shader": ext("Shader", shader_path)}
    for k, v in params.items():
        props["shader_parameter/" + k] = v
    return sub("ShaderMaterial", name, props)


def col(r, g, b, a=1.0):
    return "Color(%g, %g, %g, %g)" % (r, g, b, a)


def mat(name, rgb, rough=1.0, metal=0.0, alpha=None, tex=None, tex_scale=0.30):
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
    if alpha is not None:
        p["transparency"] = 1
    return sub("StandardMaterial3D", name, p)


MAT = {}


def materials():
    # --- shared noise ---------------------------------------------------------
    macro = noise_tex("NoiseMacro", 0.010, lo=0.0, hi=1.0, octaves=4, size=512)
    detail = noise_tex("NoiseDetail", 0.035, lo=0.0, hi=1.0, octaves=3, size=256)
    rock_n = noise_tex("NoiseRock", 0.055, lo=0.62, hi=1.05, octaves=4)
    wood_n = noise_tex("NoiseWood", 0.090, lo=0.70, hi=1.08, octaves=2)
    plaster_n = noise_tex("NoisePlaster", 0.030, lo=0.80, hi=1.06, octaves=3)
    water_n = noise_tex("NoiseWater", 0.014, lo=0.38, hi=0.62, octaves=2)
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
                              bump_strength="3.2", bump_epsilon="0.055",
                              grass_dark=col(0.106, 0.145, 0.055),
                              grass_light=col(0.310, 0.341, 0.129),
                              dirt_color=col(0.325, 0.243, 0.145),
                              rock_color=col(0.235, 0.212, 0.184),
                              macro_scale="0.022", detail_scale="0.30",
                              dirt_threshold="0.74",
                              slope_grass="0.82", slope_rock="0.48")
    MAT["cliff"] = MAT["grass"]

    MAT["dirt"] = shader_mat("MatPatch", "res://shaders/ground_patch.gdshader",
                             detail_noise=detail,
                             dirt_dark=col(0.208, 0.153, 0.094),
                             dirt_light=col(0.365, 0.271, 0.161),
                             noise_scale="0.42", edge_softness="0.42",
                             edge_break="0.60", coverage="0.70")

    MAT["water"] = shader_mat("MatWater", "res://shaders/water.gdshader",
                              wave_noise=water_n,
                              shallow_color=col(0.129, 0.278, 0.278),
                              deep_color=col(0.024, 0.075, 0.114),
                              foam_color=col(0.769, 0.804, 0.820),
                              wave_scale="0.22", flow_speed="0.07",
                              normal_strength="0.45", base_alpha="0.93",
                              bank_foam="0.22", streak_amount="0.14")

    # --- foliage: wind sway + noise break-up ---------------------------------
    MAT["leafA"] = shader_mat("MatLeafA", "res://shaders/foliage.gdshader",
                              detail_noise=detail,
                              leaf_dark=col(0.114, 0.176, 0.055),
                              leaf_light=col(0.349, 0.427, 0.161),
                              noise_scale="0.55", wind_strength="0.10",
                              wind_speed="1.1", ao_strength="0.45",
                              sway_height="4.4")
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
                             sway_height="0.7")
    MAT["tuft"] = shader_mat("MatTuft", "res://shaders/grass_tuft.gdshader",
                             base_color=col(0.216, 0.259, 0.094),
                             tip_color=col(0.392, 0.427, 0.169),
                             dry_color=col(0.451, 0.396, 0.180),
                             wind_strength="0.16", wind_speed="1.6",
                             fade_start="55.0", fade_end="78.0")

    # --- solid props ----------------------------------------------------------
    MAT["rock"] = mat("MatRock", (0.298, 0.278, 0.255), rough=0.88,
                      tex=rock_n, tex_scale=0.55)
    MAT["wood"] = mat("MatWood", (0.286, 0.192, 0.110), rough=0.92,
                      tex=wood_n, tex_scale=0.85)
    MAT["woodlt"] = mat("MatWoodLt", (0.443, 0.318, 0.180), rough=0.90,
                        tex=wood_n, tex_scale=0.85)
    MAT["wall"] = mat("MatWall", (0.616, 0.573, 0.478), rough=0.94,
                      tex=plaster_n, tex_scale=0.40)
    MAT["roof"] = mat("MatRoof", (0.318, 0.310, 0.176), rough=0.96,
                      tex=wood_n, tex_scale=1.30)
    MAT["metal"] = mat("MatMetal", (0.298, 0.310, 0.337), rough=0.42, metal=0.65,
                       tex=rock_n, tex_scale=1.20)
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
RIVER_W = 7.5                    # channel width
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


def river_x(z):
    return RX0 + RSLOPE * z


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
                  sky_top_color=col(0.235, 0.373, 0.576),
                  sky_horizon_color=col(0.847, 0.729, 0.545),
                  sky_curve="0.16",
                  ground_bottom_color=col(0.263, 0.220, 0.169),
                  ground_horizon_color=col(0.702, 0.596, 0.451),
                  sun_angle_max="18.0", sun_curve="0.18",
                  energy_multiplier="1.05")
    sky = sub("Sky", "Sky", sky_material=sky_mat)
    env = sub("Environment", "Env",
              background_mode="2", sky=sky,
              ambient_light_source="3", ambient_light_sky_contribution="1.0",
              ambient_light_energy="0.42",
              tonemap_mode="3", tonemap_exposure="1.0", tonemap_white="6.0",
              glow_enabled="true", glow_intensity="0.65", glow_strength="1.1",
              glow_bloom="0.12", glow_hdr_threshold="0.95",
              glow_blend_mode="1",
              # Mobile renderer has no SSAO/SSIL/SDFGI; depth fog is the only
              # atmospheric depth cue available here (doc section 10).
              fog_enabled="true", fog_mode="0",
              fog_light_color=col(0.769, 0.686, 0.541),
              fog_light_energy="0.9", fog_sun_scatter="0.25",
              fog_density="0.0016", fog_sky_affect="0.0",
              fog_height="-6.0", fog_height_density="0.02",
              adjustment_enabled="true", adjustment_saturation="1.06",
              adjustment_contrast="1.12", adjustment_brightness="1.0")
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
         {"light_color": col(1.0, 0.878, 0.706), "light_energy": "1.8",
          "light_angular_distance": "1.4", "shadow_enabled": "true",
          "shadow_opacity": "0.92",
          "shadow_bias": "0.035", "shadow_normal_bias": "1.2",
          "shadow_blur": "1.2",
          "directional_shadow_max_distance": "130.0",
          "directional_shadow_split_1": "0.07",
          "directional_shadow_split_2": "0.22",
          "directional_shadow_blend_splits": "true"},
         T((0.0, 20.0, 0.0), ry=-132.0, rx=-48.0))

    node("GameplayCamera", "Camera3D", ".",
         {"fov": "%.1f" % CAM_FOV, "near": "0.5", "far": "300.0",
          "current": "true"},
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
    for i, z in enumerate(range(-88, 89, 8)):
        node("RiverCut%d" % i, "CSGBox3D", ter,
             {"size": "Vector3(%g, 8, 10)" % RIVER_W, "operation": "2",
              "material": MAT["cliff"]},
             T((river_x(z), BED_Y + 4.0, z), ry=RANG))

    # ------------------------------------------------------------------ water
    water = node("Water", "Node3D", ".")
    for i, z in enumerate(range(-84, 85, 6)):
        mesh("Water%d" % i, water, plane, MAT["water"],
             (river_x(z), WATER_Y, z), ry=RANG,
             scale=(RIVER_W - 0.5, 1.0, 6.4), cast_shadow="0")

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

    building("HouseA", (-12.9, -13.2), 6.8, 4.8, 3.4, -8.0, (2.4, -1.5))
    building("HouseB", (-2.7, -11.1), 4.4, 3.8, 2.8, 14.0, (-1.3, -1.1))
    building("HouseC", (-21.5, -6.5), 5.0, 4.0, 3.0, 22.0, (1.6, 1.2))
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
    for cx, cz, n, sp in [(-17.0, 11.0, 14, 4.2), (-10.0, 19.0, 11, 4.0),
                          (-21.0, 2.0, 9, 3.4), (-19.5, -8.0, 6, 3.0),
                          (-4.0, 21.0, 8, 3.6), (-27.0, 16.0, 8, 4.0)]:
        spots += cluster(n, cx, cz, sp, (0.7, 2.4), r_mul=0.8)
    for z in range(-22, 23, 3):                            # gorge lip
        px = river_x(z) - RIVER_W / 2.0 - random.uniform(0.6, 2.4)
        pz = z + random.uniform(-1.0, 1.0)
        s = random.uniform(0.6, 1.8)
        if not blocked(px, pz, s * 0.7):
            claim(px, pz, s * 0.7)
            spots.append((px, pz, s))
    for cz in (-17.0, -2.0, 13.0):                         # far bank
        spots += cluster(6, river_x(cz) + 9.0, cz, 4.0, (0.9, 2.2), r_mul=0.8)
    for cx, cz in ((-40.0, 20.0), (30.0, -34.0), (-42.0, -22.0), (38.0, 22.0),
                   (0.0, 34.0), (-30.0, -34.0)):
        spots += cluster(8, cx, cz, 6.0, (1.0, 2.6), r_mul=0.8)
    rock_pl = []
    for px, pz, s in spots:
        sy = s * random.uniform(0.55, 0.85)
        rock_pl += [px, bank_y(px, pz) + 0.22 * sy, pz,
                    random.uniform(0.0, 360.0),
                    s, sy, s * random.uniform(0.7, 1.2)]
    node("Rocks", "Node3D", ".", {
        "script": ext("Script", "res://scripts/environment/ScatterField.gd"),
        "kind": '"rock"',
        "variants": "6",
        "material": MAT["rock"],
        "placements": "PackedFloat32Array(%s)" % ", ".join("%.3f" % v for v in rock_pl),
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
        "variants": "4",
        "material": MAT["wood"],
        "material_secondary": MAT["leafA"],
        "trunk_height": "3.6",
        "trunk_radius": "0.28",
        "canopy_radius": "2.5",
        "canopy_blobs": "4",
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
        "variants": "4",
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
            "spawn_radius": "30.0",
            "move_speed": "1.6",
            "stop_radius": "6.0",
            "churn_per_sec": "10.0",
            "shadow_mode": '"B"',
        })
        node("Benchmark", "Node", ".", {
            "script": ext("Script", "res://benchmark/BenchmarkManager.gd"),
            "crowd_path": 'NodePath("../Crowd")',
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
