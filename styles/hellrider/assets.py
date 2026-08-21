# -*- coding: utf-8 -*-
"""风格 "hellrider" 的 Blender 资产：房屋、石头、树、灌木、桥。

    blender --background --factory-startup --python styles/hellrider/assets.py \\
        -- --out-dir assets/hellrider/environment [--only trees,rocks]

和 "gatling" 风格**方法完全相反**，这是有意的：

  gatling                     hellrider
  ------------------------    ------------------------
  凸包 22-26 点，倒角，平滑     凸包 8-10 点，**不倒角、不平滑**
  UV + 方向性贴图 + 三平面      **没有 UV，没有贴图**
  法线扰动做表面细节            **没有法线扰动**
  叶片 alpha 贴片              **实体低面球**
  屋脊/檐口拆成一件件破直边      直边就是风格的一部分，保留

实测依据：参考图 90% 的像素只用 10-20 种颜色，一半以上画面是纯色块
（对比 gatling 的 3%）。gatling 那一整套"表面细节"在这里必须全部关掉。

颜色全部烘进**顶点色**，单材质单 draw call；明暗台阶由
shaders/hr_flat.gdshader 的分档光照产生，不在资产里画。
"""
import argparse
import math
import os
import random
import sys
import zlib

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "tools"))

import bpy                                  # noqa: E402,F401
import bmesh                                # noqa: E402
from mathutils import Vector                # noqa: E402,F401

import blenderlib as bl                     # noqa: E402
from blenderlib import (box, cyl, ico, wedge, mat, clear, join_as, finalize,
                        tris, srgb_to_linear, export, set_vcol)  # noqa: E402


# 调色板：全部从参考图量出来的（见 styles/hellrider/reference/）。
# 地面的几档在 shaders/hr_ground.gdshader 里，这里只放道具。
PALETTE = {
    "Rock":       (0.720, 0.600, 0.450),
    "RockDark":   (0.560, 0.455, 0.335),
    "Leaf":       (0.480, 0.620, 0.380),
    "LeafDeep":   (0.360, 0.470, 0.290),
    "Trunk":      (0.420, 0.220, 0.200),
    "Wall":       (0.800, 0.740, 0.640),
    "WallDark":   (0.640, 0.580, 0.490),
    "RoofTeal":   (0.212, 0.600, 0.650),
    "RoofRed":    (0.660, 0.260, 0.220),
    "Wood":       (0.470, 0.320, 0.220),
    "WoodDark":   (0.330, 0.220, 0.155),
    "Dark":       (0.130, 0.110, 0.100),
    "Stone":      (0.560, 0.530, 0.500),
    "Surface":    (1.0, 1.0, 1.0),          # 顶点色的白色载体
}
bl.PALETTE.update(PALETTE)


def seeded(name):
    """确定性的随机源。**不要用 hash(str)** —— Python 3 每个进程加随机盐，
    资产每次导出都不一样，"改前/改后"的像素对比就失效了。"""
    return random.Random(zlib.crc32(name.encode("utf-8")) & 0xffffffff)


def vgrad(obj, amount=0.28):
    """把**垂直渐变**烘进顶点色：顶亮底暗。

    这是参考图和"纯平面着色"之间最大的一处差别，而且是量出来的：
    参考图里每个物体从上到下都在变暗（绿丛 120->92、树冠 120->89、
    石头 125->96），而单个面**内部**的 std 有 12-26；
    我们纯平面着色的面内 std 只有 0.45，死平。

    它不是贴图 —— 是烘在模型上的渐变。按整个物体的包围盒算，
    所以高的树和矮的灌木各自都有完整的过渡，不会因为世界高度不同而失真。
    在合并之后、finalize 之前做，渐变才覆盖整个物体而不是每个部件各来一遍。
    """
    me = obj.data
    zs = [v.co.z for v in me.vertices]
    lo, hi = min(zs), max(zs)
    span = max(hi - lo, 1e-4)
    attr = me.color_attributes.get("Color")
    if attr is None:
        return obj
    for poly in me.polygons:
        for li in poly.loop_indices:
            z = me.vertices[me.loops[li].vertex_index].co.z
            t = (z - lo) / span
            k = 1.0 - amount * (1.0 - t)
            c = attr.data[li].color
            attr.data[li].color = (c[0]*k, c[1]*k, c[2]*k, c[3])
    return obj


def flat(parts, name, loc=(0, 0, 0), grad=0.28):
    """合并 + 垂直渐变 + **平面着色**（smooth_angle=0）。

    面与面之间保持硬边（这个风格的骨架），面**内部**靠顶点色渐变产生过渡。
    两者不矛盾：硬边来自法线不平滑，过渡来自顶点色插值。
    """
    o = join_as(parts, name)
    if grad > 0.0:
        vgrad(o, grad)
    finalize(o, loc, smooth_angle=0.0)
    return o


