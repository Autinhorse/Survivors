# -*- coding: utf-8 -*-
"""风格 "gatling"：对齐 docs/target.png（Gatling Gears）的暖色低多边形村庄。

这个模块只负责**填充材质槽位**。布局在 tools/layout.py，
两个风格共用，所以这里改什么都不会动到构图。

槽位约定（新风格必须提供同名的键，否则布局会 KeyError）：

  grass / cliff   地形（同一个材质，着色器按坡度分草/土/石）
  dirt            路面补丁
  water           河面
  leafA / leafB   树冠
  bush            灌木
  tuft            草丛
  rock            旧的实体石头材质（保留兼容）
  proprock        石头（三平面 + 岩石贴图）
  prop            硬表面道具（世界坐标程序化）
  prophouse       房屋（灰泥 + 茅草两张方向性贴图）
  propwood        桥（木纹贴图）
  wood / woodlt   木构件
  wall / roof     旧的建筑材质（保留兼容）
  metal           金属
  player / enemy  单位
"""
from tscnlib import *          # noqa: F401,F403

MESH_DIR = "res://assets/gatling/environment"


def MESH(name):
    """资产按风格分目录，布局通过这个函数取路径。"""
    return MESH_DIR + "/" + name

MAT = {}


def materials():
    # --- shared noise ---------------------------------------------------------
    macro = noise_tex("NoiseMacro", 0.010, lo=0.0, hi=1.0, octaves=4, size=512)
    detail = noise_tex("NoiseDetail", 0.035, lo=0.0, hi=1.0, octaves=3, size=256)
    # 叶片图集（tools/gen_leaf_atlas.py 生成）：RGB 是叶片自身的明暗，
    # alpha 是叶片形状。颜色来自顶点色，所以一张灰度图集能长出所有色系变体。
    leaf_atlas = ext("Texture2D", "res://assets/gatling/environment/leaf_atlas.png")
    rock_n = noise_tex("NoiseRock", 0.055, lo=0.62, hi=1.05, octaves=4)
    # 岸壁立面的石块纹理。用**元胞噪声**而不是值噪声：
    # 值噪声只有各向同性的斑点，出不来"一块块石头"的读法。
    # cellular_return_type=4（Distance2Sub）在胞边趋近 0、胞心较大，
    # 得到的是圆润的石块 + 石缝，正好是参考图河岸的样子。
    rock_cells = noise_tex("NoiseCells", 0.085, lo=0.34, hi=1.10, octaves=2,
                           size=512, noise_type="2", cellular_return_type="4",
                           cellular_jitter="1.0")
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
                              rock_cells=rock_cells,
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
                              cell_scale="0.085", cell_mix="0.62",
                              cell_bump="1.35",
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
    # 桥用外部木纹贴图（assets/textures/wood_planks.png，可以直接改图）。
    # 房屋仍走纯程序化那一路 —— 它们没有铺 UV。
    MAT["propwood"] = shader_mat("MatPropWood", "res://shaders/prop.gdshader",
                                 detail_noise=detail,
                                 albedo_tex=ext(
                                     "Texture2D",
                                     "res://assets/gatling/textures/wood_planks.png"),
                                 use_uv_tex="1.0", uv_tex_scale="1.0",
                                 uv_tex_strength="0.85",
                                 uv_tex_mean=tex_mean(
                                     "assets/gatling/textures/wood_planks.png"),
                                 scale_stone="0.55", scale_wood="0.75",
                                 contrast_stone="0.30", contrast_wood="0.14",
                                 bump_stone="1.10", bump_wood="0.70",
                                 epsilon="0.06", surface_roughness="0.94")

    # 房屋：灰泥（COLOR.a=0）+ 茅草（COLOR.a=1）两张方向性贴图。
    # 茅草的条纹在资产侧用 long_axis_u=False 铺成顺坡方向。
    MAT["prophouse"] = shader_mat(
        "MatPropHouse", "res://shaders/prop.gdshader",
        detail_noise=detail,
        albedo_tex=ext("Texture2D", "res://assets/gatling/textures/plaster.png"),
        albedo_tex_b=ext("Texture2D", "res://assets/gatling/textures/thatch.png"),
        uv_tex_mean=tex_mean("assets/gatling/textures/plaster.png"),
        uv_tex_mean_b=tex_mean("assets/gatling/textures/thatch.png"),
        use_uv_tex="1.0", uv_tex_scale="1.0", uv_tex_scale_b="1.0",
        uv_tex_strength="0.42",
        scale_stone="0.55", scale_wood="0.75",
        contrast_stone="0.24", contrast_wood="0.16",
        bump_stone="1.10", bump_wood="0.80",
        epsilon="0.06", surface_roughness="0.94")

    # 石头：颗粒 + 裂纹的岩石贴图，颜色来自顶点色（逐块抖过）。
    # MultiMesh 上必须挂 material_override，否则用的是 GLB 自带的纯色材质 ——
    # 这个坑在树、房屋、石头上各踩了一次。
    MAT["proprock"] = shader_mat(
        "MatPropRock", "res://shaders/prop.gdshader",
        detail_noise=detail,
        albedo_tex=ext("Texture2D", "res://assets/gatling/textures/rock.png"),
        albedo_tex_b=ext("Texture2D", "res://assets/gatling/textures/rock.png"),
        uv_tex_mean=tex_mean("assets/gatling/textures/rock.png"),
        uv_tex_mean_b=tex_mean("assets/gatling/textures/rock.png"),
        use_uv_tex="1.0", uv_tex_scale="1.0", uv_tex_scale_b="1.0",
        uv_tex_strength="0.55",
        use_triplanar="1.0", triplanar_scale="0.85",
        triplanar_sharpness="4.0",
        scale_stone="0.60", scale_wood="0.60",
        contrast_stone="0.26", contrast_wood="0.26",
        # 法线扰动对凸包不能开：它用的是逐面切平面投影，
        # 相邻面的坐标系不同，扰动图案在每条棱上跳变 ——
        # 小石头上就是一身黑白斑。石头的立体感交给三平面 albedo 和倒角。
        bump_stone="0.0", bump_wood="0.0",
        epsilon="0.06", surface_roughness="0.90")

    MAT["prop"] = shader_mat("MatProp", "res://shaders/prop.gdshader",
                             detail_noise=detail,
                             scale_stone="0.55", scale_wood="0.75",
                             contrast_stone="0.38", contrast_wood="0.22",
                             bump_stone="1.40", bump_wood="0.90",
                             epsilon="0.06",
                             surface_roughness="0.94")

    MAT["player"] = mat("MatPlayer", (0.706, 0.290, 0.098), rough=0.48, metal=0.35)
    MAT["enemy"] = mat("MatEnemy", (0.502, 0.161, 0.129), rough=0.58, metal=0.25)



    return MAT
