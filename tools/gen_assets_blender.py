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
from mathutils import Quaternion, Vector

# ------------------------------------------------------------------ 调色板 --
# 与 M2 在 Godot 侧使用的颜色保持一致，避免资产和现有场景割裂。
#
# 注意：下面的数值是 **sRGB**，因为它们抄自 Godot 的 StandardMaterial3D.albedo_color，
# 那边按 sRGB 解释。而 Blender 的 Principled BSDF Base Color 是**线性**的 ——
# 同样的数字直接搬过去，整体会被明显提亮（0.318 当 sRGB 是深橄榄，
# 当线性是浅卡其）。写入 Blender 前必须转换。
PALETTE = {
    "Wall":      (0.352, 0.336, 0.302),
    "WallDark":  (0.275, 0.260, 0.232),
    "Thatch":    (0.160, 0.131, 0.069),
    "ThatchDark": (0.116, 0.094, 0.050),
    "Wood":      (0.286, 0.192, 0.110),
    "WoodLight": (0.355, 0.255, 0.146),
    "Stone":     (0.216, 0.199, 0.196),
    "StoneWarm": (0.252, 0.219, 0.183),
    "StoneCool": (0.196, 0.192, 0.199),
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
    # 同上：颜色由顶点色承载，这个材质只是载体
    "Surface":   (1.0, 1.0, 1.0),
}

# 桥的尺寸。**tools/gen_greybox.py 的 DECK_L / DECK_W 必须和这里一致** ——
# 桥墩、拉索、以及和房屋的间距检查都按它算。
BRIDGE_L = 16.0
BRIDGE_W = 8.4
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
def bake_materials_to_vcol(obj, material="Surface", coarse=()):
    """把每个材质槽的颜色烘进顶点色，然后合并成单一材质。

    房屋原来是 8 个材质槽 = 8 次 draw call，而且因为它是 GLB 实例，
    Godot 侧挂不了 material_override（一挂就把 8 个部件冲成同一个颜色），
    于是生成器里那套 MAT["wall"]/MAT["roof"] 对房屋**根本没生效** ——
    屋顶墙面一直是 Blender 里的纯色。

    烘进顶点色之后：一个材质、一次 draw call，Godot 侧可以整体挂
    prop.gdshader，颜色照旧、还多出表面细节和法线扰动。

    COLOR.a 给着色器当细节尺度的选择器：coarse 里列出的材质名 -> 1（木头，
    纹理粗），其余 -> 0（石头/灰泥，纹理细）。"""
    me = obj.data
    cols = []
    for m in me.materials:
        c = (1.0, 1.0, 1.0)
        if m is not None and m.use_nodes:
            for nd in m.node_tree.nodes:
                if nd.type == "BSDF_PRINCIPLED":
                    v = nd.inputs["Base Color"].default_value
                    c = (v[0], v[1], v[2])       # Principled 的 Base Color 是线性的
                    break
        nm = m.name if m is not None else ""
        cols.append((c[0], c[1], c[2],
                     1.0 if any(k in nm for k in coarse) else 0.0))

    attr = me.color_attributes.get("Color")
    if attr is None:
        attr = me.color_attributes.new(name="Color", type="BYTE_COLOR",
                                       domain="CORNER")
    for p in me.polygons:
        cc = cols[p.material_index] if p.material_index < len(cols) else (1, 1, 1, 0)
        for li in p.loop_indices:
            attr.data[li].color = cc

    me.materials.clear()
    me.materials.append(mat(material))
    return obj


