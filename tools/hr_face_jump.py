# -*- coding: utf-8 -*-
"""量"相邻面色差正比于法线差"这条规则被破坏得有多厉害。

在 Blender 里跑：

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" \
        --background --factory-startup --python tools/hr_face_jump.py -- \
        assets/hellrider/environment/rocks.glb

背景：`hr_flat` 把亮度量化成 light_steps 档，量化天生违反这条规则 ——
两个法线只差几度的面，只要跨过档位边界就硬差一整档。片元着色器看不到邻面，
改不了；真正的邻面约束在 Blender 端（`face_relax`），但烘的时候还不知道
这个实例会被转到哪个 yaw，所以约束不到方向性的那一项。

**先量再决定要不要做那套"生成时烘"的管线。** 判据：
在很多个 yaw 上取平均，法线夹角 < 阈值的相邻面对里，有多大比例跨了档，
跨档的那些平均差多少亮度。太阳仰角按场景里的 50°。
"""
import math
import sys

import bmesh
import bpy
from mathutils import Vector

SUN_ELEV = 50.0          # 场景里的太阳仰角（layout.py 的 rx=-50）
STEPS = 4.0              # light_steps
FLOOR = 0.20             # light_floor
GAMMA = 1.6              # light_gamma
NEAR_DEG = 12.0          # "法线差不多"的阈值
N_YAW = 72               # 绕一圈取多少个朝向


def lit_new(n, l):
    t = 1.0 - math.acos(max(-1.0, min(1.0, n.dot(l)))) / math.pi
    t = t ** GAMMA
    q = max(0.0, min(1.0, math.floor(t * STEPS) / (STEPS - 1.0)))
    return FLOOR + (1.0 - FLOOR) * q


def lit_old(n, l, wrap=0.60, sw=0.80, floor=0.22, tilt=0.10, steps=4.0):
    d = n.dot(l)
    nl = (1.0 - wrap) * max(0.0, min(1.0, d)) + wrap * (d * 0.5 + 0.5)
    q = max(0.0, min(1.0, math.floor(nl * steps) / (steps - 1.0)))
    sh = (1.0 - sw) * nl + sw * q
    return (floor + (1.0 - floor) * sh) * (1.0 + tilt * (nl - 0.5) * 2.0)


def pairs_of(obj):
    """(法线A, 法线B, 夹角度数)，只要共边的相邻面。"""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    # **必须先按距离合并。** 平面着色的网格导出时顶点是按面拆开的
    # （每个面自己一套法线），导进来之后几乎没有边是被两个面共用的 ——
    # 不合并的话下面一对相邻面都找不到，量出来是一片 0，看着像"没问题"。
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bm.normal_update()
    out = []
    for e in bm.edges:
        if len(e.link_faces) != 2:
            continue
        f0, f1 = e.link_faces
        d = max(-1.0, min(1.0, f0.normal.dot(f1.normal)))
        out.append((f0.normal.copy(), f1.normal.copy(),
                    math.degrees(math.acos(d))))
    bm.free()
    return out


def main(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.data.objects if o.type == "MESH"]
    print("载入 %s：%d 个网格" % (path, len(objs)))

    allp = []
    for o in objs:
        allp += pairs_of(o)
    near = [p for p in allp if p[2] < NEAR_DEG]
    print("相邻面对 %d，其中法线差 < %g° 的 %d 对 (%.0f%%)"
          % (len(allp), NEAR_DEG, len(near), 100.0 * len(near) / max(len(allp), 1)))

    # 判据和 face_relax 用的一样：邻面允许的色差上限 = base + slope*夹角/pi。
    # 超过这个上限的才算"非比例跳变"，也就是眼睛会读成假台阶的那种。
    BASE, SLOPE, VISIBLE = 0.03, 0.60, 0.10
    el = math.radians(SUN_ELEV)
    lights = []
    for i in range(N_YAW):
        az = 2.0 * math.pi * i / N_YAW
        lights.append(Vector((math.cos(el) * math.cos(az),
                              math.cos(el) * math.sin(az),
                              math.sin(el))).normalized())
    print("%-20s %8s %9s %9s %8s" % ("", "平均|Δ|", ">上限%", ">0.10%", "最大|Δ|"))
    for name, fn in (("现在（角度法 4 档）", lit_new), ("上一版（三条规则）", lit_old)):
        tot = over = vis = 0
        acc = worst = 0.0
        for l in lights:
            for n0, n1, ang in near:
                a, b = fn(n0, l), fn(n1, l)
                d = abs(a - b)
                lim = (BASE + SLOPE * (ang / 180.0)) * 0.5 * (a + b)
                tot += 1
                acc += d
                worst = max(worst, d)
                if d > lim:
                    over += 1
                if d > VISIBLE:
                    vis += 1
        print("%-20s %8.3f %8.1f%% %8.1f%% %8.3f"
              % (name, acc / tot, 100.0 * over / tot, 100.0 * vis / tot, worst))
    print("参考：一整档 = %.3f" % ((1.0 - FLOOR) / (STEPS - 1.0)))


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    main(argv[0] if argv else "assets/hellrider/environment/rocks.glb")
