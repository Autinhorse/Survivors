# -*- coding: utf-8 -*-
"""风格 "hellrider" 的材质。

**这个风格自带布局**（styles/hellrider/layout.py），不共用 tools/layout.py ——
参考图的美术语言和 gatling 相差太远，构图上也不同（那是熔岩走廊）。
所以这里的槽位名字只对本风格的布局负责，不需要和 gatling 对齐。

材质总共只有五个，这本身就是风格的一部分：

    ground  方格铺地（hr_ground）
    lava    熔岩带（hr_lava，unshaded）
    water   平的青色水面（hr_flat，纯色）
    flat    所有道具共用（hr_flat，读顶点色）
    unit    玩家和敌人（hr_flat，纯色）

gatling 那边光材质就有十七个，因为每类表面都要各自的贴图和参数。
这里没有贴图，所以不需要。
"""
from tscnlib import *          # noqa: F401,F403

MESH_DIR = "res://assets/hellrider/environment"


def MESH(name):
    return MESH_DIR + "/" + name


MAT = {}


def materials():
    # 全部来自 styles/hellrider/reference/ 的量化调色板：
    #   地面 #74533C .. #B7885B（同一色相的几档明暗，就是方格铺地）
    #   熔岩 #F95231 / #E5313A / #C5344C
    #   水   #36A2B0
    MAT["ground"] = shader_mat(
        "MatHrGround", "res://shaders/hr_ground.gdshader",
        # 方格的明暗差要**非常**小。判据：把地面区域去掉大尺度渐变之后的 std。
        #   参考图（绿地面）  5.87
        #   我们第一版        30.07   —— 高 5 倍，读出来是一张棋盘
        # 参考图里的格子要把对比度提高 3 倍才看得见，本来就该是这样。
        # a..b 是**整条**明度阶梯的两端。色相和饱和度不动，纯乘一个系数
        # （参考图里跨档 H 0.253->0.266、S 0.386->0.398，基本不变）。
        # 注意这里写的比是**uniform 空间**的，源色要过一次 sRGB->线性，
        # 屏幕上量到的比会更大：实测 uniform 1.12 -> 画面 1.204，指数约 1.64。
        # 所以要画面 1.16，这里写 1.095。旧值 uniform 1.035，地面读成一片死色。
        tile_a=col(0.5287, 0.3808, 0.2739),
        tile_b=col(0.5805, 0.4181, 0.3007),
        tile_size="2.6", tile_steps="4.0", tile_bias="0.55",
        # 分区 5 x 2.6 = 13 m。屏幕上约 380 px，和参考图里那些大色块同量级；
        # 细格 2.6 m 只有 76 px，两个尺度分别对应量出来的
        # "半幅块 std 3.04" 和 "总 std 5.54"。
        # 权重偏向分区：细格只在大色块上再抖一点点。
        # 0.55 那版细格的振幅跟着总跨度一起放大了 3 倍，直接读成棋盘。
        zone_size_mul="3.0", zone_steps="3.0", zone_weight="0.80",
        zone_jitter="1.0",
        lattice_deg="0.0",
        path_a=col(0.310, 0.216, 0.153), path_b=col(0.404, 0.290, 0.204),
        light_steps="3.0", light_floor="0.72")

    MAT["lava"] = shader_mat(
        "MatHrLava", "res://shaders/hr_lava.gdshader",
        rim_inner=col(1.000, 0.780, 0.290), rim_outer=col(0.976, 0.322, 0.192),
        lava_hot=col(0.969, 0.251, 0.224), lava_mid=col(0.871, 0.192, 0.271),
        lava_cold=col(0.604, 0.145, 0.267),
        rim_inner_w="0.55", rim_outer_w="1.30",
        diamond_size="3.2", fade_dist="26.0", pulse_speed="0.6")

    MAT["water"] = shader_mat(
        "MatHrWater", "res://shaders/hr_flat.gdshader",
        tint="0.0", base_color=col(0.212, 0.635, 0.690),
        light_steps="2.0", light_floor="0.82", top_boost="0.0")

    MAT["waterdeep"] = shader_mat(
        "MatHrWaterDeep", "res://shaders/hr_flat.gdshader",
        tint="0.0", base_color=col(0.145, 0.463, 0.510),
        light_steps="2.0", light_floor="0.85", top_boost="0.0")

    # 所有道具共用一个材质：颜色在顶点色里，明暗台阶由着色器分档产生
    MAT["flat"] = shader_mat(
        "MatHrFlat", "res://shaders/hr_flat.gdshader",
        # 明暗只有一条规则：法线和光照方向的夹角，分 4 档。
        # gamma 1.6 是把档位挪到面真正分布的区间上（0-120°），
        # 纯线性时最暗那档要 θ>150° 才够得着，画面会发灰。
        tint="1.0", light_steps="4.0", light_floor="0.20",
        light_gamma="1.6", light_jitter="0.06",
        top_boost="0.10",
        # 吃地面的低频分区。这四个必须和上面 ground 的写法一致。
        #
        # 幅度对齐地面分区在画面上的跨度（约 1.11）。**不能直接抄地面那个数**：
        # zone_tint 乘的是线性空间的 ALBEDO，而 tile_a/tile_b 是 source_color，
        # 要多过一次 sRGB->线性。同样写 0.035，地面落到画面上是 1.12，
        # 物体只有 1.034 —— 差 3 倍。补上 2.2 次方后是 0.11。
        zone_tint="0.11", tile_size="2.6", zone_size_mul="3.0",
        zone_steps="3.0", lattice_deg="0.0", zone_jitter="1.0")

    # blob 阴影：贴在地面上的软影贴片，代替真实投影阴影。
    # 参考图里树/石头下面的影子是居中的软椭圆，没有方向偏移。
    MAT["blob"] = shader_mat(
        "MatHrBlob", "res://shaders/hr_blob.gdshader",
        # 剖面由 shader 程序生成，不再挂贴图（贴图那版的浓区被物体自己盖住了）
        shadow_color=col(0.31, 0.20, 0.13), strength="0.58", core="0.42")

    MAT["player"] = shader_mat(
        "MatHrPlayer", "res://shaders/hr_flat.gdshader",
        tint="0.0", base_color=col(0.949, 0.784, 0.220),
        light_steps="3.0", light_floor="0.55", top_boost="0.08")
    MAT["enemy"] = shader_mat(
        "MatHrEnemy", "res://shaders/hr_flat.gdshader",
        tint="0.0", base_color=col(0.878, 0.890, 0.910),
        light_steps="3.0", light_floor="0.55", top_boost="0.08")
    MAT["enemydark"] = shader_mat(
        "MatHrEnemyDark", "res://shaders/hr_flat.gdshader",
        tint="0.0", base_color=col(0.290, 0.302, 0.337),
        light_steps="3.0", light_floor="0.55", top_boost="0.08")
    return MAT