def tint(obj, colour, rng=None, jitter=0.0):
    """把颜色烘进顶点色。jitter>0 时**逐面**抖一点点。

    参考图的树冠上，相邻面的绿色深浅不完全跟随光照方向 ——
    有一部分是美术手动给的面间差异。少量逐面抖动就能还原，
    比在着色器里加噪声干净（那会破坏纯色块的读法）。
    """
    base = PALETTE[colour] if isinstance(colour, str) else colour
    if jitter <= 0.0 or rng is None:
        return set_vcol(obj, base, material="Surface", alpha=0.0)
    me = obj.data
    attr = me.color_attributes.get("Color")
    if attr is None:
        attr = me.color_attributes.new(name="Color", type="BYTE_COLOR",
                                       domain="CORNER")
    for poly in me.polygons:
        k = 1.0 + rng.uniform(-jitter, jitter)
        c = [srgb_to_linear(min(1.0, v * k)) for v in base]
        for li in poly.loop_indices:
            attr.data[li].color = (c[0], c[1], c[2], 0.0)
    me.materials.clear()
    me.materials.append(mat("Surface"))
    return obj


# ------------------------------------------------------------------ 石头 --
# 参考图的石头是"一个盒子切几刀"：六到十个平面、硬边、没有倒角。
# gatling 风格用 22-26 个点是为了软化棱角；这里**恰恰相反**，
# 点太多就退回圆润的多面体，风格就没了。
ROCK_SHAPES = {
    "block":  ((1.00, 0.95, 0.80), 9),
    "slab":   ((1.25, 1.10, 0.45), 8),
    "spire":  ((0.75, 0.80, 1.25), 9),
    "chunk":  ((1.05, 0.90, 0.65), 10),
}


