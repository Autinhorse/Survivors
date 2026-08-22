# -*- coding: utf-8 -*-
"""量每个面在**屏幕上**有多少像素 —— 面太小就读不成一个面。

在 Blender 里跑：

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" \
        --background --factory-startup --python tools/hr_face_px.py -- \
        assets/hellrider/environment/rocks.glb [实例缩放]

为什么要量这个：分档着色把面按朝向分成 4 档，相邻两档差 3.7 倍。
这在一个**读得出是平面**的面上是风格；在一个十几像素的碎片上就是脏点。
参考图里"每块石头只有 3-4 个明确的面"说的就是这件事。

判据：可见面的屏幕面积 >= MIN_PX。相机是正交的，所以
    屏幕面积 = 三维面积 x 实例缩放^2 x |n·视线| x (像素/米)^2
和距离无关，一个变体一个数，不用逐实例算。
"""
import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

PPM = 1920.0 / 65.8          # 正交视宽 65.8 m 铺满 1920 px
MIN_PX = 200.0               # 约 14x14 像素
LO, HI, STEPS = 12.0, 105.0, 4.0
L = Vector((-0.396, 0.507, 0.766)).normalized()    # 指向光源（Blender Z 上）
D = Vector((0.0, 0.766, -0.643)).normalized()      # 相机视线（Blender Z 上）
YAWS = 12                    # 绕一圈取几个朝向平均


def step_of(th):
    t = max(0.0, min(1.0, (HI - th) / (HI - LO)))
    return int(max(0, min(3, math.floor(t * STEPS))))


def components(bm):
    """按连通块分组 —— 一个变体是**一组**石头（大的配两三小的），
    要和参考图比"一块石头有几个面"就必须拆开算。"""
    seen, out = set(), []
    for f in bm.faces:
        if f.index in seen:
            continue
        stack, grp = [f], []
        seen.add(f.index)
        while stack:
            g = stack.pop()
            grp.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index)
                        stack.append(h)
        out.append(grp)
    return out


def survey_parts(obj, scale):
    """逐块：可见面数、屏幕面积、每个面平均多少 px²。"""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bm.normal_update()
    bm.faces.ensure_lookup_table()
    out = []
    for grp in components(bm):
        n, area, small = 0.0, 0.0, 0.0
        for k in range(YAWS):
            R = Matrix.Rotation(math.tau * k / YAWS, 3, 'Z')
            for f in grp:
                nrm = (R @ f.normal).normalized()
                c = nrm.dot(D)
                if c >= -1e-6:
                    continue
                px = f.calc_area() * scale * scale * (-c) * PPM * PPM
                n += 1
                area += px
                if px < MIN_PX:
                    small += 1
        if area > 0:
            out.append((area / YAWS, n / YAWS, small / YAWS))
    bm.free()
    return sorted(out, reverse=True)


def survey(obj, scale):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bm.normal_update()
    vis, small, small_area, tot_area, spread = 0, 0, 0.0, 0.0, 0
    for k in range(YAWS):
        R = Matrix.Rotation(math.tau * k / YAWS, 3, 'Z')
        steps_of_small = set()
        for f in bm.faces:
            n = (R @ f.normal).normalized()
            c = n.dot(D)
            if c >= -1e-6:
                continue
            px = f.calc_area() * scale * scale * (-c) * PPM * PPM
            th = math.degrees(math.acos(max(-1.0, min(1.0, n.dot(L)))))
            vis += 1
            tot_area += px
            if px < MIN_PX:
                small += 1
                small_area += px
                steps_of_small.add(step_of(th))
        spread = max(spread, len(steps_of_small))
    bm.free()
    return (vis / YAWS, small / YAWS, 100.0 * small_area / max(tot_area, 1e-9),
            tot_area / YAWS, spread)


def main(path, scale):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    print("实例缩放 %.2f，判据：可见面 >= %.0f px²" % (scale, MIN_PX))
    print("%-14s %8s %8s %9s %10s %8s"
          % ("网格", "可见面", "太小的", "占面积%", "屏幕px²", "小面跨档"))
    for o in [x for x in bpy.data.objects if x.type == "MESH"]:
        v, s, a, t, sp = survey(o, scale)
        print("%-14s %8.1f %8.1f %8.1f%% %10.0f %8d%s"
              % (o.name, v, s, a, t, sp, "   <-" if a > 15.0 else ""))
    print()
    print("逐块（一个变体是一组石头，拆开算才能和参考图比）")
    print("%-14s %10s %8s %10s %8s"
          % ("网格.块", "屏幕px²", "可见面", "px²/面", "太小的"))
    for o in [x for x in bpy.data.objects if x.type == "MESH"]:
        for i, (area, n, sm) in enumerate(survey_parts(o, scale)):
            print("%-14s %10.0f %8.1f %10.0f %8.1f%s"
                  % ("%s.%d" % (o.name, i), area, n, area / max(n, 1e-9), sm,
                     "   <- 面太碎" if area / max(n, 1e-9) < 900 else ""))


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    main(argv[0] if argv else "assets/hellrider/environment/rocks.glb",
         float(argv[1]) if len(argv) > 1 else 1.2)
