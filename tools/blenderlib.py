# -*- coding: utf-8 -*-
"""Blender 建模辅助：基础构件、合并、倒角、UV、顶点色烘焙、导出。

**与美术风格无关。** 从 gen_assets_blender.py 抽出来，
让各个风格的资产脚本（styles/<名字>/assets.py）共用同一套底层。

调色板由风格注入：

    import blenderlib as bl
    bl.PALETTE.update(MY_PALETTE)

`mat(name)` 既接受调色板里的名字，也接受直接给的 (r, g, b) sRGB 三元组。
"""
import math
import os

import bpy
import bmesh
from mathutils import Quaternion, Vector    # noqa: F401  资产脚本会用到

# 由风格模块填充（styles/<名字>/assets.py）
PALETTE = {}


_mats = {}


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat(name):
    if name in _mats and _mats[name].name in bpy.data.materials:
        return _mats[name]
    m = bpy.data.materials.new(name=name)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    if b:
        c = [srgb_to_linear(x) for x in PALETTE[name]]
        b.inputs["Base Color"].default_value = (c[0], c[1], c[2], 1.0)
        if "Roughness" in b.inputs:
            b.inputs["Roughness"].default_value = 0.92
        if "Metallic" in b.inputs:
            b.inputs["Metallic"].default_value = 0.5 if name == "Metal" else 0.0
    _mats[name] = m
    return m


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mats.clear()


# -------------------------------------------------------------- 基础构件 --


