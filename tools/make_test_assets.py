# -*- coding: utf-8 -*-
"""生成"AI 3D 风格"的脏输入，用来在没有 AI 服务的情况下验证 §21 的后半段管线。

这些替身刻意复现真实 AI 3D 输出的麻烦之处，而不是生成干净模型 ——
否则管线等于没被测过：

- 几万面的三角汤，没有可用拓扑
- 任意缩放（不是米），原点在世界中心而不是底面
- 法线不一致（部分面翻转）
- 重复顶点与孤立顶点
- 一个随机命名的材质

用法：
    blender --background --factory-startup --python tools/make_test_assets.py -- --out-dir tmp/raw
"""
import argparse
import math
import os
import random
import sys

import bpy
import bmesh
from mathutils import Vector, noise


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def messify(obj, rng, flip_ratio=0.12, dup_verts=40):
    """把一个干净网格弄成 AI 输出那种状态。"""
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)

    # 法线不一致：随机翻转一部分面
    faces = bm.faces[:]
    for f in faces:
        if rng.random() < flip_ratio:
            f.normal_flip()

    # 孤立顶点：AI 网格里很常见
    for _ in range(dup_verts):
        p = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
        bm.verts.new(p * 0.5)

    bm.to_mesh(me)
    bm.free()
    me.update()


def displace(obj, amount, freq, seed):
    me = obj.data
    for v in me.vertices:
        n = noise.noise(v.co * freq + Vector((seed, seed, seed)))
        v.co += v.normal * (n * amount)
    me.update()


def add_random_material(obj, rng):
    m = bpy.data.materials.new(name="mat_%06d" % rng.randint(0, 999999))
    m.use_nodes = True
    obj.data.materials.clear()
    obj.data.materials.append(m)


def finish(objs, rng, scale, offset):
    """任意缩放 + 原点偏移：AI 输出几乎从不按米，也几乎从不把原点放在底面。"""
    for o in objs:
        o.scale = (scale, scale, scale)
        o.location = o.location * scale + offset
        add_random_material(o, rng)
        messify(o, rng)


def export(path):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB",
                              use_selection=False)
    print("[raw] wrote %s (%.1f KB)" % (path, os.path.getsize(path) / 1024.0),
          flush=True)


def make_rocks(out, rng):
    """§21 的"一组 Rock"：5 块，大小不一。"""
    clear()
    objs = []
    for i in range(5):
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=5, radius=1.0)
        o = bpy.context.active_object
        o.name = "rock_%d" % i
        displace(o, 0.42, 1.6, i * 7 + 3)
        s = rng.uniform(0.5, 1.6)
        o.scale = (s * rng.uniform(0.8, 1.3), s * rng.uniform(0.8, 1.3),
                   s * rng.uniform(0.5, 0.9))
        o.location = (i * 3.0 - 6.0, 0.0, 0.0)
        objs.append(o)
    finish(objs, rng, scale=11.3, offset=Vector((4.2, -1.7, 6.9)))
    export(out)


def make_bridge(out, rng):
    """§21 的"一座 Bridge"：桥面 + 桥墩 + 栏杆，高密度细分。"""
    clear()
    parts = []
    bpy.ops.mesh.primitive_cube_add(size=1)
    deck = bpy.context.active_object
    deck.name = "deck"
    deck.scale = (6.0, 1.2, 0.12)
    parts.append(deck)
    for i in range(4):
        bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.16, depth=2.2)
        p = bpy.context.active_object
        p.name = "pylon_%d" % i
        p.location = (-4.0 + i * 2.7, (-1.0 if i % 2 else 1.0), -1.1)
        parts.append(p)
    for i in range(14):
        bpy.ops.mesh.primitive_cube_add(size=1)
        r = bpy.context.active_object
        r.name = "post_%d" % i
        r.scale = (0.06, 0.06, 0.5)
        r.location = (-5.6 + i * 0.86, (-1.1 if i % 2 else 1.1), 0.4)
        parts.append(r)

    bpy.ops.object.select_all(action="DESELECT")
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    # join() 会把其他物体烘进活动物体的局部空间。活动物体如果还带着非等比缩放，
    # 被烘进来的部件就会按那个缩放的倒数被拉变形 —— 先 apply 掉。
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    bpy.ops.object.join()
    obj = bpy.context.active_object
    obj.name = "bridge"

    # 细分成三角汤：AI 输出通常没有可用拓扑
    bpy.context.view_layer.objects.active = obj
    mod = obj.modifiers.new("sub", "SUBSURF")
    mod.subdivision_type = "SIMPLE"
    mod.levels = 3
    mod.render_levels = 3
    bpy.ops.object.modifier_apply(modifier=mod.name)
    displace(obj, 0.02, 6.0, 11)
    finish([obj], rng, scale=27.5, offset=Vector((-9.0, 3.5, 12.0)))
    export(out)


def make_mech(out, rng):
    """§21 的"一个 Mech"：多构件机械体。"""
    clear()
    parts = []
    specs = [
        ("torso", "cube", (1.9, 2.3, 1.2), (0, 0, 1.55)),
        ("turret", "cyl", (1.3, 1.3, 0.7), (0, -0.2, 2.35)),
        ("gun_l", "cyl", (0.28, 0.28, 2.4), (0.45, -1.7, 2.3)),
        ("gun_r", "cyl", (0.24, 0.24, 2.0), (-0.45, -1.5, 2.3)),
        ("hip_l", "cube", (0.5, 1.2, 0.7), (-0.95, 0, 1.0)),
        ("hip_r", "cube", (0.5, 1.2, 0.7), (0.95, 0, 1.0)),
        ("foot_l", "cube", (0.6, 1.5, 0.25), (-0.95, 0.15, 0.12)),
        ("foot_r", "cube", (0.6, 1.5, 0.25), (0.95, 0.15, 0.12)),
    ]
    for name, kind, sc, loc in specs:
        if kind == "cube":
            bpy.ops.mesh.primitive_cube_add(size=1)
        else:
            bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=0.5, depth=1.0)
        o = bpy.context.active_object
        o.name = name
        o.scale = sc
        o.location = loc
        if name.startswith("gun"):
            o.rotation_euler = (math.radians(90), 0, 0)
        parts.append(o)

    bpy.ops.object.select_all(action="DESELECT")
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    # join() 会把其他物体烘进活动物体的局部空间。活动物体如果还带着非等比缩放，
    # 被烘进来的部件就会按那个缩放的倒数被拉变形 —— 先 apply 掉。
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    bpy.ops.object.join()
    obj = bpy.context.active_object
    obj.name = "mech"
    bpy.context.view_layer.objects.active = obj
    mod = obj.modifiers.new("sub", "SUBSURF")
    mod.subdivision_type = "SIMPLE"
    mod.levels = 3
    bpy.ops.object.modifier_apply(modifier=mod.name)
    displace(obj, 0.015, 8.0, 23)
    finish([obj], rng, scale=6.4, offset=Vector((2.0, 2.0, -3.0)))
    export(out)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args(argv)
    rng = random.Random(20260821)
    make_rocks(os.path.join(args.out_dir, "raw_rocks.glb"), rng)
    make_bridge(os.path.join(args.out_dir, "raw_bridge.glb"), rng)
    make_mech(os.path.join(args.out_dir, "raw_mech.glb"), rng)


main()
