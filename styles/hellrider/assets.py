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
# 参考图的石头有三个特征，缺一个都不像：
#
# 1. **平顶 + 近乎竖直的侧壁**。不是随机点的凸包（那到处都是斜面，
#    没有那个决定性的大平顶）。
# 2. **大块的是两层**：一个宽的低平台，上面偏一侧压着一个小锥台。
#    单层棱柱只能做小石头。
# 3. **成组出现**：一大配两三小，挤在一起、高低错落，共享底边。
#    孤零零一块是散布器的味道，不是美术摆的味道。
#
# 第三条决定了这里的做法：**变体本身就是一组**，而不是靠散布器去凑。
# 散布器随机撒出来的"组"总是间距均匀、朝向随机，读起来还是散的。
#
# 比例：参考图的石头总高和顶面宽度大致相当（敦实但不矮墩）。
# 第一版做得太扁，第二版锥台给了 7 条边读成圆顶 —— 改成 4-5 条边才有方块感。

def _tier(r0, r1, h, ox=0.0, oy=0.0, sides=6):
    return (r0, r1, h, ox, oy, sides)


ROCK_GROUPS = {
    # 每个变体是一组石头：[(锥台层列表, x, y, 转角), ...]
    #
    # 比例是并排比出来的：参考图的底座**宽而低**（宽高比约 3:1），
    # 顶面很大、侧壁很矮，高度主要来自压在上面那一层。
    # 我们一度做成"窄而高"，读起来像柱子不像岩体。
    #
    # **侧壁严格竖直**（顶半径 = 底半径）。给了锥度就读成圆锥，
    # 参考图里没有一块石头是锥形的。收窄只发生在最上面那层的顶面（做成坡顶）。
    "big": [([_tier(1.95, 1.95, 0.72, 0, 0, 6),
              _tier(1.20, 0.80, 0.75, 0.30, 0.18, 5)], 0.0, 0.0, 0.0),
            ([_tier(0.85, 0.85, 0.55, 0, 0, 5),
              _tier(0.55, 0.30, 0.34, 0.05, 0.05, 4)], 2.35, -0.95, 0.7),
            ([_tier(0.52, 0.52, 0.30, 0, 0, 4)], -2.00, 1.10, 2.1)],

    "twin": [([_tier(1.55, 1.55, 0.66, 0, 0, 6),
               _tier(0.95, 0.62, 0.62, -0.22, 0.20, 4)], 0.0, 0.0, 0.0),
             ([_tier(1.10, 1.10, 0.78, 0, 0, 5),
               _tier(0.62, 0.34, 0.40, 0.10, -0.08, 4)], 2.10, 0.80, 1.2)],

    "spire": [([_tier(1.15, 1.15, 0.78, 0, 0, 5),
                _tier(0.78, 0.72, 0.72, 0.05, 0.02, 5),
                _tier(0.55, 0.22, 0.55, 0.02, -0.06, 4)], 0.0, 0.0, 0.0),
              ([_tier(0.62, 0.62, 0.34, 0, 0, 4)], 1.55, -0.85, 0.4)],

    "low": [([_tier(2.05, 2.05, 0.60, 0, 0, 7)], 0.0, 0.0, 0.0),
            ([_tier(0.78, 0.78, 0.38, 0, 0, 5)], 2.20, 0.95, 1.8)],

    "block": [([_tier(1.30, 1.30, 0.75, 0, 0, 5),
                _tier(0.88, 0.55, 0.68, 0.18, 0.14, 4)], 0.0, 0.0, 0.0)],

    "slab": [([_tier(2.20, 2.20, 0.50, 0, 0, 8)], 0.0, 0.0, 0.0),
             ([_tier(0.50, 0.50, 0.26, 0, 0, 4)], 2.35, -0.70, 0.9)],
}
ROCK_TILT = {"low": 0.10, "slab": 0.08}


def _ngon(rng, sides):
    """不规则凸多边形的角度和半径系数。抖动控制在 ±20% 以内保持凸性。"""
    ang, a = [], rng.uniform(0.0, math.tau)
    for _i in range(sides):
        a += math.tau / sides * rng.uniform(0.84, 1.16)
        ang.append(a)
    return ang, [rng.uniform(0.90, 1.06) for _ in range(sides)]


def _stack(bm, rng, tiers, cx, cy, rot, tilt):
    """在 (cx, cy) 堆一摞锥台。"""
    z = 0.0
    for ti, (r0, r1, h, ox, oy, sides) in enumerate(tiers):
        ang, jit = _ngon(rng, sides)
        bot, top = [], []
        for i in range(sides):
            a = ang[i] + rot
            ca, sa = math.cos(a), math.sin(a)
            k = jit[i]
            bot.append(bm.verts.new((cx + ox + ca * r0 * k,
                                     cy + oy + sa * r0 * k, z)))
            tz = z + h + ca * r1 * k * tilt
            top.append(bm.verts.new((cx + ox + ca * r1 * k,
                                     cy + oy + sa * r1 * k, tz)))
        bm.faces.new(top)
        if ti == 0:
            bm.faces.new(list(reversed(bot)))
        for i in range(sides):
            j = (i + 1) % sides
            bm.faces.new((bot[i], bot[j], top[j], top[i]))
        z += h


def rock(name, shape, loc=(0, 0, 0)):
    rng = seeded(name)
    tilt = ROCK_TILT.get(shape, 0.05)
    bm = bmesh.new()
    for tiers, cx, cy, rot in ROCK_GROUPS[shape]:
        _stack(bm, rng, tiers, cx, cy, rot, tilt)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    tint(o, "Rock", rng, 0.045)
    vgrad(o, 0.24)
    finalize(o, loc, smooth_angle=0.0)
    return o


def build_rocks(out_dir):
    clear()
    for i, shape in enumerate(ROCK_GROUPS):
        rock("rock_%s" % shape, shape, loc=(i * 7.0 - 17.0, 0, 0))
    export(os.path.join(out_dir, "rocks.glb"), "rocks")

    # 碎石：单块、很小，用来填空
    clear()
    for i, shape in enumerate(("block", "low", "slab", "twin")):
        o = rock("pebble_%d" % i, shape, loc=(i * 2.0 - 3.0, 0, 0))
        o.scale = (0.16, 0.16, 0.15)
    export(os.path.join(out_dir, "pebbles.glb"), "pebbles")


# -------------------------------------------------------------------- 树 --
def tree(name, loc=(0, 0, 0), height=4.6, crown=1.9, seed=0):
    """细杆 + 低面球树冠。参考图就是这么简单 —— 没有枝、没有贴片。

    第二团要和主团**同色系且大幅重叠**。第一版给了明显更深的 LeafDeep
    又只压住一点点，读出来是贴在树冠上的一块深色补丁，不是同一团树叶。
    深浅差异交给着色器的分档光照和 vgrad 去产生，不要在颜色上先分好。
    """
    rng = seeded(name)
    parts = []
    th = height * 0.44
    # 树干更细：参考图里树干只有两三个像素宽
    parts.append(tint(cyl(0.10, th, (0, 0, th * 0.5), "Trunk", verts=5),
                      "Trunk", rng, 0.04))
    cz = th + crown * 0.66
    c = ico(crown, (0, 0, cz), "Leaf", subdiv=1)
    c.scale = (1.0, 1.0, 1.12)
    tint(c, "Leaf", rng, 0.07)
    parts.append(c)
    c2 = ico(crown * 0.70, (crown * 0.30, crown * 0.12, cz + crown * 0.26),
             "Leaf", subdiv=1)
    tint(c2, "Leaf", rng, 0.07)
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