def box(size, loc, material, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = size
    o.data.materials.append(mat(material))
    return o


def cyl(radius, depth, loc, material, verts=8, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius,
                                        depth=depth, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.data.materials.append(mat(material))
    return o


def wedge(size, loc, material, rot=(0, 0, 0)):
    """三棱柱屋顶：Blender 没有现成的，用 bmesh 直接建，
    这样能精确控制屋脊位置和出檐，比缩放 primitive 可控得多。"""
    w, d, h = size
    verts = [
        (-w / 2, -d / 2, 0), (w / 2, -d / 2, 0), (w / 2, d / 2, 0), (-w / 2, d / 2, 0),
        (0, -d / 2, h), (0, d / 2, h),
    ]
    faces = [(0, 1, 4), (2, 3, 5), (0, 4, 5, 3), (1, 2, 5, 4), (0, 3, 2, 1)]
    me = bpy.data.meshes.new("wedge")
    me.from_pydata([Vector(v) for v in verts], [], faces)
    me.update()
    o = bpy.data.objects.new("wedge", me)
    bpy.context.collection.objects.link(o)
    o.location = loc
    o.rotation_euler = rot
    o.data.materials.append(mat(material))
    return o


def join_as(parts, name):
    bpy.ops.object.select_all(action="DESELECT")
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    # 合并前 apply：活动物体若带非等比缩放，被烘入的部件会按其倒数变形
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    bpy.ops.object.join()
    o = bpy.context.active_object
    o.name = name
    return o


def finalize(obj, loc=(0, 0, 0), smooth_angle=0.0):
    """着色 + 原点落到底面中心 + 摆到指定位置。

    smooth_angle = 0  纯平面着色（建筑、树干这种要硬边的）
    smooth_angle > 0  按角度自动平滑：小于该夹角的边平滑过渡、大于的保持硬边。
                      石头需要它 —— 倒角面才会和相邻面融成一条渐亮的带，
                      而不是一条突兀的亮线。"""
    if smooth_angle > 0.0:
        bpy.context.view_layer.objects.active = obj
        for p in obj.data.polygons:
            p.use_smooth = True
        try:
            bpy.ops.object.shade_auto_smooth(angle=math.radians(smooth_angle))
        except Exception:
            # 老版本回退：按面夹角手动标锐边
            import bmesh as _bm
            bm = _bm.new()
            bm.from_mesh(obj.data)
            thr = math.cos(math.radians(smooth_angle))
            for e in bm.edges:
                if len(e.link_faces) == 2:
                    a, b = e.link_faces
                    e.smooth = a.normal.dot(b.normal) > thr
            bm.to_mesh(obj.data)
            bm.free()
    else:
        for p in obj.data.polygons:
            p.use_smooth = False
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
    obj.location = loc


def tris(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


# ------------------------------------------------------------------ 建筑 --


def bake_materials_to_vcol(obj, material="Surface", coarse=()):
    """把每个材质槽的颜色烘进顶点色，然后合并成单一材质。

    房屋原来是 8 个材质槽 = 8 次 draw call，而且因为它是 GLB 实例，
    Godot 侧挂不了 material_override（一挂就把 8 个部件冲成同一个颜色），
    于是生成器里那套 MAT["wall"]/MAT["roof"] 对房屋**根本没生效** ——
    屋顶墙面一直是 Blender 里的纯色。

    烘进顶点色之后：一个材质、一次 draw call，Godot 侧可以整体挂
    prop.gdshader，颜色照旧、还多出表面细节和法线扰动。

    COLOR.a 给着色器当细节尺度的选择器：coarse 里列出的材质名 -> 1（木头，
    纹理粗），其余 -> 0（石头/灰泥，纹理细）。"""
    me = obj.data
    cols = []
    for m in me.materials:
        c = (1.0, 1.0, 1.0)
        if m is not None and m.use_nodes:
            for nd in m.node_tree.nodes:
                if nd.type == "BSDF_PRINCIPLED":
                    v = nd.inputs["Base Color"].default_value
                    c = (v[0], v[1], v[2])       # Principled 的 Base Color 是线性的
                    break
        nm = m.name if m is not None else ""
        cols.append((c[0], c[1], c[2],
                     1.0 if any(k in nm for k in coarse) else 0.0))

    attr = me.color_attributes.get("Color")
    if attr is None:
        attr = me.color_attributes.new(name="Color", type="BYTE_COLOR",
                                       domain="CORNER")
    for p in me.polygons:
        cc = cols[p.material_index] if p.material_index < len(cols) else (1, 1, 1, 0)
        for li in p.loop_indices:
            attr.data[li].color = cc

    me.materials.clear()
    me.materials.append(mat(material))
    return obj


def uv_planar(obj, uv_scale=0.30, offset=(0.0, 0.0), long_axis_u=True):
    """按局部坐标做平面投影 UV，纹理**沿物件的长轴**跑。

    这是"外部贴图"这条路的入口：程序生成的网格默认没有可用的 UV
    （bmesh 建的完全没有；primitive 的每个面都铺满 0..1，尺度不一致），
    有了这一步，assets/textures/ 下的普通 PNG 就能直接贴上来，
    而且是**按米**铺的 —— 大小不同的木件纹理密度一致。

    每个面按法线的主轴投影到另外两轴；两轴里**较长的那个给 U**，
    于是木纹自然顺着板子、梁、立柱的长边走，不用逐件指定方向。
    long_axis_u=False 反过来（短边给 U）—— 屋面要用它：
    茅草的条纹应该**顺着坡**走，而屋面的长边是沿屋脊的。
    offset 给每件一个随机位移，否则所有木件的纹理完全一样。
    """
    me = obj.data
    sc = obj.scale
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uvl = me.uv_layers.active.data
    # 尺寸要从**网格包围盒**算，不能直接用 obj.scale：
    # primitive_cube_add 建的网格是 ±0.5 的单位立方体、尺寸在 scale 里，
    # 而 bmesh / from_pydata 建的（wedge、凸包）坐标已经是米、scale 是 1。
    # 只看 scale 的话，后者会被当成 1x1x1，长边判断随机。
    co_all = [v.co for v in me.vertices]
    size = [(max(c[i] for c in co_all) - min(c[i] for c in co_all)) * sc[i]
            for i in range(3)]
    for poly in me.polygons:
        n = poly.normal
        axis = max(range(3), key=lambda i: abs(n[i]))
        a, b = [i for i in range(3) if i != axis]
        want_long_u = long_axis_u
        if (size[a] < size[b]) == want_long_u:
            a, b = b, a
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uvl[li].uv = ((co[a] * sc[a]) * uv_scale + offset[0],
                          (co[b] * sc[b]) * uv_scale + offset[1])
    return obj


def bevel_edges(obj, width=0.03, segments=1, angle=25.0):
    """给硬表面加倒角。

    这是"过渡"层的活，着色器做不了 —— 倒角改变的是**侧影和受光**：
    90° 硬棱在任何光照下都是一条突变线，倒角面则会随朝向渐变。
    参考图里的木结构没有一条razor edge。

    宽度按物件尺寸给：桥板 0.02、立柱 0.03、大梁 0.04。
    给得太大在这个机位（29 px/m）下会把细木件啃圆。
    """
    bpy.context.view_layer.objects.active = obj
    m = obj.modifiers.new("bevel", "BEVEL")
    m.width = width
    m.segments = segments
    m.limit_method = "ANGLE"
    m.angle_limit = math.radians(angle)
    m.harden_normals = False
    bpy.ops.object.modifier_apply(modifier=m.name)
    return obj


def set_vcol(obj, colour_name, material="Foliage", alpha=0.0):
    """colour_name 可以是调色板里的名字，也可以直接给 (r,g,b) sRGB 三元组。"""
    """把颜色烘进顶点色，并统一材质。

    统一材质有两个作用：合并后只剩一个 surface（一次 draw call），
    以及 Godot 侧可以用一个 material_override 挂着色器而不冲掉任何东西。
    树干也必须走这条路 —— 否则 material_override 会把它一起冲成白色。

    **顶点色的 alpha 是"这是不是叶片贴片"的标志**：1 = 采样叶片图集并做
    alpha 裁剪，0 = 实体木头，强制不透明。合并成一个网格之后就靠它区分。"""
    me = obj.data
    src = (PALETTE[colour_name] if isinstance(colour_name, str)
           else colour_name)
    c = [srgb_to_linear(x) for x in src]
    attr = me.color_attributes.get("Color")
    if attr is None:
        attr = me.color_attributes.new(name="Color", type="BYTE_COLOR",
                                       domain="CORNER")
    for i in range(len(attr.data)):
        attr.data[i].color = (c[0], c[1], c[2], alpha)
    me.materials.clear()
    me.materials.append(mat(material))
    return obj


# ------------------------------------------------------------------ 导出 --


def export(path, label):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    # export_vertex_color 默认是 "MATERIAL"：只有材质引用了颜色属性才导出。
    # 叶簇的颜色全靠顶点色承载，漏掉就是一片白 —— 必须显式改成 "ACTIVE"。
    kw = dict(filepath=path, export_format="GLB", use_selection=False,
              export_apply=True, export_yup=True)
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(**kw)
    total = sum(tris(o) for o in bpy.context.scene.objects if o.type == "MESH")
    n = len([o for o in bpy.context.scene.objects if o.type == "MESH"])
    print("[assets] %-10s %d objects, %d tris -> %s (%.1f KB)"
          % (label, n, total, os.path.basename(path),
             os.path.getsize(path) / 1024.0), flush=True)