def building(name, w, d, wall_h, loc, roof_h=1.9, eaves=0.45, storeys=1,
             chimney=True, porch=False):
    """M2 的短板是建筑"还是纯色盒子 + 三棱柱"。真正让房子读起来像房子的
    是这几样，每一样都只花几十个面：

      - 石头地基（把墙和地面分开，避免"盒子插在草里"）
      - 屋顶出檐 + 屋脊（纯三棱柱没有厚度，一眼假）
      - 门和窗的凹陷（深色内凹，不是贴在墙上的色块）
      - 转角立柱 / 横梁（给墙面加水平分段，破掉大色块）
    """
    import random
    rng = random.Random(hash(name) & 0xffff)
    parts = []
    base_h = 0.28
    # 地基改成一圈石块：整块板的上沿也是一条直线
    parts.append(box((w + 0.24, d + 0.24, base_h * 0.8),
                     (0, 0, base_h * 0.4), "Stone"))
    for sy in (-1, 1):
        n_s = max(3, int(w / 0.55))
        for i in range(n_s):
            x = -w / 2 + (i + 0.5) * w / n_s
            parts.append(box((w / n_s * rng.uniform(0.8, 0.96),
                              0.20, base_h * rng.uniform(0.85, 1.25)),
                             (x, sy * (d / 2 + 0.06),
                              base_h * 0.5 * rng.uniform(0.9, 1.1)),
                             rng.choice(("Stone", "WallDark"))))

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

    # 屋顶。
    #
    # 两个老问题都出在这里：**边界太直**（屋脊和檐口都是一条数学直线）、
    # **贴图太均匀**（各向同性噪声，而茅草的读法来自一束束草秆的方向性）。
    #
    # 形状上的解法是把屋脊和檐口拆成**一件件**：
    # 屋脊是一捆捆压顶草，檐口是一排草头。每件抖大小、角度、色调，
    # 轮廓就自然不直了 —— 这和树叶、石头是同一个道理，不是调参能调出来的。
    rw, rd = roof_w + eaves * 2, roof_d + eaves * 2
    parts.append(wedge((rw, rd, roof_h), (0, 0, roof_base_z), "Thatch"))

    slope = math.atan2(roof_h, rw * 0.5)

    # 檐口：一排草头，逐个抖出挑长度和厚度。参考图的檐口是又厚又毛的一条，
    # 不是一条锐利的边
    n_eave = max(4, int(rd / 0.42))
    for i in range(n_eave):
        y = -rd / 2 + (i + 0.5) * rd / n_eave
        for sx in (-1, 1):
            out = rng.uniform(0.06, 0.20)
            th = rng.uniform(0.16, 0.26)
            parts.append(box((0.24 + out, rd / n_eave * rng.uniform(0.82, 0.98),
                              th),
                             (sx * (rw / 2 - 0.02 + out * 0.4), y,
                              roof_base_z + rng.uniform(-0.01, 0.04)),
                             rng.choice(("Thatch", "ThatchDark")),
                             rot=(0, sx * slope * rng.uniform(0.5, 0.8), 0)))

    # 屋脊：一捆捆压顶草，还带一点点下垂（老屋脊都不是水平的）
    n_ridge = max(4, int(rd / 0.5))
    for i in range(n_ridge):
        t = (i + 0.5) / n_ridge
        y = -rd / 2 + t * rd
        sag = math.sin(t * math.pi) * 0.045          # 中间略沉
        parts.append(box((rng.uniform(0.30, 0.42),
                          rd / n_ridge * rng.uniform(0.80, 0.96),
                          rng.uniform(0.20, 0.30)),
                         (rng.uniform(-0.04, 0.04), y,
                          roof_base_z + roof_h - 0.04 - sag),
                         rng.choice(("ThatchDark", "Thatch")),
                         rot=(0, 0, rng.uniform(-0.10, 0.10))))

    # 山墙边的压条：把两端的斜边也打碎
    for sy in (-1, 1):
        n_g = 5
        for i in range(n_g):
            t = (i + 0.5) / n_g
            parts.append(box((0.30, 0.16, 0.18),
                             ((0.5 - t) * rw * 0.9, sy * (rd / 2 - 0.02),
                              roof_base_z + roof_h * t * 0.92 + 0.02),
                             "ThatchDark",
                             rot=(0, -math.copysign(slope, 0.5 - t), 0)))

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

    # 全件倒角 + 铺 UV。
    # 倒角解决"边界太直"里那条**每个面都是 90° 硬棱**；
    # UV 解决"贴图太均匀"—— 有了 UV 才能用有方向性的茅草/灰泥贴图，
    # 世界坐标程序化噪声只有各向同性斑点，做不出草秆的方向。
    # 屋面用 long_axis_u=False：茅草条纹要顺着坡走，而屋面长边是沿屋脊的。
    for o in parts:
        m = o.data.materials[0].name if o.data.materials else ""
        roofish = m.startswith("Thatch")
        uv_planar(o, uv_scale=0.55 if roofish else 0.42,
                  offset=(rng.uniform(0.0, 4.0), rng.uniform(0.0, 4.0)),
                  long_axis_u=not roofish)
        bevel_edges(o, width=0.022)

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
    # 点数是这里唯一真正决定"棱角软硬"的参数。
    # 14-17 个点的凸包只有二十来个面，轮廓上必然出现几条很长的直边。
    # 但也不能一味加：点太多会退回圆润的多面体（第一版位移球体的老问题）。
    # 22-28 是这个机位下的平衡点。
    "chunky":   ((1.00, 0.95, 0.68), 26, 0.0),
    "slab":     ((1.15, 1.30, 0.34), 24, 0.0),
    "column":   ((0.72, 0.78, 1.05), 23, 0.20),
    "wedge":    ((1.08, 0.76, 0.58), 23, -0.20),
    "block":    ((0.95, 0.90, 0.78), 22, 0.0),
    "pebble":   ((1.00, 0.92, 0.52), 14, 0.0),
}


