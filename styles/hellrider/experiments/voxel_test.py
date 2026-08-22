# -*- coding: utf-8 -*-
"""临时：搭两个体素道具（树 + 岩），看它们在我们这台 90° 正视相机下什么样。"""
import os
import sys

REPO = r"C:/My_Works/Survivors/Survivors"
sys.path[:0] = [os.path.join(REPO, "tools"), os.path.join(REPO, "styles", "hellrider")]

import blenderlib as bl                      # noqa: E402
from blenderlib import box, clear, export    # noqa: E402
import assets as A                           # noqa: E402


def vox_tree(name, loc, cube=0.75):
    rng = A.seeded(name)
    parts = [A.tint(box((0.45, 0.45, 1.8), (0, 0, 0.9), "Trunk"), "Trunk", rng, 0.04)]
    for ix in range(-2, 3):
        for iy in range(-2, 3):
            for iz in range(0, 4):
                d = (ix / 2.3) ** 2 + (iy / 2.3) ** 2 + ((iz - 1.4) / 1.9) ** 2
                if d > 1.0 or (d > 0.55 and rng.random() < 0.45):
                    continue
                o = box((cube, cube, cube),
                        (ix * cube, iy * cube, 1.8 + (iz + 0.5) * cube), "Leaf")
                parts.append(A.tint(
                    o, "Leaf" if rng.random() < 0.65 else "LeafDeep", rng, 0.07))
    return A.flat(parts, name, loc, grad=0.20)


def vox_rock(name, loc, cube=1.15):
    rng = A.seeded(name)
    parts = []
    z = 0.0
    for r in (2, 1, 0):
        for ix in range(-r, r + 1):
            for iy in range(-r, r + 1):
                if ix * ix + iy * iy > r * r + r:
                    continue
                if r == 2 and rng.random() < 0.18:
                    continue
                parts.append(A.tint(
                    box((cube, cube, cube), (ix * cube, iy * cube, z + cube * 0.5),
                        "Rock"),
                    "Rock" if rng.random() < 0.7 else "RockDark", rng, 0.05))
        z += cube
    return A.flat(parts, name, loc, grad=0.22)


clear()
vox_tree("vox_tree_0", (-6.0, 0, 0))
vox_tree("vox_tree_1", (-2.0, 0, 0))
vox_rock("vox_rock_0", (2.0, 0, 0))
vox_rock("vox_rock_1", (6.0, 0, 0))
out = os.path.join(REPO, "assets", "hellrider", "environment", "voxel_test.glb")
export(out, "voxel_test")
for o in bpy.data.objects if False else []:
    pass
import bpy                                   # noqa: E402
for o in [x for x in bpy.data.objects if x.type == "MESH"]:
    print("[tris] %-14s %d" % (o.name, len(o.data.polygons)))
