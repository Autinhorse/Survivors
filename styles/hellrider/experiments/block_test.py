# -*- coding: utf-8 -*-
"""临时：大小不一的方块堆成的岩，倒角 / 不倒角各一份。"""
import os
import sys

REPO = r"C:/My_Works/Survivors/Survivors"
sys.path[:0] = [os.path.join(REPO, "tools"), os.path.join(REPO, "styles", "hellrider")]

import bpy                                              # noqa: E402
import blenderlib as bl                                 # noqa: E402
from blenderlib import box, clear, export, join_as, finalize   # noqa: E402
import assets as A                                      # noqa: E402

# 一座"台地"：几块大小不同的方盒，轴向对齐、互相错开
BLOCKS = (
    ((4.2, 3.6, 1.3), (0.0, 0.0, 0.65)),
    ((2.8, 2.4, 1.5), (-0.5, 0.4, 1.95)),
    ((1.9, 2.9, 1.1), (1.2, -0.3, 1.85)),
    ((1.5, 1.4, 1.2), (-0.2, 0.1, 3.20)),
    ((1.2, 1.1, 0.7), (2.4, 1.5, 0.35)),
    ((0.9, 1.3, 0.5), (-2.3, -1.4, 0.25)),
)


def block_rock(name, loc, bevel=0.0):
    rng = A.seeded(name)
    parts = []
    for i, (size, pos) in enumerate(BLOCKS):
        o = box(size, pos, "Rock")
        parts.append(A.tint(
            o, "Rock" if rng.random() < 0.72 else "RockDark", rng, 0.05))
    o = join_as(parts, name)
    if bevel > 0.0:
        bl.bevel_edges(o, width=bevel, segments=1, angle=25.0)
    A.vgrad(o, 0.20)
    finalize(o, loc, smooth_angle=0.0)
    return o


clear()
block_rock("blk_a_plain", (-6.0, 0, 0), bevel=0.0)
block_rock("blk_b_bevel", (0.0, 0, 0), bevel=0.10)
out = os.path.join(REPO, "assets", "hellrider", "environment", "block_test.glb")
export(out, "block_test")
for o in [x for x in bpy.data.objects if x.type == "MESH"]:
    print("[tris] %-14s %d" % (o.name, len(o.data.polygons)))