def uv_planar(obj, uv_scale=0.30, offset=(0.0, 0.0), long_axis_u=True):
    """按局部坐标做平面投影 UV，纹理**沿物件的长轴**跑。

    这是"外部贴图"这条路的入口：程序生成的网格默认没有可用的 UV
    （bmesh 建的完全没有；primitive 的每个面都铺满 0..1，尺度不一致），
    有了这一步，assets/textures/ 下的普通 PNG 就能直接贴上来，
    而且是**按米**铺的 —— 大小不同的木件纹理密度一致。

    每个面按法线的主轴投影到另外两轴；两轴里**较长的那个给 U**，
    于是木纹自然顺着板子、梁、立柱的长边走，不用逐件指定方向。
    long_axis_u=False 反过来（短边给 U）—— 屋面要用它：
    茅草的条纹应该**顺着坡**走，而屋面的长边是沿屋脊的。
    offset 给每件一个随机位移，否则所有木件的纹理完全一样。
    """
    me = obj.data
    sc = obj.scale
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uvl = me.uv_layers.active.data
    # 尺寸要从**网格包围盒**算，不能直接用 obj.scale：
    # primitive_cube_add 建的网格是 ±0.5 的单位立方体、尺寸在 scale 里，
    # 而 bmesh / from_pydata 建的（wedge、凸包）坐标已经是米、scale 是 1。
    # 只看 scale 的话，后者会被当成 1x1x1，长边判断随机。
    co_all = [v.co for v in me.vertices]
    size = [(max(c[i] for c in co_all) - min(c[i] for c in co_all)) * sc[i]
            for i in range(3)]
    for poly in me.polygons:
        n = poly.normal
        axis = max(range(3), key=lambda i: abs(n[i]))
        a, b = [i for i in range(3) if i != axis]
        want_long_u = long_axis_u
        if (size[a] < size[b]) == want_long_u:
            a, b = b, a
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uvl[li].uv = ((co[a] * sc[a]) * uv_scale + offset[0],
                          (co[b] * sc[b]) * uv_scale + offset[1])
    return obj


def bevel_edges(obj, width=0.03, segments=1, angle=25.0):
    """给硬表面加倒角。

    这是"过渡"层的活，着色器做不了 —— 倒角改变的是**侧影和受光**：
    90° 硬棱在任何光照下都是一条突变线，倒角面则会随朝向渐变。
    参考图里的木结构没有一条razor edge。

    宽度按物件尺寸给：桥板 0.02、立柱 0.03、大梁 0.04。
    给得太大在这个机位（29 px/m）下会把细木件啃圆。
    """
    bpy.context.view_layer.objects.active = obj
    m = obj.modifiers.new("bevel", "BEVEL")
    m.width = width
    m.segments = segments
    m.limit_method = "ANGLE"
    m.angle_limit = math.radians(angle)
    m.harden_normals = False
    bpy.ops.object.modifier_apply(modifier=m.name)
    return obj


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
    # UV 是"石头太光"的前提：MultiMesh 上挂的 StandardMaterial3D 法线贴图
    # 在没有 UV 的网格上静默失效（没 UV 就没切线）。铺了 UV 之后
    # 改走 prop.gdshader，贴图和法线扰动都在着色器里算，不依赖切线。
    uv_planar(o, uv_scale=0.85,
              offset=(rng.uniform(0.0, 4.0), rng.uniform(0.0, 4.0)))
    base = PALETTE[rng.choice(("Stone", "StoneWarm", "StoneCool"))]
    k = rng.uniform(0.82, 1.18)
    set_vcol(o, tuple(min(1.0, c * k) for c in base),
             material="Surface", alpha=0.0)
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


