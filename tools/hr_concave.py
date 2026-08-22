# -*- coding: utf-8 -*-
"""量石头/树上的**凹折**：向内折的边有多少、多深、夹着的面有多小。

在 Blender 里跑：

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" \
        --background --factory-startup --python tools/hr_concave.py -- \
        assets/hellrider/environment/rocks.glb

为什么单独量这个：分档着色下，一个**又深又窄**的凹折读出来就是一小块突兀的
深色 —— 面法线先猛地转过去再转回来，中间那个面掉进最暗的一档，而它太小，
读不成"一个面"，只读成一个脏点。参考图里的石头有台阶（也是凹的），
但台阶是**宽**的，读成一个平面。所以判据不是"有没有凹"，是"凹得又深又窄"。

凹凸的判法：外向法线下，convex 时相邻面的重心落在本面平面**之下**，
即 dot(n0, c1 - c0) <= 0；> 0 就是凹。
"""
import math
import sys

import bmesh
import bpy

DEEP = 35.0        # 折角超过这么多度算"深"
NARROW = 0.04      # 相邻面里较小的那个占整体表面积的比例低于这个算"窄"


def analyse(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    total_area = sum(f.calc_area() for f in bm.faces)

    rows = []
    for e in bm.edges:
        if len(e.link_faces) != 2:
            continue
        f0, f1 = e.link_faces
        d = max(-1.0, min(1.0, f0.normal.dot(f1.normal)))
        ang = math.degrees(math.acos(d))
        concave = f0.normal.dot(f1.calc_center_median() - f0.calc_center_median()) > 1e-6
        if not concave:
            continue
        small = min(f0.calc_area(), f1.calc_area()) / max(total_area, 1e-9)
        up = (f0.normal.z > 0.2 and f1.normal.z > 0.2)      # 顶上、相机看得见
        rows.append((ang, small, up))
    bm.free()
    return rows, total_area


def main(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    print("%-14s %6s %8s %8s %10s" %
          ("网格", "凹边", "深且窄", "顶上的", "最深"))
    for o in [x for x in bpy.data.objects if x.type == "MESH"]:
        rows, _ = analyse(o)
        bad = [r for r in rows if r[0] > DEEP and r[1] < NARROW]
        up = [r for r in bad if r[2]]
        print("%-14s %6d %8d %8d %9.1f°"
              % (o.name, len(rows), len(bad), len(up),
                 max([r[0] for r in rows], default=0.0)))
        for ang, small, u in sorted(bad, reverse=True)[:4]:
            print("        折 %5.1f°  小面占表面积 %.2f%%%s"
                  % (ang, 100 * small, "  顶上" if u else ""))


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    main(argv[0] if argv else "assets/hellrider/environment/rocks.glb")