def rock(name, shape, seed, loc=(0, 0, 0)):
    rng = seeded(name)
    axes, n_pts = ROCK_SHAPES[shape]
    bm = bmesh.new()
    for _i in range(n_pts):
        z = rng.uniform(-1.0, 1.0)
        r = math.sqrt(max(0.0, 1.0 - z * z))
        a = rng.uniform(0.0, math.tau)
        # 半径抖动很小：参考图的石头是敦实的块体，不是碎片
        k = rng.uniform(0.90, 1.0)
        bm.verts.new((math.cos(a) * r * axes[0] * k,
                      math.sin(a) * r * axes[1] * k,
                      z * axes[2] * k))
    bmesh.ops.convex_hull(bm, input=bm.verts[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    tint(o, "Rock", rng, 0.05)
    vgrad(o, 0.26)
    finalize(o, loc, smooth_angle=0.0)
    return o


def build_rocks(out_dir):
    clear()
    i = 0
    for shape in ROCK_SHAPES:
        for k in range(2):
            rock("rock_%s_%d" % (shape, k), shape, seed=i,
                 loc=(i * 3.0 - 10.0, 0, 0))
            i += 1
    export(os.path.join(out_dir, "rocks.glb"), "rocks")

    clear()
    for k in range(4):
        o = rock("pebble_%d" % k, "chunk", seed=100 + k, loc=(k * 1.2 - 2.0, 0, 0))
        o.scale = (0.32, 0.32, 0.30)
    export(os.path.join(out_dir, "pebbles.glb"), "pebbles")


# -------------------------------------------------------------------- 树 --
def tree(name, loc=(0, 0, 0), height=4.6, crown=1.9, seed=0):
    """细杆 + 低面球树冠。参考图就是这么简单 —— 没有枝、没有贴片。"""
    rng = seeded(name)
    parts = []
    th = height * 0.42
    parts.append(tint(cyl(0.13, th, (0, 0, th * 0.5), "Trunk", verts=5),
                      "Trunk", rng, 0.04))
    cz = th + crown * 0.72
    c = ico(crown, (0, 0, cz), "Leaf", subdiv=1)
    c.scale = (1.0, 1.0, 1.18)
    tint(c, "Leaf", rng, 0.09)
    parts.append(c)
    # 第二个略小的球错开一点，轮廓才不是一个完美的球
    c2 = ico(crown * 0.62, (crown * 0.36, crown * 0.16, cz + crown * 0.42),
             "Leaf", subdiv=1)
    tint(c2, "LeafDeep", rng, 0.09)
    parts.append(c2)
    return flat(parts, name, loc)


def bush(name, loc=(0, 0, 0), radius=0.85, seed=0):
    rng = seeded(name)
    b = ico(radius, (0, 0, radius * 0.62), "Leaf", subdiv=1)
    b.scale = (1.15, 1.0, 0.72)
    tint(b, "Leaf" if rng.random() < 0.6 else "LeafDeep", rng, 0.10)
    return flat([b], name, loc)


def build_trees(out_dir):
    clear()
    for i, (h, c) in enumerate(((4.6, 1.9), (5.6, 2.2), (3.9, 1.6), (5.0, 2.0))):
        tree("tree_%d" % i, (i * 6.0 - 9.0, 0, 0), height=h, crown=c, seed=i)
    export(os.path.join(out_dir, "trees.glb"), "trees")

    clear()
    for i, r in enumerate((0.85, 1.05, 0.70, 0.95, 0.62, 1.15)):
        bush("bush_%d" % i, (i * 2.6 - 6.0, 0, 0), radius=r, seed=i)
    export(os.path.join(out_dir, "bushes.glb"), "bushes")


# ------------------------------------------------------------------ 建筑 --
def house(name, w, d, wall_h, loc=(0, 0, 0), roof_h=1.7, roof="RoofTeal",
          eaves=0.35):
    """平面着色的低模房子。

    参考图里没有建筑，所以这部分是按**这个风格的语法**推的，不是抄的：
    大色块、硬边、每个部件一个纯色、部件数量少到能一眼数清。
    刻意不加 gatling 那一套（碎屋脊、毛檐口、方向性贴图）——
    那些在这里会把风格拉回去。
    """
    rng = seeded(name)
    parts = []
    base_h = 0.32
    parts.append(tint(box((w + 0.35, d + 0.35, base_h), (0, 0, base_h * 0.5),
                          "Stone"), "Stone", rng, 0.05))
    parts.append(tint(box((w, d, wall_h), (0, 0, base_h + wall_h * 0.5),
                          "Wall"), "Wall", rng, 0.05))
    parts.append(tint(wedge((w + eaves * 2, d + eaves * 2, roof_h),
                            (0, 0, base_h + wall_h), roof), roof, rng, 0.06))
    # 门：一个凹进去的深色块，不做门框
    parts.append(tint(box((0.9, 0.18, 1.8), (0, -d * 0.5 + 0.04,
                                             base_h + 0.9), "Dark"), "Dark"))
    # 窗：两个小深色块
    for sx in (-1, 1):
        parts.append(tint(box((0.55, 0.16, 0.55),
                              (sx * w * 0.28, -d * 0.5 + 0.04,
                               base_h + wall_h * 0.62), "Dark"), "Dark"))
    # 烟囱
    ch = base_h + wall_h + roof_h * 0.85
    parts.append(tint(box((0.5, 0.5, ch), (w * 0.3, d * 0.25, ch * 0.5),
                          "WallDark"), "WallDark", rng, 0.05))
    return flat(parts, name, loc)


def build_houses(out_dir):
    specs = [("house_a", 5.4, 4.2, 2.8, "RoofTeal"),
             ("house_b", 4.2, 3.6, 2.5, "RoofRed"),
             ("house_c", 6.2, 4.6, 3.2, "RoofTeal")]
    for nm, w, d, h, roof in specs:
        clear()
        house(nm, w, d, h, roof=roof)
        export(os.path.join(out_dir, nm + ".glb"), nm)


# -------------------------------------------------------------------- 桥 --
def bridge(name, length=14.0, width=6.0, loc=(0, 0, 0)):
    rng = seeded(name)
    parts = []
    parts.append(tint(box((length, width, 0.32), (0, 0, 0), "Wood"),
                      "Wood", rng, 0.05))
    n = int(length / 1.6)
    for i in range(n):
        x = -length * 0.5 + (i + 0.5) * length / n
        parts.append(tint(box((0.35, width + 0.2, 0.14), (x, 0, 0.22),
                              "WoodDark"), "WoodDark", rng, 0.06))
    for sy in (-1, 1):
        y = sy * (width * 0.5 - 0.15)
        parts.append(tint(box((length, 0.22, 0.22), (0, y, 0.72), "Wood"),
                          "Wood", rng, 0.05))
        for i in range(4):
            x = -length * 0.5 + (i + 0.5) * length / 4.0
            parts.append(tint(box((0.22, 0.22, 0.9), (x, y, 0.45), "Wood"),
                              "Wood", rng, 0.05))
    return flat(parts, name, loc)


def build_bridge(out_dir):
    clear()
    bridge("bridge")
    export(os.path.join(out_dir, "bridge.glb"), "bridge")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="assets/hellrider/environment")
    ap.add_argument("--only", default="rocks,trees,houses,bridge")
    args = ap.parse_args(argv)
    if not os.path.isdir(args.out_dir):
        os.makedirs(args.out_dir)
    only = args.only.split(",")
    if "rocks" in only:
        build_rocks(args.out_dir)
    if "trees" in only:
        build_trees(args.out_dir)
    if "houses" in only:
        build_houses(args.out_dir)
    if "bridge" in only:
        build_bridge(args.out_dir)


if __name__ == "__main__":
    main()
