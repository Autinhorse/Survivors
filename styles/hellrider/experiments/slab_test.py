# -*- coding: utf-8 -*-
"""临时：平面轮廓带斜边、墙垂直的台地岩。

轮廓的每条边都取自一组固定方向（0/30/45/60/90...），做法是用半平面去切一个
大方形 —— 交出来的凸多边形，每条边必然是那些方向之一。
墙垂直、顶水平，所以顶面全是同一档，明暗层次全靠墙面朝向拉开。
"""
import math
import os
import sys

REPO = r"C:/My_Works/Survivors/Survivors"
sys.path[:0] = [os.path.join(REPO, "tools"), os.path.join(REPO, "styles", "hellrider")]

import bmesh                                            # noqa: E402
import bpy                                              # noqa: E402
import blenderlib as bl                                 # noqa: E402
from blenderlib import clear, export, join_as, finalize  # noqa: E402
import assets as A                                      # noqa: E402

DIRS = (0, 30, 45, 60, 90, 120, 135, 150, 180, 210, 225, 240, 270, 300, 315, 330)


def clip(poly, ang, d):
    """留下 n·p <= d 的那半边。n 取 ang 方向，所以切出来的边就是 ang+90°。"""
    nx, nz = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        da = nx * a[0] + nz * a[1] - d
        db = nx * b[0] + nz * b[1] - d
        if da <= 0.0:
            out.append(a)
        if (da < 0.0) != (db < 0.0):
            t = da / (da - db)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def layer_poly(rng, r, cx, cy, n_cuts=7):
    big = r * 2.2
    poly = [(cx - big, cy - big), (cx + big, cy - big),
            (cx + big, cy + big), (cx - big, cy + big)]
    for ang in rng.sample(DIRS, n_cuts):
        rad = math.radians(ang)
        d = (cx * math.cos(rad) + cy * math.sin(rad)) + r * rng.uniform(0.72, 1.05)
        poly = clip(poly, ang, d)
    return poly


def prism(poly, z0, z1, name):
    bm = bmesh.new()
    lo = [bm.verts.new((x, y, z0)) for x, y in poly]
    hi = [bm.verts.new((x, y, z1)) for x, y in poly]
    n = len(poly)
    for k in range(n):
        j = (k + 1) % n
        bm.faces.new((lo[k], lo[j], hi[j], hi[k]))
    bm.faces.new(hi)
    bm.faces.new(list(reversed(lo)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    return o


def slab_rock(name, loc, bevel=0.0, layers=4, r0=2.2):
    rng = A.seeded(name)
    parts = []
    z = 0.0
    r = r0
    cx = cy = 0.0
    for i in range(layers):
        poly = layer_poly(rng, r, cx, cy, n_cuts=9)
        # 厚薄要拉开：薄的读成"台沿"，厚的读成"墙"。都一样厚就成了叠盘子。
        h = rng.uniform(0.30, 0.55) if rng.random() < 0.4 else rng.uniform(1.1, 1.9)
        # 每层从上一层的顶面往下扎 0.02，免得和上一层的顶面共面打架
        o = prism(poly, z - (0.02 if i else 0.0), z + h, "%s_L%d" % (name, i))
        parts.append(A.tint(
            o, "Rock" if rng.random() < 0.72 else "RockDark", rng, 0.05))
        z += h
        r *= rng.uniform(0.70, 0.94)
        # 偏心给足：台地要往一边压，才有"一侧陡、一侧出台沿"的读法
        cx += rng.uniform(-0.9, 0.9) * r
        cy += rng.uniform(-0.9, 0.9) * r
    o = join_as(parts, name)
    if bevel > 0.0:
        bl.bevel_edges(o, width=bevel, segments=1, angle=25.0)
    A.vgrad(o, 0.20)
    finalize(o, loc, smooth_angle=0.0)
    return o


clear()
slab_rock("slab_a_plain", (-7.0, 0, 0), bevel=0.0)
slab_rock("slab_b_bevel", (0.0, 0, 0), bevel=0.09)
slab_rock("slab_c_tall", (7.0, 0, 0), bevel=0.09, layers=5, r0=1.7)
slab_rock("slab_d_low", (14.0, 0, 0), bevel=0.09, layers=2, r0=2.6)
out = os.path.join(REPO, "assets", "hellrider", "environment", "slab_test.glb")
export(out, "slab_test")
for o in [x for x in bpy.data.objects if x.type == "MESH"]:
    print("[tris] %-14s %d" % (o.name, len(o.data.polygons)))
