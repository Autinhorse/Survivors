# -*- coding: utf-8 -*-
"""Blender 资产管线：任意输入网格 -> 可直接进 Godot 的 GLB。

对应需求 §21 的中间那一段：

    (AI 3D / 购买 / 手工) --> [ Blender: Cleanup / 减面 / Scale / Origin / 材质 ] --> GLB --> Godot

这一段是确定性的，所以它应该是脚本，不是手工劳动 —— §33 D 项的
「一个普通环境资产人工 Cleanup ≤ 30 分钟」如果靠人手点，永远不可能稳定达成。

用法：

    blender --background --factory-startup --python tools/asset_pipeline.py -- \
        --input in.glb --output out.glb --name Rock --target-tris 300 --target-size 2.0

输入支持 .glb/.gltf/.obj/.fbx/.blend。每一步都会打印耗时和网格统计，
最后输出一行 JSON 摘要，方便汇总成表。
"""
import argparse
import json
import os
import sys
import time

import bpy
import bmesh
from mathutils import Vector


def log(msg):
    print("[pipeline] " + msg, flush=True)


class Step:
    """计时上下文：每一步的耗时都要能单独报出来，否则不知道该优化哪一步。"""

    def __init__(self, name, out):
        self.name = name
        self.out = out

    def __enter__(self):
        self.t0 = time.perf_counter()
        return self

    def __exit__(self, *a):
        dt = time.perf_counter() - self.t0
        self.out[self.name] = round(dt, 3)
        log("%-18s %6.3f s" % (self.name, dt))
        return False


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_any(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif ext == ".blend":
        bpy.ops.wm.open_mainfile(filepath=path)
    else:
        raise SystemExit("unsupported input: " + ext)


def mesh_objects():
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


def tri_count(objs):
    n = 0
    for o in objs:
        me = o.data
        me.calc_loop_triangles()
        n += len(me.loop_triangles)
    return n


def scene_dimensions(objs):
    """世界空间包围盒（含物体自身变换）。"""
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
    return lo, hi, (hi - lo)


def cleanup(obj, merge_dist):
    """用 bmesh 而不是 bpy.ops.mesh.*：bmesh 的 API 跨版本稳定得多，
    而且不依赖编辑模式和当前选中状态（无头运行时后者很容易出错）。"""
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=merge_dist)
    bmesh.ops.dissolve_degenerate(bm, dist=merge_dist * 0.1, edges=bm.edges[:])
    loose = [v for v in bm.verts if not v.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.to_mesh(me)
    bm.free()
    me.update()


def decimate(obj, target_tris):
    me = obj.data
    me.calc_loop_triangles()
    cur = len(me.loop_triangles)
    if cur <= target_tris:
        return cur, cur
    ratio = max(min(float(target_tris) / float(cur), 1.0), 0.001)
    bpy.context.view_layer.objects.active = obj
    mod = obj.modifiers.new("decimate", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio
    bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.calc_loop_triangles()
    return cur, len(obj.data.loop_triangles)


def normalize_scale(objs, target_size, fit):
    """统一缩放，全体乘同一个系数（保持物体之间的相对大小）。

    fit="scene"   整个场景的包围盒最长轴 -> target_size
    fit="object"  单个物体的最长轴的最大值 -> target_size

    资产"组"（比如一组石头）必须用 object：它们在文件里是摊开摆放的，
    按场景包围盒缩放的话，量到的是摆放跨度而不是石头本身的尺寸。"""
    if fit == "object":
        longest = 0.0
        for o in objs:
            d = o.dimensions
            longest = max(longest, d.x, d.y, d.z)
        dim = None
    else:
        _, _, dim = scene_dimensions(objs)
        longest = max(dim.x, dim.y, dim.z)
    if longest <= 1e-9:
        return 1.0
    s = target_size / longest
    for o in objs:
        o.scale = o.scale * s
        # 位置也要一起缩放，否则物体缩小了但彼此的间距没变，
        # 一组石头会被摊开到几十米外
        o.location = o.location * s
    bpy.context.view_layer.update()
    return s


def set_origin_bottom_center(obj):
    """原点放到底面中心：Godot 侧摆放时 y=0 就是地面，不用每个资产猜偏移。
    Blender 是 Z-up，导出 glTF 时会转成 Y-up，底面依然是底面。"""
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
    obj.location = obj.location + (obj.matrix_world.to_3x3() @ pivot)


def recenter(objs):
    """把资产搬到世界原点，底面贴地。

    AI 3D 的输出几乎总是带一个任意的世界偏移（模型飘在离原点几十米的地方）。
    只把网格内部的原点挪到底面是不够的 —— 物体本身还在原来的位置上，
    在 Godot 里摆放时就会发现"放在 (0,0,0) 的东西不在 (0,0,0)"。

    多物体的资产"组"保留彼此的相对布局，只把整组的中心对到原点，
    因为组内的相对关系是有意义的（一组石头的大小和疏密），
    而组相对于世界原点的位置没有意义。
    """
    if not objs:
        return
    cx = sum(o.location.x for o in objs) / len(objs)
    cy = sum(o.location.y for o in objs) / len(objs)
    for o in objs:
        o.location.x -= cx
        o.location.y -= cy
        o.location.z = 0.0        # Blender 是 Z-up：底面落到 z=0
    bpy.context.view_layer.update()


def apply_transforms(objs):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)


def unify_material(objs, name, color):
    """统一成一个命名材质。AI 3D 通常带一张烘焙贴图和随机材质名，
    直接进项目会让每个资产各自一套材质 —— 批处理和 Preset 都无从谈起。"""
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
        if "Roughness" in bsdf.inputs:
            bsdf.inputs["Roughness"].default_value = 0.9
        if "Metallic" in bsdf.inputs:
            bsdf.inputs["Metallic"].default_value = 0.0
    for o in objs:
        o.data.materials.clear()
        o.data.materials.append(mat)
    return mat


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--name", default="Asset")
    ap.add_argument("--target-tris", type=int, default=300,
                    help="每个物体的目标三角形数（§4.1：小型单位 100-300）")
    ap.add_argument("--target-size", type=float, default=2.0,
                    help="整体最长轴对齐到多少米")
    ap.add_argument("--merge-dist", type=float, default=1e-4)
    ap.add_argument("--fit", choices=["scene", "object"], default="scene",
                    help="target-size 对齐到整场景包围盒还是单个物体")
    ap.add_argument("--color", default="0.35,0.33,0.30")
    ap.add_argument("--report", default="")
    args = ap.parse_args(argv)

    color = [float(x) for x in args.color.split(",")]
    t = {}
    stats = {"name": args.name, "input": os.path.basename(args.input)}
    t_all = time.perf_counter()

    with Step("import", t):
        clear_scene()
        import_any(args.input)
    objs = mesh_objects()
    if not objs:
        raise SystemExit("no mesh objects in input")

    stats["objects"] = len(objs)
    stats["tris_in"] = tri_count(objs)
    _, _, dim_in = scene_dimensions(objs)
    stats["size_in_m"] = [round(v, 3) for v in dim_in]

    with Step("cleanup", t):
        for o in objs:
            cleanup(o, args.merge_dist)
    stats["tris_after_cleanup"] = tri_count(objs)

    with Step("decimate", t):
        for o in objs:
            decimate(o, args.target_tris)
    stats["tris_out"] = tri_count(objs)

    with Step("scale_origin", t):
        s = normalize_scale(objs, args.target_size, args.fit)
        apply_transforms(objs)
        for o in objs:
            set_origin_bottom_center(o)
        recenter(objs)
        stats["scale_factor"] = round(s, 5)
    _, _, dim_out = scene_dimensions(objs)
    stats["size_out_m"] = [round(v, 3) for v in dim_out]

    with Step("material", t):
        unify_material(objs, args.name + "Mat", color)

    with Step("export_glb", t):
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        bpy.ops.export_scene.gltf(filepath=args.output, export_format="GLB",
                                  use_selection=False, export_apply=True,
                                  export_yup=True)

    stats["steps_sec"] = t
    stats["total_sec"] = round(time.perf_counter() - t_all, 3)
    stats["output"] = os.path.basename(args.output)
    stats["output_kb"] = round(os.path.getsize(args.output) / 1024.0, 1)

    log("tris %d -> %d (cleanup %d), size %s m -> %s m, %.2f s total"
        % (stats["tris_in"], stats["tris_out"], stats["tris_after_cleanup"],
           stats["size_in_m"], stats["size_out_m"], stats["total_sec"]))
    print("PIPELINE_JSON " + json.dumps(stats), flush=True)
    if args.report:
        with open(args.report, "a", encoding="utf-8") as f:
            f.write(json.dumps(stats) + "\n")


main()
