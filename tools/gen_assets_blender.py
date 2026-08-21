# -*- coding: utf-8 -*-
"""程序化生成本项目的环境资产（Blender，无头运行）。

和 tools/asset_pipeline.py 的分工：

    asset_pipeline.py    清理"外来"的脏网格（AI 生成 / 购买 / 别人做的）
    gen_assets_blender.py  直接把资产"长"出来（本文件）

对这个美术风格（stylized low-poly、强轮廓、清晰色块、模块化复用）来说，
程序化生成的质量上限比 AI 3D 更高：它要的正是规整几何和统一比例，
而这恰好是 AI 3D 最不擅长的。参数化还顺带解决了 §21 点名的风险项 ——
风格一致性是白送的，不是需要额外验证的东西。

约定（与 asset_pipeline.py 一致，Godot 侧才能无脑摆放）：
- 1 单位 = 1 米
- 每个物体的原点在底面中心，y=0 就是地面
- 平面着色（flat shading）：这个机位下轮廓和切面才是可读信息
- 材质按调色板命名并复用，不是每个物体一套

用法：
    blender --background --factory-startup --python tools/gen_assets_blender.py -- \
        --out-dir assets/environment --only buildings,trees
"""
import argparse
import math
import os
import sys

import bpy
import bmesh
from mathutils import Vector

# ------------------------------------------------------------------ 调色板 --
# 与 M2 在 Godot 侧使用的颜色保持一致，避免资产和现有场景割裂。
#
# 注意：下面的数值是 **sRGB**，因为它们抄自 Godot 的 StandardMaterial3D.albedo_color，
# 那边按 sRGB 解释。而 Blender 的 Principled BSDF Base Color 是**线性**的 ——
# 同样的数字直接搬过去，整体会被明显提亮（0.318 当 sRGB 是深橄榄，
# 当线性是浅卡其）。写入 Blender 前必须转换。
PALETTE = {
    "Wall":      (0.616, 0.573, 0.478),
    "WallDark":  (0.482, 0.443, 0.365),
    "Thatch":    (0.318, 0.310, 0.176),
    "ThatchDark": (0.235, 0.227, 0.125),
    "Wood":      (0.286, 0.192, 0.110),
    "WoodLight": (0.443, 0.318, 0.180),
    "Stone":     (0.255, 0.235, 0.231),
    "Metal":     (0.298, 0.310, 0.337),
    "Dark":      (0.102, 0.086, 0.075),
    "LeafA":     (0.180, 0.271, 0.098),
    "LeafB":     (0.243, 0.337, 0.129),
    "LeafDark":  (0.106, 0.161, 0.063),
    "LeafMid":   (0.220, 0.286, 0.102),
    "LeafLight": (0.353, 0.404, 0.145),
    "LeafDry":   (0.373, 0.263, 0.122),
    "LeafRust":  (0.325, 0.192, 0.102),
    "Flower":    (0.365, 0.310, 0.502),
    # 顶点色承载真实颜色，这个材质只是个载体，白色以免二次着色
    "Foliage":   (1.0, 1.0, 1.0),
}
_mats = {}


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat(name):
    if name in _mats and _mats[name].name in bpy.data.materials:
        return _mats[name]
    m = bpy.data.materials.new(name=name)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    if b:
        c = [srgb_to_linear(x) for x in PALETTE[name]]
        b.inputs["Base Color"].default_value = (c[0], c[1], c[2], 1.0)
        if "Roughness" in b.inputs:
            b.inputs["Roughness"].default_value = 0.92
        if "Metallic" in b.inputs:
            b.inputs["Metallic"].default_value = 0.5 if name == "Metal" else 0.0
    _mats[name] = m
    return m


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mats.clear()