# ------------------------------------------------------ 叶片贴片 / 灌木 --
# 参考图的树冠是**细枝干 + 一片片独立的叶子贴片**，中间透光、能看见底下的影子。
#
# 之前两版都是实体几何（先是光滑球，后是凸包叶簇堆积），无论怎么调都是"一坨"——
# 实体不可能透光，这是原理性的，不是参数问题。
#
# 现在：枝干是细圆柱（真几何，它需要明确的走向），叶子是挂在枝头的四边形，
# 采样 assets/environment/leaf_atlas.png 做 alpha 裁剪。
# 用 alpha 裁剪而不是 alpha 混合：走不透明通道，不需要排序，阴影自动正确，
# 也没有透明层的填充开销（§15 点名的 overdraw 风险主要来自混合）。

ATLAS_GRID = 2


def set_vcol(obj, colour_name, material="Foliage", alpha=0.0):
    """colour_name 可以是调色板里的名字，也可以直接给 (r,g,b) sRGB 三元组。"""
    """把颜色烘进顶点色，并统一材质。

    统一材质有两个作用：合并后只剩一个 surface（一次 draw call），
    以及 Godot 侧可以用一个 material_override 挂着色器而不冲掉任何东西。
    树干也必须走这条路 —— 否则 material_override 会把它一起冲成白色。

    **顶点色的 alpha 是"这是不是叶片贴片"的标志**：1 = 采样叶片图集并做
    alpha 裁剪，0 = 实体木头，强制不透明。合并成一个网格之后就靠它区分。"""
    me = obj.data
    src = (PALETTE[colour_name] if isinstance(colour_name, str)
           else colour_name)
    c = [srgb_to_linear(x) for x in src]
    attr = me.color_attributes.get("Color")
    if attr is None:
        attr = me.color_attributes.new(name="Color", type="BYTE_COLOR",
                                       domain="CORNER")
    for i in range(len(attr.data)):
        attr.data[i].color = (c[0], c[1], c[2], alpha)
    me.materials.clear()
    me.materials.append(mat(material))
    return obj


