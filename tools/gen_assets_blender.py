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
    "Stone":     (0.298, 0.278, 0.255),
    "Metal":     (0.298, 0.310, 0.337),
    "Dark":      (0.102, 0.086, 0.075),
    "LeafA":     (0.180, 0.271, 0.098),
    "LeafB":     (0.243, 0.337, 0.129),
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


def finalize(obj, loc=(0, 0, 0)):
    """平面着色 + 原点落到底面中心 + 摆到指定位置。"""
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


# -------------------------------------------------------------------- 树 --
def tree(name, loc, height=5.4, trunk_r=0.17, canopy_layers=3, seed=0):
    """比 M2 的"两个球"多做的事：树干有锥度和弯曲、树冠是分层收拢的多面体、
    底层带几根粗枝。轮廓上立刻从"西兰花"变成"树"。"""
    import random
    rng = random.Random(seed)
    parts = []

    segs = 4
    trunk_h = height * 0.42
    lean = Vector((rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2), 0.0))
    prev = None
    for i in range(segs + 1):
        t = i / float(segs)
        r = trunk_r * (1.35 - 0.75 * t)
        c = Vector((0, 0, trunk_h * t)) + lean * (t * t)
        if prev is not None:
            mid = (prev[0] + c) * 0.5
            seg_h = (c - prev[0]).length + 0.02
            parts.append(cyl(max(r, 0.04), seg_h, mid, "Wood", verts=6))
        prev = (c, r)

    # 粗枝
    for i in range(3):
        a = rng.uniform(0, math.tau)
        parts.append(cyl(0.07, 0.9,
                         (math.cos(a) * 0.3, math.sin(a) * 0.3, trunk_h * 0.82),
                         "Wood", verts=5,
                         rot=(math.radians(rng.uniform(35, 55)), 0, a)))

    # 树冠：分层收拢，每层是低面数多面体而不是球
    base_z = trunk_h * 0.86
    for i in range(canopy_layers):
        t = i / float(max(canopy_layers - 1, 1))
        r = (height * 0.30) * (1.0 - 0.42 * t)
        z = base_z + (height - base_z) * (0.18 + 0.62 * t)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=r,
                                              location=(0, 0, z))
        o = bpy.context.active_object
        o.scale = (1.0 + rng.uniform(-0.12, 0.12),
                   1.0 + rng.uniform(-0.12, 0.12),
                   0.66 + rng.uniform(-0.08, 0.08))
        o.rotation_euler = (0, 0, rng.uniform(0, math.tau))
        o.data.materials.append(mat("LeafA" if i % 2 == 0 else "LeafB"))
        parts.append(o)

    o = join_as(parts, name)
    finalize(o, loc)
    return o


# ------------------------------------------------------------------ 导出 --
def export(path, label):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB",
                              use_selection=False, export_apply=True,
                              export_yup=True)
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
    tree("tree_a", (-7, 0, 0), height=5.6, canopy_layers=3, seed=1)
    tree("tree_b", (0, 0, 0), height=6.8, canopy_layers=4, seed=2)
    tree("tree_c", (7, 0, 0), height=4.4, canopy_layers=3, seed=3)
    export(os.path.join(out_dir, "trees.glb"), "trees")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--only", default="buildings,trees")
    args = ap.parse_args(argv)
    only = [s.strip() for s in args.only.split(",")]
    if "buildings" in only:
        build_buildings(args.out_dir)
    if "trees" in only:
        build_trees(args.out_dir)


main()