# -------------------------------------------------------------- 基础构件 --
def box(size, loc, material, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = size
    o.data.materials.append(mat(material))
    return o


def cyl(radius, depth, loc, material, verts=8, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius,
                                        depth=depth, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.data.materials.append(mat(material))
    return o


def wedge(size, loc, material, rot=(0, 0, 0)):
    """三棱柱屋顶：Blender 没有现成的，用 bmesh 直接建，
    这样能精确控制屋脊位置和出檐，比缩放 primitive 可控得多。"""
    w, d, h = size
    verts = [
        (-w / 2, -d / 2, 0), (w / 2, -d / 2, 0), (w / 2, d / 2, 0), (-w / 2, d / 2, 0),
        (0, -d / 2, h), (0, d / 2, h),
    ]
    faces = [(0, 1, 4), (2, 3, 5), (0, 4, 5, 3), (1, 2, 5, 4), (0, 3, 2, 1)]
    me = bpy.data.meshes.new("wedge")
    me.from_pydata([Vector(v) for v in verts], [], faces)
    me.update()
    o = bpy.data.objects.new("wedge", me)
    bpy.context.collection.objects.link(o)
    o.location = loc
    o.rotation_euler = rot
    o.data.materials.append(mat(material))
    return o


def join_as(parts, name):
    bpy.ops.object.select_all(action="DESELECT")
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    # 合并前 apply：活动物体若带非等比缩放，被烘入的部件会按其倒数变形
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    bpy.ops.object.join()
    o = bpy.context.active_object
    o.name = name
    return o


def finalize(obj, loc=(0, 0, 0), smooth_angle=0.0):
    """着色 + 原点落到底面中心 + 摆到指定位置。

    smooth_angle = 0  纯平面着色（建筑、树干这种要硬边的）
    smooth_angle > 0  按角度自动平滑：小于该夹角的边平滑过渡、大于的保持硬边。
                      石头需要它 —— 倒角面才会和相邻面融成一条渐亮的带，
                      而不是一条突兀的亮线。"""
    if smooth_angle > 0.0:
        bpy.context.view_layer.objects.active = obj
        for p in obj.data.polygons:
            p.use_smooth = True
        try:
            bpy.ops.object.shade_auto_smooth(angle=math.radians(smooth_angle))
        except Exception:
            # 老版本回退：按面夹角手动标锐边
            import bmesh as _bm
            bm = _bm.new()
            bm.from_mesh(obj.data)
            thr = math.cos(math.radians(smooth_angle))
            for e in bm.edges:
                if len(e.link_faces) == 2:
                    a, b = e.link_faces
                    e.smooth = a.normal.dot(b.normal) > thr
            bm.to_mesh(obj.data)
            bm.free()
    else:
        for p in obj.data.polygons:
            p.use_smooth = False
    me = obj.data
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for v in me.vertices:
        for i in range(3):
            lo[i] = min(lo[i], v.co[i])
            hi[i] = max(hi[i], v.co[i])
    pivot = Vector(((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, lo.z))
    for v in me.vertices:
        v.co -= pivot
    me.update()
    obj.location = loc


def tris(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


# ------------------------------------------------------------------ 建筑 --
def building(name, w, d, wall_h, loc, roof_h=1.9, eaves=0.45, storeys=1,
             chimney=True, porch=False):
    """M2 的短板是建筑"还是纯色盒子 + 三棱柱"。真正让房子读起来像房子的
    是这几样，每一样都只花几十个面：

      - 石头地基（把墙和地面分开，避免"盒子插在草里"）
      - 屋顶出檐 + 屋脊（纯三棱柱没有厚度，一眼假）
      - 门和窗的凹陷（深色内凹，不是贴在墙上的色块）
      - 转角立柱 / 横梁（给墙面加水平分段，破掉大色块）
    """
    parts = []
    base_h = 0.28
    parts.append(box((w + 0.3, d + 0.3, base_h), (0, 0, base_h / 2), "Stone"))

    wall_z = base_h + wall_h / 2
    parts.append(box((w, d, wall_h), (0, 0, wall_z), "Wall"))

    # 转角立柱：把大墙面切成几块，轮廓上多出四条竖线
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(box((0.16, 0.16, wall_h),
                             (sx * (w / 2 - 0.05), sy * (d / 2 - 0.05), wall_z),
                             "Wood"))
    # 檐下横梁
    parts.append(box((w + 0.12, d + 0.12, 0.14),
                     (0, 0, base_h + wall_h - 0.07), "Wood"))

    if storeys > 1:
        # 二层稍微收进去，屋檐才有层次
        up_h = wall_h * 0.72
        up_z = base_h + wall_h + up_h / 2
        parts.append(box((w * 0.86, d * 0.86, up_h), (0, 0, up_z), "Wall"))
        parts.append(box((w * 0.86 + 0.12, d * 0.86 + 0.12, 0.12),
                         (0, 0, base_h + wall_h + up_h - 0.06), "Wood"))
        roof_base_z = base_h + wall_h + up_h
        roof_w, roof_d = w * 0.86, d * 0.86
    else:
        roof_base_z = base_h + wall_h
        roof_w, roof_d = w, d

    # 屋顶：出檐是关键，纯三棱柱贴着墙沿会显得很假
    parts.append(wedge((roof_w + eaves * 2, roof_d + eaves * 2, roof_h),
                       (0, 0, roof_base_z), "Thatch"))
    # 屋脊
    parts.append(box((0.22, roof_d + eaves * 2 + 0.1, 0.22),
                     (0, 0, roof_base_z + roof_h - 0.05), "ThatchDark"))

    # 门：凹进墙面
    door_w, door_h = 0.95, 1.9
    parts.append(box((door_w, 0.22, door_h),
                     (0, -d / 2 + 0.02, base_h + door_h / 2), "Dark"))
    parts.append(box((door_w + 0.18, 0.1, door_h + 0.16),
                     (0, -d / 2 - 0.04, base_h + door_h / 2), "Wood"))

    # 窗：同样凹进去，加十字窗框
    win = 0.62
    for sx, sy in ((-w / 4, -1), (w / 4, -1), (-w / 4, 1), (w / 4, 1)):
        if abs(sx) < door_w * 0.8 and sy < 0:
            continue
        y = sy * (d / 2 - 0.02)
        z = base_h + wall_h * 0.62
        parts.append(box((win, 0.18, win), (sx, y, z), "Dark"))
        parts.append(box((win + 0.14, 0.08, 0.09), (sx, y - sy * 0.06, z), "Wood"))
        parts.append(box((0.09, 0.08, win + 0.14), (sx, y - sy * 0.06, z), "Wood"))

    if chimney:
        cx, cy = w / 2 - 0.55, d / 4
        ch = roof_base_z + roof_h + 0.5
        parts.append(box((0.62, 0.62, ch), (cx, cy, ch / 2), "Stone"))
        parts.append(box((0.78, 0.78, 0.16), (cx, cy, ch + 0.02), "WallDark"))

    if porch:
        py = -d / 2 - 0.7
        parts.append(box((w * 0.8, 1.4, 0.14), (0, py, base_h + 0.07), "WoodLight"))
        for sx in (-1, 1):
            parts.append(box((0.14, 0.14, 1.9),
                             (sx * w * 0.34, py - 0.5, base_h + 0.95), "Wood"))
        parts.append(box((w * 0.86, 0.16, 0.16),
                         (0, py - 0.5, base_h + 1.92), "Wood"))

    o = join_as(parts, name)
    finalize(o, loc)
    return o


# ------------------------------------------------------------------ 石头 --
# 参考图的石头是"碎裂的岩块"：几个大平面、锐边、轮廓各不相同。
# 位移球体从原理上做不出这个 —— 它只会得到圆润的多面体，
# 面的分布还很均匀，一眼就是程序生成的。
#
# 正确做法是**随机点的凸包**：天然产生平面和锐边；改变点云的轴比就能
# 控制形状类型；点数直接控制面数（10 个点约 16 面 / 32 三角形）。
# 点数不能太少：7-11 个点的凸包会退化成尖锐的四面体，看起来像碎玻璃而不是石头。
# 参考图的石头是"十几个面的敦实块体"，所以点数要够、半径抖动要小。
ROCK_ARCHETYPES = {
    #            轴比 (x, y, z)        点数   垂直偏置
    "chunky":   ((1.00, 0.95, 0.68), 17, 0.0),
    "slab":     ((1.15, 1.30, 0.34), 16, 0.0),
    "column":   ((0.72, 0.78, 1.05), 15, 0.20),
    "wedge":    ((1.08, 0.76, 0.58), 15, -0.20),
    "block":    ((0.95, 0.90, 0.78), 14, 0.0),
    "pebble":   ((1.00, 0.92, 0.52), 10, 0.0),
}


def rock_hull(name, archetype, seed, loc=(0, 0, 0), bevel=0.05,
              smooth_angle=19.0):
    import random
    rng = random.Random(seed)
    axes, n_pts, bias = ROCK_ARCHETYPES[archetype]

    bm = bmesh.new()
    for i in range(n_pts):
        # 球面上的随机方向，再按轴比拉伸 —— 直接在盒子里取点会得到偏立方的结果
        z = rng.uniform(-1.0, 1.0) + bias
        z = max(-1.0, min(1.0, z))
        r = math.sqrt(max(0.0, 1.0 - z * z))
        a = rng.uniform(0.0, math.tau)
        # 半径抖动要小：抖太狠会让某个面变得极大、其他面缩成一条，
        # 结果就是尖锐的薄片
        k = rng.uniform(0.88, 1.0)
        bm.verts.new((math.cos(a) * r * axes[0] * k,
                      math.sin(a) * r * axes[1] * k,
                      z * axes[2] * k))
    bmesh.ops.convex_hull(bm, input=bm.verts[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    # 不切底面：切平会删掉大半几何（实测 8 块石头只剩 40 面），
    # 而且真实的散落岩块本来就是半埋的 —— 交给摆放时下沉更简单也更自然。

    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    o.data.materials.append(mat("Stone"))

    # 参考图的石头有一圈随光变化的高亮棱 —— 那是**几何倒角**，不是贴图：
    # 倒角面的法线在低角度夕阳下比水平顶面更正对光源，于是比顶面还亮，
    # 而且亮的总是朝阳那一侧。贴图伪造的边缘光不会随石头朝向这样变化。
    if bevel > 0.0:
        bpy.context.view_layer.objects.active = o
        m = o.modifiers.new("bevel", "BEVEL")
        m.width = bevel
        m.segments = 1
        m.limit_method = "ANGLE"
        m.angle_limit = math.radians(25.0)
        m.harden_normals = False
        bpy.ops.object.modifier_apply(modifier=m.name)

    finalize(o, loc, smooth_angle=smooth_angle)
    return o


def build_rocks(out_dir):
    """一个 GLB 装多个变体：石头走 MultiMesh 按变体取用，适合合并成一个文件。
    形状类型和尺寸都要拉开 —— 参考图里从碎石到巨石跨了一个数量级。"""
    clear()
    plan = [
        ("chunky", 1.00), ("chunky", 0.62), ("slab", 1.20), ("slab", 0.70),
        ("column", 0.85), ("wedge", 1.05), ("wedge", 0.55), ("block", 0.90),
    ]
    for i, (arch, scale) in enumerate(plan):
        o = rock_hull("rock_%02d" % i, arch, seed=1000 + i * 37,
                      loc=(i * 3.0 - 10.5, 0, 0))
        o.scale = (scale, scale, scale)
    export(os.path.join(out_dir, "rocks_lp.glb"), "rocks")

    clear()
    for i in range(6):
        o = rock_hull("pebble_%02d" % i, "pebble", seed=5000 + i * 53,
                      loc=(i * 1.2 - 3.0, 0, 0), bevel=0.0, smooth_angle=0.0)
        o.scale = (0.34, 0.34, 0.34)
    export(os.path.join(out_dir, "pebbles.glb"), "pebbles")


# ------------------------------------------------------------ 叶簇 / 灌木 --
# 参考图的灌木和树冠是**许多小叶簇堆成的**：轮廓有明显锯齿和缺口，
# 而且同一丛里颜色深浅不一。光滑的球（M2 的做法）从原理上出不来这个 ——
# 它的轮廓永远是连续曲线。
#
# 做法：每个小叶簇是一个 6-8 点的凸包（和石头同一套原理，只是很小、压扁），
# 若干个撒在半球壳上。凸包天然给出棱角，堆积天然给出缺口。
# 不用 alpha 贴片：M2 已经量过，真几何在这个机位下比透明层便宜
# （§15 点名的 overdraw 才是风险）。


def leaf_blob(rng, radius, squash=0.75):
    """一个小叶簇。返回 bmesh，调用方负责摆位和材质。"""
    bm = bmesh.new()
    n = rng.randint(12, 15)
    for i in range(n):
        z = rng.uniform(-1.0, 1.0)
        r = math.sqrt(max(0.0, 1.0 - z * z))
        a = rng.uniform(0.0, math.tau)
        k = rng.uniform(0.88, 1.0)
        bm.verts.new((math.cos(a) * r * radius * k,
                      math.sin(a) * r * radius * k,
                      z * radius * squash * k))
    bmesh.ops.convex_hull(bm, input=bm.verts[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return bm


def set_vcol(obj, colour_name, material="Foliage"):
    """把颜色烘进顶点色，并统一材质。

    统一材质有两个作用：合并后只剩一个 surface（一次 draw call），
    以及 Godot 侧可以用一个 material_override 挂着色器而不冲掉任何东西。
    树干也必须走这条路 —— 否则 material_override 会把它一起冲成白色。"""
    me = obj.data
    c = [srgb_to_linear(x) for x in PALETTE[colour_name]]
    attr = me.color_attributes.get("Color")
    if attr is None:
        attr = me.color_attributes.new(name="Color", type="BYTE_COLOR",
                                       domain="CORNER")
    for i in range(len(attr.data)):
        attr.data[i].color = (c[0], c[1], c[2], 1.0)
    me.materials.clear()
    me.materials.append(mat(material))
    return obj


def _blob_object(rng, radius, loc, colour_name, squash=0.75):
    """叶簇的颜色烘进**顶点色**，不是每簇一个材质。

    每簇一个材质的话，Godot 侧就只能用 GLB 自带材质，
    风摆着色器（scripts 的 foliage.gdshader）无从挂载 ——
    要么有颜色没风摆，要么用 material_override 把颜色全冲掉。
    顶点色让"一个材质 + 一个着色器"同时保住两者。"""
    bm = leaf_blob(rng, radius, squash)
    me = bpy.data.meshes.new("clump")
    bm.to_mesh(me)
    bm.free()

    o = bpy.data.objects.new("clump", me)
    bpy.context.collection.objects.link(o)
    o.location = loc
    return set_vcol(o, colour_name)


def bush(name, seed, loc=(0, 0, 0), radius=0.95, height=0.85, clumps=13,
         palette=("LeafDark", "LeafMid", "LeafLight")):
    """一丛灌木：**实心核 + 外圈叶簇**。

    只做外圈是第一版的错误 —— 叶簇撒在半球壳上、彼此不重叠，
    渲染出来是一地互不相连的碎片，完全没有体积。
    正确的读法是：核负责"这是一团东西"，外圈只负责把轮廓咬出缺口。"""
    import random
    rng = random.Random(seed)
    parts = []

    # 核：两三个大blob，把内部填实
    for i in range(2):
        parts.append(_blob_object(
            rng, radius * rng.uniform(0.58, 0.70),
            (rng.uniform(-0.18, 0.18) * radius, rng.uniform(-0.18, 0.18) * radius,
             height * rng.uniform(0.30, 0.45)),
            palette[min(len(palette) - 1, 1)], squash=height / max(radius, 0.01)))

    # 外圈：咬出缺口的叶簇，必须和核有重叠，否则又变成碎片
    for i in range(clumps):
        u = rng.uniform(0.0, 1.0)
        zt = u ** 0.7
        rr = math.sqrt(max(0.0, 1.0 - zt * zt))
        a = rng.uniform(0.0, math.tau)
        p = (math.cos(a) * rr * radius * rng.uniform(0.45, 0.92),
             math.sin(a) * rr * radius * rng.uniform(0.45, 0.92),
             zt * height * rng.uniform(0.5, 1.0))
        idx = min(len(palette) - 1, int(zt * len(palette) + rng.uniform(-0.4, 0.6)))
        parts.append(_blob_object(rng, radius * rng.uniform(0.22, 0.36), p,
                                  palette[max(0, idx)]))
    o = join_as(parts, name)
    finalize(o, loc, smooth_angle=50.0)
    return o


def build_bushes(out_dir):
    """多个色系的变体：参考图里同一片地上深绿、黄绿、红褐、紫花都有，
    颜色差异比形状差异更能打破重复感。"""
    clear()
    specs = [
        ("bush_green", ("LeafDark", "LeafMid", "LeafLight"), 0.95, 0.80, 22),
        ("bush_dark", ("LeafDark", "LeafDark", "LeafMid"), 1.10, 0.70, 26),
        ("bush_yellow", ("LeafMid", "LeafLight", "LeafLight"), 0.85, 0.90, 20),
        ("bush_rust", ("LeafRust", "LeafDry", "LeafLight"), 0.90, 0.75, 20),
        ("bush_flower", ("LeafDark", "LeafMid", "Flower"), 0.80, 0.85, 22),
        ("bush_small", ("LeafDark", "LeafMid", "LeafMid"), 0.55, 0.45, 14),
    ]
    for i, (nm, pal, r, h, c) in enumerate(specs):
        bush(nm, seed=900 + i * 41, loc=(i * 3.0 - 7.5, 0, 0),
             radius=r, height=h, clumps=c, palette=pal)
    export(os.path.join(out_dir, "bushes.glb"), "bushes")


# -------------------------------------------------------------------- 树 --
def tree(name, loc, height=5.4, trunk_r=0.17, seed=0, clumps=22,
         palette=("LeafDark", "LeafMid", "LeafLight"), crown_ratio=0.34):
    """树 = 有锥度和弯曲的树干 + 粗枝 + **由叶簇堆成的树冠**。

    M2 的"两个球"轮廓是连续曲线，一眼假。参考图的树冠边缘全是缺口和锯齿 ——
    那来自叶簇的堆积，不是来自把球体细分得更密。"""
    import random
    rng = random.Random(seed)
    parts = []

    # 树干：分段、带锥度和轻微弯曲（笔直圆柱是"棒棒糖树"的主因）
    segs = 4
    trunk_h = height * 0.44
    lean = Vector((rng.uniform(-0.22, 0.22), rng.uniform(-0.22, 0.22), 0.0))
    prev = None
    for i in range(segs + 1):
        t = i / float(segs)
        r = trunk_r * (1.4 - 0.8 * t)
        c = Vector((0, 0, trunk_h * t)) + lean * (t * t)
        if prev is not None:
            mid = (prev + c) * 0.5
            seg_h = (c - prev).length + 0.02
            parts.append(set_vcol(
                cyl(max(r, 0.045), seg_h, mid, "Wood", verts=6), "Wood"))
        prev = c

    # 粗枝：伸进树冠，让树冠不是"浮在树干上"
    for i in range(3):
        a = rng.uniform(0, math.tau)
        parts.append(set_vcol(
            cyl(0.075, height * 0.22,
                (math.cos(a) * 0.35, math.sin(a) * 0.35, trunk_h * 0.9),
                "Wood", verts=5,
                rot=(math.radians(rng.uniform(38, 58)), 0, a)), "Wood"))

    # 树冠：叶簇撒在一个压扁的椭球壳上，越靠上越亮
    crown_r = height * crown_ratio
    crown_h = height - trunk_h * 0.82
    base_z = trunk_h * 0.82

    # 树冠的核：撑起体积，否则外圈叶簇之间全是洞，树看着是"一把撒开的碎叶"
    for i in range(3):
        parts.append(_blob_object(
            rng, crown_r * rng.uniform(0.60, 0.74),
            (rng.uniform(-0.22, 0.22) * crown_r,
             rng.uniform(-0.22, 0.22) * crown_r,
             base_z + crown_h * rng.uniform(0.30, 0.62)),
            palette[min(len(palette) - 1, 1)], squash=0.9))

    for i in range(clumps):
        u = rng.uniform(-0.85, 1.0)
        zt = (u + 0.85) / 1.85
        rr = math.sqrt(max(0.0, 1.0 - (zt * 2.0 - 1.0) ** 2))
        a = rng.uniform(0.0, math.tau)
        p = (math.cos(a) * rr * crown_r * rng.uniform(0.55, 0.95),
             math.sin(a) * rr * crown_r * rng.uniform(0.55, 0.95),
             base_z + zt * crown_h * rng.uniform(0.75, 1.0))
        idx = min(len(palette) - 1,
                  int(zt * len(palette) + rng.uniform(-0.5, 0.6)))
        parts.append(_blob_object(rng, crown_r * rng.uniform(0.21, 0.34), p,
                                  palette[max(0, idx)], squash=0.85))

    o = join_as(parts, name)
    finalize(o, loc, smooth_angle=50.0)
    return o


# ------------------------------------------------------------------ 导出 --
def export(path, label):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    # export_vertex_color 默认是 "MATERIAL"：只有材质引用了颜色属性才导出。
    # 叶簇的颜色全靠顶点色承载，漏掉就是一片白 —— 必须显式改成 "ACTIVE"。
    kw = dict(filepath=path, export_format="GLB", use_selection=False,
              export_apply=True, export_yup=True)
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)
    total = sum(tris(o) for o in bpy.context.scene.objects if o.type == "MESH")
    n = len([o for o in bpy.context.scene.objects if o.type == "MESH"])
    print("[assets] %-10s %d objects, %d tris -> %s (%.1f KB)"
          % (label, n, total, os.path.basename(path),
             os.path.getsize(path) / 1024.0), flush=True)


def build_buildings(out_dir):
    """每栋单独导出一个 GLB。
    合成一个文件的话，Godot 侧实例化一次就会把全部三栋都带进来 ——
    摆三栋房子会变成场景里有九栋。资产"组"（石头、树）走 MultiMesh 按变体取用，
    那种才适合合在一个文件里。"""
    specs = [
        ("house_small", dict(w=4.4, d=3.8, wall_h=2.8, roof_h=1.7)),
        ("house_large", dict(w=6.8, d=4.8, wall_h=3.4, roof_h=2.1, porch=True)),
        ("house_tall", dict(w=5.0, d=4.2, wall_h=3.0, roof_h=1.9, storeys=2)),
    ]
    for name, kw in specs:
        clear()
        building(name, kw.pop("w"), kw.pop("d"), kw.pop("wall_h"), (0, 0, 0), **kw)
        export(os.path.join(out_dir, name + ".glb"), name)


def build_trees(out_dir):
    clear()
    specs = [
        ("tree_a", 5.6, 34, ("LeafDark", "LeafMid", "LeafLight")),
        ("tree_b", 6.9, 42, ("LeafDark", "LeafDark", "LeafMid")),
        ("tree_c", 4.5, 28, ("LeafMid", "LeafLight", "LeafLight")),
        ("tree_d", 5.2, 30, ("LeafRust", "LeafDry", "LeafLight")),
    ]
    for i, (nm, h, c, pal) in enumerate(specs):
        tree(nm, (i * 7.0 - 10.5, 0, 0), height=h, seed=1 + i * 17,
             clumps=c, palette=pal)
    export(os.path.join(out_dir, "trees.glb"), "trees")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--only", default="buildings,trees,rocks,bushes")
    args = ap.parse_args(argv)
    only = [s.strip() for s in args.only.split(",")]
    if "bushes" in only:
        build_bushes(args.out_dir)
    if "rocks" in only:
        build_rocks(args.out_dir)
    if "buildings" in only:
        build_buildings(args.out_dir)
    if "trees" in only:
        build_trees(args.out_dir)


main()