def leaf_card(rng, size, loc, colour_name, tile=None, tilt_max=1.0):
    """一张叶片贴片：带图集 UV 的四边形。

    朝向 = 随机 yaw + 从**水平面**起算的随机倾角。60° 俯视下水平的贴片正好
    看得清，完全竖直的会退化成一条线 —— 所以倾角从水平开始加，不是从竖直。"""
    bm = bmesh.new()
    h = size * 0.5
    vs = [bm.verts.new((-h, -h, 0.0)), bm.verts.new((h, -h, 0.0)),
          bm.verts.new((h, h, 0.0)), bm.verts.new((-h, h, 0.0))]
    f = bm.faces.new(vs)
    uvl = bm.loops.layers.uv.new("UVMap")
    k = rng.randrange(ATLAS_GRID * ATLAS_GRID) if tile is None else tile
    u0 = (k % ATLAS_GRID) / float(ATLAS_GRID)
    v0 = (k // ATLAS_GRID) / float(ATLAS_GRID)
    d = 1.0 / ATLAS_GRID
    # 随机翻转 UV：四张图能长出八种朝向，重复感更弱
    fu = rng.random() < 0.5
    fv = rng.random() < 0.5
    for lp, (cu, cv) in zip(f.loops, [(0, 0), (1, 0), (1, 1), (0, 1)]):
        uu = 1 - cu if fu else cu
        vv = 1 - cv if fv else cv
        lp[uvl].uv = (u0 + uu * d, v0 + vv * d)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new("card")
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new("card", me)
    bpy.context.collection.objects.link(o)
    o.location = loc
    o.rotation_euler = (rng.uniform(0.0, 1.0) * tilt_max, 0.0,
                        rng.uniform(0.0, math.tau))
    return set_vcol(o, colour_name, alpha=1.0)


def twig(rng, r0, length, base, direction, colour="Wood"):
    """一根细枝：从 base 沿 direction 伸出。返回 (对象, 末端位置)。"""
    d = Vector(direction).normalized()
    tip = Vector(base) + d * length
    mid = (Vector(base) + tip) * 0.5
    up = Vector((0.0, 0.0, 1.0))        # 圆柱默认沿 +Z，转到 d
    axis = up.cross(d)
    ang = up.angle(d)
    if axis.length < 1e-6:
        axis = Vector((1.0, 0.0, 0.0))
        ang = 0.0 if d.z > 0 else math.pi
    e = Quaternion(axis.normalized(), ang).to_euler()
    o = cyl(r0, length, mid, colour, verts=4, rot=(e.x, e.y, e.z))
    return set_vcol(o, colour, alpha=0.0), tip


def bush(name, seed, loc=(0, 0, 0), radius=0.95, height=0.85, cards=14,
         palette=("LeafDark", "LeafMid", "LeafLight"), card_scale=0.46):
    """一丛灌木：几根从根部张开的细枝 + 挂在枝头的叶片贴片。"""
    import random
    rng = random.Random(seed)
    parts = []

    stems = max(4, cards // 6)
    tips = []
    for i in range(stems):
        a = math.tau * i / stems + rng.uniform(-0.4, 0.4)
        d = (math.cos(a) * rng.uniform(0.55, 1.05),
             math.sin(a) * rng.uniform(0.55, 1.05), 1.0)
        o, tip = twig(rng, 0.022, height * rng.uniform(0.60, 0.85),
                      (0.0, 0.0, 0.0), d)
        parts.append(o)
        tips.append(tip)

    for i in range(cards):
        t = tips[i % len(tips)]
        p = (t.x + rng.uniform(-0.22, 0.22) * radius,
             t.y + rng.uniform(-0.22, 0.22) * radius,
             max(height * 0.18, t.z + rng.uniform(-0.30, 0.18) * height))
        zt = min(1.0, max(0.0, p[2] / max(height, 0.01)))
        idx = min(len(palette) - 1, int(zt * len(palette) + rng.uniform(-0.4, 0.6)))
        parts.append(leaf_card(rng, radius * card_scale * rng.uniform(0.75, 1.15),
                               p, palette[max(0, idx)], tilt_max=1.0))

    o = join_as(parts, name)
    finalize(o, loc)
    return o


def build_bushes(out_dir):
    """多个色系的变体：参考图里同一片地上深绿、黄绿、红褐、紫花都有，
    颜色差异比形状差异更能打破重复感。"""
    clear()
    specs = [
        ("bush_green", ("LeafDark", "LeafMid", "LeafLight"), 0.95, 0.80, 62),
        ("bush_dark", ("LeafDark", "LeafDark", "LeafMid"), 1.10, 0.70, 72),
        ("bush_yellow", ("LeafMid", "LeafLight", "LeafLight"), 0.85, 0.90, 58),
        ("bush_rust", ("LeafRust", "LeafDry", "LeafLight"), 0.90, 0.75, 58),
        ("bush_flower", ("LeafDark", "LeafMid", "Flower"), 0.80, 0.85, 62),
        ("bush_small", ("LeafDark", "LeafMid", "LeafMid"), 0.55, 0.45, 28),
    ]
    for i, (nm, pal, r, h, c) in enumerate(specs):
        bush(nm, seed=900 + i * 41, loc=(i * 3.0 - 7.5, 0, 0),
             radius=r, height=h, cards=c, palette=pal)
    export(os.path.join(out_dir, "bushes.glb"), "bushes")


# -------------------------------------------------------------------- 树 --
def tree(name, loc, height=5.4, trunk_r=0.11, seed=0, cards=30,
         palette=("LeafDark", "LeafMid", "LeafLight"), crown_ratio=0.34):
    """树 = 细树干 + 二级分叉的枝 + 挂在枝头的叶片贴片。

    树干比之前细了近一半：参考图里的树干在这个机位下只有两三个像素宽，
    原来 0.17 m 的锥形树干太抢眼，看着像电线杆。"""
    import random
    rng = random.Random(seed)
    parts = []

    trunk_h = height * 0.46
    lean = Vector((rng.uniform(-0.18, 0.18), rng.uniform(-0.18, 0.18), 0.0))
    segs = 3
    prev = Vector((0.0, 0.0, 0.0))
    for i in range(1, segs + 1):
        t = i / float(segs)
        r = trunk_r * (1.35 - 0.75 * t)
        c = Vector((0.0, 0.0, trunk_h * t)) + lean * (t * t)
        mid = (prev + c) * 0.5
        d = c - prev
        up = Vector((0.0, 0.0, 1.0))
        ax = up.cross(d.normalized())
        ang = up.angle(d.normalized())
        if ax.length < 1e-6:
            ax, ang = Vector((1.0, 0.0, 0.0)), 0.0
        e = Quaternion(ax.normalized(), ang).to_euler()
        parts.append(set_vcol(
            cyl(max(r, 0.035), d.length + 0.02, mid, "Wood", verts=5,
                rot=(e.x, e.y, e.z)), "Wood", alpha=0.0))
        prev = c

    # 一级枝 -> 二级枝，贴片挂在二级枝末端。这样树冠是"从中心张开"的结构，
    # 而不是一团悬空的叶子
    crown_r = height * crown_ratio
    tips = []
    primaries = 6
    for i in range(primaries):
        a = math.tau * i / primaries + rng.uniform(-0.35, 0.35)
        d = (math.cos(a) * rng.uniform(0.5, 0.95),
             math.sin(a) * rng.uniform(0.5, 0.95), rng.uniform(0.7, 1.25))
        o, tip = twig(rng, trunk_r * 0.45, crown_r * rng.uniform(0.55, 0.85),
                      prev, d)
        parts.append(o)
        tips.append(prev + (tip - prev) * rng.uniform(0.45, 0.75))
        for j in range(3):
            a2 = a + rng.uniform(-1.1, 1.1)
            d2 = (math.cos(a2) * rng.uniform(0.5, 1.1),
                  math.sin(a2) * rng.uniform(0.5, 1.1), rng.uniform(0.2, 0.9))
            o2, tip2 = twig(rng, trunk_r * 0.26,
                            crown_r * rng.uniform(0.28, 0.5), tip, d2)
            parts.append(o2)
            tips.append(tip2)

    top = max(t.z for t in tips)
    bot = min(t.z for t in tips)
    for i in range(cards):
        t = tips[i % len(tips)]
        p = (t.x + rng.uniform(-0.28, 0.28) * crown_r,
             t.y + rng.uniform(-0.28, 0.28) * crown_r,
             t.z + rng.uniform(-0.35, 0.22) * crown_r)
        zt = min(1.0, max(0.0, (p[2] - bot) / max(top - bot, 0.01)))
        idx = min(len(palette) - 1,
                  int(zt * len(palette) + rng.uniform(-0.4, 0.6)))
        parts.append(leaf_card(rng, crown_r * rng.uniform(0.36, 0.58), p,
                               palette[max(0, idx)], tilt_max=1.05))

    o = join_as(parts, name)
    finalize(o, loc)
    return o


# ------------------------------------------------------------------ 桥 --
# 参考图的桥：**横铺的板**（每块长短色泽都不同、有缝）、侧面的 A 形立柱和斜撑、
# 通长的扶手、板下的横梁。所有木件都是倒角的，没有一条 razor edge。
#
# 之前用 CSG 盒子在场景生成器里拼，出来是"几块对齐的平板"：
# 板是一整块、边是 90° 硬棱、颜色完全一致。这三件事都得在几何层解决。
#
# 局部坐标：X 沿桥、Y 横跨、Z 向上（Blender Z-up），原点在桥面中心的底面。

# 亮度按实测校准：目标图里**避开爆炸照亮**的那几段桥面亮度是 111-118，
# 靠近火焰那段是 176.8 —— 拿后者当参考会把整座桥调亮 50%。
BRIDGE_WOOD = ((0.243, 0.163, 0.094), (0.299, 0.202, 0.115),
               (0.207, 0.139, 0.083), (0.343, 0.247, 0.139),
               (0.270, 0.182, 0.104))


def _wood(rng, jitter=0.10):
    """从木色里挑一个再抖一下。逐板色差是参考图最明显的特征之一 ——
    整片同色的甲板一眼是程序生成的。"""
    c = BRIDGE_WOOD[rng.randrange(len(BRIDGE_WOOD))]
    k = 1.0 + rng.uniform(-jitter, jitter)
    return tuple(min(1.0, v * k) for v in c)


def bridge(name, length=16.0, width=8.4, seed=77, rail_h=1.15):
    import random
    rng = random.Random(seed)
    parts = []

    def add(o, colour, bw=0.03, coarse=1.0):
        # 顺序要紧：先铺 UV 再倒角。倒角会新增面，
        # 那些面从相邻面插值拿到 UV；反过来做的话新面没有 UV。
        uv_planar(o, uv_scale=0.30,
                  offset=(rng.uniform(0.0, 4.0), rng.uniform(0.0, 4.0)))
        bevel_edges(o, width=bw)
        return parts.append(set_vcol(o, colour, material="Surface",
                                     alpha=coarse))

    # 纵梁：两根通长的大梁，板铺在它上面
    for sy in (-1.0, 1.0):
        y = sy * (width * 0.5 - 0.45)
        add(box((length, 0.36, 0.30), (0.0, y, -0.15), "Wood"),
            (0.243, 0.163, 0.098), bw=0.04)

    # 板下横梁
    nbeam = max(3, int(length / 2.4))
    for i in range(nbeam):
        x = -length * 0.5 + (i + 0.5) * length / nbeam
        add(box((0.28, width - 0.2, 0.26), (x, 0.0, -0.18), "Wood"),
            (0.226, 0.150, 0.090), bw=0.03)

    # 桥面板：横铺，逐块抖长度 / 厚度 / 转角 / 颜色，留缝
    pitch = 0.52
    nplank = int(length / pitch)
    for i in range(nplank):
        x = -length * 0.5 + (i + 0.5) * length / nplank
        w_pl = pitch * rng.uniform(0.76, 0.90)          # 剩下的是板缝
        ln = width * rng.uniform(0.94, 1.02)
        th = rng.uniform(0.085, 0.125)
        o = box((w_pl, ln, th),
                (x + rng.uniform(-0.02, 0.02), rng.uniform(-0.10, 0.10),
                 th * 0.5 + 0.002),
                "Wood", rot=(0.0, 0.0, rng.uniform(-0.012, 0.012)))
        add(o, _wood(rng), bw=0.02)

    # 侧栏：立柱 + 通长扶手 + 斜撑
    npost = max(4, int(length / 2.6))
    for sy in (-1.0, 1.0):
        y = sy * (width * 0.5 - 0.18)
        prev_x = None
        for i in range(npost + 1):
            x = -length * 0.5 + i * length / npost
            add(box((0.22, 0.22, rail_h), (x, y, rail_h * 0.5), "Wood"),
                _wood(rng, 0.06), bw=0.03)
            if prev_x is not None:
                # 斜撑：交替方向，规则的同向斜撑看着像栅栏
                dx = x - prev_x
                ln = math.hypot(dx, rail_h * 0.72)
                ang = math.atan2(rail_h * 0.72, dx) * (1 if i % 2 else -1)
                add(box((ln, 0.13, 0.13),
                        (prev_x + dx * 0.5, y, rail_h * 0.46), "Wood",
                        rot=(0.0, -ang, 0.0)), _wood(rng, 0.06), bw=0.02)
            prev_x = x
        add(box((length, 0.18, 0.16), (0.0, y, rail_h + 0.02), "Wood"),
            (0.404, 0.290, 0.163), bw=0.03)

    o = join_as(parts, name)
    finalize(o, (0.0, 0.0, 0.0))
    return o


def build_bridge(out_dir):
    clear()
    bridge("bridge", length=BRIDGE_L, width=BRIDGE_W)
    export(os.path.join(out_dir, "bridge.glb"), "bridge")


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
        o = building(name, kw.pop("w"), kw.pop("d"), kw.pop("wall_h"),
                     (0, 0, 0), **kw)
        bake_materials_to_vcol(o, coarse=("Wood", "Thatch"))
        export(os.path.join(out_dir, name + ".glb"), name)


def build_trees(out_dir):
    clear()
    specs = [
        ("tree_a", 5.6, 150, ("LeafDark", "LeafMid", "LeafLight")),
        ("tree_b", 6.9, 190, ("LeafDark", "LeafDark", "LeafMid")),
        ("tree_c", 4.5, 120, ("LeafMid", "LeafLight", "LeafLight")),
        ("tree_d", 5.2, 135, ("LeafRust", "LeafDry", "LeafLight")),
    ]
    for i, (nm, h, c, pal) in enumerate(specs):
        tree(nm, (i * 7.0 - 10.5, 0, 0), height=h, seed=1 + i * 17,
             cards=c, palette=pal)
    export(os.path.join(out_dir, "trees.glb"), "trees")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--only",
                default="buildings,trees,rocks,bushes,bridge")
    args = ap.parse_args(argv)
    only = [s.strip() for s in args.only.split(",")]
    if "bridge" in only:
        build_bridge(args.out_dir)
    if "bushes" in only:
        build_bushes(args.out_dir)
    if "rocks" in only:
        build_rocks(args.out_dir)
    if "buildings" in only:
        build_buildings(args.out_dir)
    if "trees" in only:
        build_trees(args.out_dir)


main()
