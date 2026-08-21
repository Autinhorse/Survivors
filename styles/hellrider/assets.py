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


def _components(me):
    """把网格按连通性分组，返回每个顶点属于第几块。

    **一组石头是一个网格里的 2-3 块独立几何。** 按整个物体的包围盒算高度，
    小的卫星石整块都落在低处，会被均匀压暗、内部一点梯度都没有 ——
    明暗就只剩 N·L 在决定，于是出现"两个暗面下面反而是个亮面"。
    高度类的烘焙必须**每块各算各的**。
    """
    n = len(me.vertices)
    par = list(range(n))

    def find(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a

    for e in me.edges:
        ra, rb = find(e.vertices[0]), find(e.vertices[1])
        if ra != rb:
            par[ra] = rb
    return [find(i) for i in range(n)]


def _comp_span(me, comp):
    """每个连通块自己的 z 范围。"""
    span = {}
    for i, v in enumerate(me.vertices):
        c = comp[i]
        lo, hi = span.get(c, (1e9, -1e9))
        span[c] = (min(lo, v.co.z), max(hi, v.co.z))
    return span


def vgrad(obj, amount=0.28):
    """把**垂直渐变**烘进顶点色：顶亮底暗。

    这是参考图和"纯平面着色"之间最大的一处差别，而且是量出来的：
    参考图里每个物体从上到下都在变暗（绿丛 120->92、树冠 120->89、
    石头 125->96），而单个面**内部**的 std 有 12-26；
    我们纯平面着色的面内 std 只有 0.45，死平。

    它不是贴图 —— 是烘在模型上的渐变。按**连通块**的包围盒算，
    所以一组石头里每一块、一棵树的树冠和树干各自都有完整的过渡。
    在合并之后、finalize 之前做，渐变才覆盖整个物体而不是每个部件各来一遍。
    """
    me = obj.data
    attr = me.color_attributes.get("Color")
    if attr is None:
        return obj
    comp = _components(me)
    span = _comp_span(me, comp)
    for poly in me.polygons:
        # **顶点色的 alpha 存这个面在自己那块几何里的相对高度**（0 底 1 顶）。
        # 着色器用它给 N·L 封顶，把"位置低的面"压下去 —— 这是唯一能让
        # "低处更暗"作用到**光照**上的办法：光是运行时算的，烘进 RGB 的
        # 偏置只改反照率，压不住一个朝光的下部面比背光的上部面亮两倍。
        # 高度在绕 Y 旋转下不变，所以烘它是安全的（光照方向就不是）。
        flo, fhi = span[comp[poly.vertices[0]]]
        hf = min(max((poly.center.z - flo) / max(fhi - flo, 1e-4), 0.0), 1.0)
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            lo, hi = span[comp[vi]]
            t = (me.vertices[vi].co.z - lo) / max(hi - lo, 1e-4)
            k = 1.0 - amount * (1.0 - t)
            c = attr.data[li].color
            attr.data[li].color = (c[0] * k, c[1] * k, c[2] * k, hf)
    return obj


def face_relax(obj, low_dark=0.20, base=0.03, slope=0.60, iters=40):
    """**逐面**按高度压暗，再做邻面约束松弛，结果乘进顶点色。

    要解决两个具体现象：

    1. 低处的面比它上面的面还亮。纯按 N·L 着色时完全可能 ——
       一个朝光倾斜的下部面，亮度可以超过一个背光的上部面。
       真实石头不会这样：低处被周围环境遮挡，本来就更暗。
       所以每个面按**面心在自己那块石头里的相对高度**加一个压暗偏置。
    2. 相邻两个面的色差要和法线差成比例。法线只差几度的两个面
       不该差一大截。

    第 2 条只能在这里做 —— 片元着色器看不到邻面，只有网格阶段有拓扑。
    做法是约束松弛：邻面允许的色差上限 = base + slope * 法线夹角/pi，
    超了就把两边各拉一半，迭代到收敛。夹角大的边界（顶面对侧面）上限很宽，
    硬边保留；夹角小的边界被压平，假台阶消失。

    约束的对象是**面的最终平均亮度**，不是高度偏置本身 —— 只约束自己那
    一项的话，tint 的逐面抖动照样能让两个近平行的面差出 0.2 以上。
    在对数域里松弛：约束说的是"相对色差"，而且对数不会把暗面推成负值。

    注意烘的量必须**旋转无关**：ScatterField 会给每个实例随机绕 Y 转。
    高度和法线夹角都满足，光照方向不满足 —— 所以方向性的明暗留在着色器里
    按世界法线算，这里只管高度和邻面平滑。
    """
    me = obj.data
    attr = me.color_attributes.get("Color")
    if attr is None or not me.polygons:
        return obj

    comp = _components(me)
    span = _comp_span(me, comp)

    lum, k = [], []
    for poly in me.polygons:
        t3 = [0.0, 0.0, 0.0]
        for li in poly.loop_indices:
            c = attr.data[li].color
            for x in range(3):
                t3[x] += c[x]
        n3 = float(len(poly.loop_indices))
        L = max((0.299 * t3[0] + 0.587 * t3[1] + 0.114 * t3[2]) / n3, 1e-5)
        lo, hi = span[comp[poly.vertices[0]]]
        h = min(max((poly.center.z - lo) / max(hi - lo, 1e-4), 0.0), 1.0)
        lum.append(L)
        k.append(math.log(L) + math.log(1.0 - low_dark * (1.0 - h)))

    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    pairs = []
    for e in bm.edges:
        if len(e.link_faces) != 2:
            continue
        f0, f1 = e.link_faces
        d = max(-1.0, min(1.0, f0.normal.dot(f1.normal)))
        pairs.append((f0.index, f1.index,
                      base + slope * (math.acos(d) / math.pi)))
    bm.free()

    for _it in range(iters):
        moved = 0.0
        for i, j, lim in pairs:
            d = k[i] - k[j]
            over = abs(d) - lim
            if over <= 0.0:
                continue
            step = over * 0.25 * (1.0 if d > 0.0 else -1.0)
            k[i] -= step
            k[j] += step
            moved += over
        if moved < 1e-5:
            break

    for poly in me.polygons:
        i = poly.index
        f = math.exp(k[i]) / lum[i]
        for li in poly.loop_indices:
            c = attr.data[li].color
            attr.data[li].color = (c[0] * f, c[1] * f, c[2] * f, c[3])
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
# 把参考图的石头放到最大看清楚之后，结构是这样的（前两版都理解错了）：
#
#   ┌─ 一整块**起伏的多面顶**：从边缘的窄台阶升上去，
#   │  几条脊线通向偏一侧的高点，各个顶点高度都不一样
#   ├─ 边缘一圈**窄台阶**（顶面折下来和墙相交的地方）
#   └─ 低矮的底座，侧壁**略微外撇**，不是垂直
#
# 走过的两条弯路：
#   v1 随机点凸包    —— 到处斜面，没有平顶（gatling 的语言，错的）
#   v2 两层锥台堆叠  —— 读成"平台上放了个方块"，参考图没有这么明显的分层
#
# 关键在于顶部是**一个连续的多面体表面**，靠顶点高度变化产生脊和坡，
# 而不是靠堆几何体。所以生成方式是：
#   外圈（墙顶）-> 中圈（抬高、高度按方向渐变 + 抖动）-> 顶点（最高，偏一侧）
# 三圈之间连三角面。"前后高度有变化"就是中圈那一圈的高度梯度。

def _rock_body(bm, rng, cx, cy, radius, wall_h, cap_h, sides,
               taper=0.30, jitter=0.20, flare=0.06, third_ring=False):
    """一块石头：**下环 + 上环**，上环三个方向各随机抖动。

    结构就两圈顶点，不堆层、不切割：

      下环  radius，贴地
      上环  radius*(1-taper)，高度 H —— **收进去**，所以侧面是斜的，不是垂直
            每个顶点在 x / y / z 三个方向各随机 ±jitter
            角度也相对下环错开，所以上下顶点**不垂直对应**

    上环因此不共面，顶面被三角化成几个不同朝向的面；
    侧面的每个四边形也因为上下不对齐而扭曲成两个朝向不同的三角形 ——
    明暗自然就碎开了，不需要另外做。

    走过的弯路（都是把简单问题做复杂了）：
      v1 随机点凸包        到处斜面，没有平顶
      v2 两层锥台堆叠      读成"平台上放了个方块"，分层太明显
      v3/v4 外圈连内圈     收敛成穹顶或土包
      v5-v7 平面切割       切出来太"方"，侧面接近垂直
    """
    H = wall_h + cap_h
    rot = rng.uniform(0.0, math.tau)

    lo, hi = [], []
    base_ang = []
    a = 0.0
    for _i in range(sides):
        a += math.tau / sides * rng.uniform(0.86, 1.14)
        base_ang.append(a + rot)

    for i in range(sides):
        ca, sa = math.cos(base_ang[i]), math.sin(base_ang[i])
        k = radius * rng.uniform(0.92, 1.06)
        lo.append(bm.verts.new((cx + ca * k * (1.0 + flare),
                                cy + sa * k * (1.0 + flare), 0.0)))

    # 上环：三个方向各抖 jitter，角度也错开，所以上下顶点不垂直对应。
    #
    # 但抖动要**沿环平滑一次**：相邻两个节点各自独立随机，很容易一个往上
    # 一个往下，把它们之间那片侧面折出很陡的角。量过一次 —— 同一圈侧壁上
    # 出现过法线夹角 52°、60° 的邻面，配合光照量化就变成"下面那个面比上面
    # 亮两倍"。平滑保留整体起伏的幅度，只压掉这种高频对折。
    dr = [rng.uniform(-jitter, jitter) for _ in range(sides)]
    dz = [rng.uniform(-jitter, jitter) for _ in range(sides)]
    dx = [rng.uniform(-jitter, jitter) for _ in range(sides)]
    dy = [rng.uniform(-jitter, jitter) for _ in range(sides)]
    da = [rng.uniform(-0.30, 0.30) for _ in range(sides)]
    for arr in (dr, dz, dx, dy, da):
        sm = [0.5 * arr[i] + 0.25 * (arr[i - 1] + arr[(i + 1) % sides])
              for i in range(sides)]
        arr[:] = [v / 0.75 for v in sm]     # 平滑会缩幅度，除回去

    for i in range(sides):
        ta = base_ang[i] + math.tau / sides * da[i]
        rt = radius * (1.0 - taper) * (1.0 + dr[i])
        hz = H * (1.0 + dz[i])
        hi.append(bm.verts.new((cx + math.cos(ta) * rt + radius * dx[i] * 0.35,
                                cy + math.sin(ta) * rt + radius * dy[i] * 0.35,
                                hz)))

    bm.faces.new(list(reversed(lo)))
    for i in range(sides):
        j = (i + 1) % sides
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))

    base_xy = [(v.co.x, v.co.y) for v in lo]
    if not third_ring:
        bm.faces.new(hi)      # 上环不共面，三角化后是几个不同朝向的面
        return base_xy

    # 大石块再加一环：向内收 50%，随机增删 1-2 个节点，再三轴抖 25%。
    #
    # 增删节点是关键的一步 —— 只抖位置的话，上下两环的顶点数一样，
    # 侧面永远是规整的一圈四边形；增删之后环与环的拓扑就对不齐了，
    # 面的大小和朝向自然参差。用 bridge_loops 连接，它能处理两环点数不同。
    top_ang = []
    n = len(hi)
    keep = list(range(n))
    ops = rng.randint(1, 2)
    for _o in range(ops):
        if rng.random() < 0.5 and len(keep) > 4:
            keep.pop(rng.randrange(len(keep)))          # 去掉一个，相邻自然连上
        else:
            k = rng.randrange(len(keep))                # 在两个之间插一个
            keep.insert(k + 1, (keep[k], keep[(k + 1) % len(keep)]))

    top = []
    for e in keep:
        if isinstance(e, tuple):
            a0, a1 = base_ang[e[0]], base_ang[e[1]]
            if a1 < a0:
                a1 += math.tau
            ta = (a0 + a1) * 0.5
        else:
            ta = base_ang[e]
        rt = radius * (1.0 - taper) * 0.50 * (1.0 + rng.uniform(-0.25, 0.25))
        tz = H * (1.0 + cap_h / max(H, 1e-4) * 0.35) * (1.0 + rng.uniform(-0.25, 0.25))
        top.append(bm.verts.new((cx + math.cos(ta) * rt
                                 + radius * rng.uniform(-0.25, 0.25) * 0.30,
                                 cy + math.sin(ta) * rt
                                 + radius * rng.uniform(-0.25, 0.25) * 0.30,
                                 tz)))
    # 上环的边已经被侧面四边形建过了，直接 new 会 "this edge exists"
    def _edge(a, b):
        e = bm.edges.get((a, b))
        return e if e else bm.edges.new((a, b))

    hi_edges = [_edge(hi[i], hi[(i + 1) % len(hi)]) for i in range(len(hi))]
    tp_edges = [_edge(top[i], top[(i + 1) % len(top)]) for i in range(len(top))]
    bmesh.ops.bridge_loops(bm, edges=hi_edges + tp_edges)
    bm.faces.new(top)
    return base_xy


# 每个变体是一组石头：(半径, 墙高, 顶高, 边数, x, y)
# 参考图的石头成组出现：一大配两三小、挤在一起、共享底边。
# 让**变体本身就是一组** —— 散布器撒出来的"组"间距均匀、朝向随机，读起来还是散的。
ROCK_GROUPS = {
    "big":   [(1.85, 0.70, 0.75, 6, 0.00, 0.00),
              (0.85, 0.34, 0.34, 5, 2.30, -0.95),
              (0.50, 0.20, 0.20, 5, -1.95, 1.05)],
    "twin":  [(1.45, 0.62, 0.62, 6, 0.00, 0.00),
              (1.05, 0.48, 0.48, 5, 2.05, 0.80)],
    "spire": [(1.00, 0.85, 0.85, 5, 0.00, 0.00),
              (0.60, 0.26, 0.26, 5, 1.50, -0.85)],
    "low":   [(1.95, 0.45, 0.45, 7, 0.00, 0.00),
              (0.75, 0.30, 0.30, 5, 2.15, 0.95)],
    "block": [(1.20, 0.72, 0.72, 5, 0.00, 0.00)],
    "slab":  [(2.10, 0.36, 0.36, 7, 0.00, 0.00),
              (0.48, 0.18, 0.18, 5, 2.30, -0.70)],
}


def _fit_ellipse(pts):
    """把底环的多边形拟合成一个椭圆：(cx, cy, rx, ry, 角度)。

    假阴影要"配合石块底面形状缩放旋转"，所以量的是**真实底环**，
    不是拍脑袋给个半径。用二阶矩求主轴 —— 多边形顶点分布的协方差
    矩阵，特征向量就是长短轴方向，特征值开方按 2 倍缩放回外接尺度。
    """
    n = len(pts)
    cx = sum(p[0] for p in pts) / n
    cy = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - cx) ** 2 for p in pts) / n
    syy = sum((p[1] - cy) ** 2 for p in pts) / n
    sxy = sum((p[0] - cx) * (p[1] - cy) for p in pts) / n
    # 2x2 对称矩阵的特征分解，手写比拉 numpy 进 Blender 省事
    tr, det = sxx + syy, sxx * syy - sxy * sxy
    disc = max(tr * tr * 0.25 - det, 0.0) ** 0.5
    l0, l1 = tr * 0.5 + disc, tr * 0.5 - disc
    ang = 0.5 * math.atan2(2.0 * sxy, sxx - syy)
    # 均匀分布在圆周上的 n 个点，二阶矩是 R^2/2 —— 所以乘 sqrt(2) 回到半径
    k = 2.0 ** 0.5
    return (cx, cy, max(l0, 1e-6) ** 0.5 * k, max(l1, 1e-6) ** 0.5 * k, ang)


ROCK_FOOTPRINT = {}      # 变体名 -> [(cx, cy, rx, ry, ang), ...]，导出给布局用


def rock(name, shape, loc=(0, 0, 0)):
    rng = seeded(name)
    foot = []
    bm = bmesh.new()
    for radius, wall_h, cap_h, sides, cx, cy in ROCK_GROUPS[shape]:
        # 只有够大的块才加第三环：小石头加了反而碎
        base = _rock_body(bm, rng, cx, cy, radius, wall_h, cap_h, sides,
                          third_ring=(radius > 0.95))
        foot.append(_fit_ellipse(base))
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    tint(o, "Rock", rng, 0.04)
    vgrad(o, 0.24)
    face_relax(o, low_dark=0.20)
    finalize(o, loc, smooth_angle=0.0)
    ROCK_FOOTPRINT[shape] = foot
    return o


def _check_glb_order(path, expect):
    """核对 GLB 里的节点顺序真的等于我们写侧表用的顺序。

    ScatterField 是按 GLB 的节点顺序取变体的，而"每变体侧表"（底面椭圆
    那类）是我们在 Python 里排出来的。两个顺序对不上，影子就和石头错位。

    这个坑踩过三次，每次都是渲染出来才看见：
      1. 按声明顺序写表，而 glTF 是按名字排的
      2. Python 的 sorted 是 ASCII 排序，Blender 的是大小写不敏感排序
         （'L' < 'c' 对 'c' < 'L'）
    自检只有几行，不一致直接抛错，比再看一次渲染图便宜得多。
    """
    import struct
    import json as _json
    with open(path, "rb") as f:
        d = f.read()
    ln = struct.unpack_from("<I", d, 12)[0]
    got = [n["name"] for n in _json.loads(d[20:20 + ln].decode("utf-8"))["nodes"]]
    if got != list(expect):
        raise RuntimeError("GLB 节点顺序和侧表顺序不一致： glb=%s 表=%s"
                           % (got, list(expect)))


def build_rocks(out_dir):
    clear()
    for i, shape in enumerate(ROCK_GROUPS):
        rock("rock_%s" % shape, shape, loc=(i * 7.0 - 17.0, 0, 0))
    export(os.path.join(out_dir, "rocks.glb"), "rocks")
    # 底面椭圆表给布局用来摆假阴影。Blender 的 XY -> Godot 的 X/-Z，
    # 这里只存 Blender 空间的原始值，坐标系转换留给布局做一次就好。
    #
    # **顺序必须按物体名排序**，不能按 ROCK_GROUPS 的声明顺序。
    # glTF 导出的节点是按名字字母序排的（big/block/low/slab/spire/twin），
    # 而 ScatterField 是按 GLB 里的节点顺序取变体的。第一版按声明顺序写，
    # 结果影子和石头对不上号 —— 一块小石头顶着一组大石头的影子。
    # 凡是给 GLB 配的"每变体侧表"，都得按 GLB 的节点顺序来。
    import json
    order = sorted(ROCK_GROUPS, key=lambda k: "rock_" + k)
    _check_glb_order(os.path.join(out_dir, "rocks.glb"),
                     ["rock_" + k for k in order])
    with open(os.path.join(out_dir, "rocks_footprint.json"), "w") as fp:
        json.dump([ROCK_FOOTPRINT[k] for k in order], fp, indent=1)

    clear()
    for i, shape in enumerate(("block", "low", "slab", "twin")):
        o = rock("pebble_%d" % i, shape, loc=(i * 2.0 - 3.0, 0, 0))
        o.scale = (0.16, 0.16, 0.15)
    export(os.path.join(out_dir, "pebbles.glb"), "pebbles")


# -------------------------------------------------------------------- 树 --
# 树冠团的几种形状。全用同一个二十面体的话，不管怎么摆位置，
# 每一团的刻面图案都一模一样，凑近了就露馅。
#
#   ball   二十面体，随机转向          —— 圆的一团
#   long   二十面体沿一个水平轴拉长     —— 横着的一簇
#   drum   六棱台，上小下大，顶面是平的 —— 像被削掉一块
#   spike  六棱锥，顶尖削平             —— **只能做单团的树**，不参与拼团
#
# spike 拼进多团树冠里很怪：其它团是圆的，中间冒一个锥体读起来像插了根
# 东西，不像同一棵树的树叶。留着是给以后做单团的针叶树用的。
# 都控制在 20 面左右，和原来的二十面体持平。
LOBE_KINDS = ("ball", "long", "drum")
LOBE_SOLO = ("spike",)


def _prism(r0, r1, h, sides, rng, jitter=0.12):
    """棱台。r1 接近 r0 是鼓，接近 0 是锥。顶面留一点不收到尖 ——
    真收成一个点的话顶上会出现一圈很细的三角形，分档着色下闪得厉害。"""
    bm = bmesh.new()
    ang = [math.tau * i / sides + rng.uniform(-0.18, 0.18)
           for i in range(sides)]
    lo, hi = [], []
    for i in range(sides):
        ca, sa = math.cos(ang[i]), math.sin(ang[i])
        k0 = r0 * (1.0 + rng.uniform(-jitter, jitter))
        k1 = r1 * (1.0 + rng.uniform(-jitter, jitter))
        lo.append(bm.verts.new((ca * k0, sa * k0, -h * 0.5)))
        hi.append(bm.verts.new((ca * k1, sa * k1,
                                h * 0.5 * (1.0 + rng.uniform(-0.10, 0.10)))))
    bm.faces.new(list(reversed(lo)))
    bm.faces.new(hi)
    for i in range(sides):
        j = (i + 1) % sides
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new("lobe")
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new("lobe", me)
    bpy.context.collection.objects.link(o)
    o.data.materials.append(mat("Leaf"))
    return o


def _lobe(kind, r, pos, flat_z, rng):
    """按 kind 造一团树叶，摆到 pos。"""
    yaw = rng.uniform(0.0, math.tau)
    if kind == "drum":
        o = _prism(r * 1.06, r * 0.74, r * 1.22, 6, rng)
        o.rotation_euler = (rng.uniform(-0.16, 0.16), 0.0, yaw)
    elif kind == "spike":
        o = _prism(r * 1.00, r * 0.30, r * 1.80, 6, rng)
        o.rotation_euler = (rng.uniform(-0.12, 0.12), 0.0, yaw)
    else:
        o = ico(r, (0, 0, 0), "Leaf", subdiv=1,
                rot=(rng.uniform(0, math.tau), rng.uniform(0, math.tau), yaw))
        if kind == "long":
            # 先转到随机方位再拉长，所以长轴方向也是随机的
            o.scale = (1.34, 0.82, 0.92 * flat_z)
        else:
            o.scale = (1.0, 1.0, flat_z)
    o.location = pos
    return o


# 每个变体一套**不同的比例**，不是同一个模型缩放。
# 之前 4 个变体只改了总高和冠半径，等比缩放之后读起来就是同一棵树。
# (总高, 冠半径, 团数, 树干占总高, 冠的扁平, 树干倾斜, 各团形状)
TREE_SHAPES = (
    (4.6, 1.70, 3, 0.44, 1.12, 0.00, ("ball", "long", "ball")),
    (5.8, 1.72, 4, 0.48, 0.92, 0.07, ("drum", "ball", "long", "drum")),
    (3.7, 1.55, 2, 0.52, 1.26, 0.12, ("long", "ball")),
    (5.2, 1.62, 3, 0.46, 1.00, 0.05, ("long", "drum", "ball")),
)


def tree(name, loc=(0, 0, 0), shape=0, seed=0):
    """细杆 + 几团低面球。参考图就是这么简单 —— 没有枝、没有贴片。

    树冠是**几个平等的团围着共同重心**，不是"一个主球在中轴上、其它球
    从顶上冒出来"。后者读起来是个球上长了两个瘤：中心那团明显是主体，
    旁边的像多余的附件。正确的读法是几团有大有小、都偏离中轴一点，
    但**合起来的质心落在树干上**。

    所以生成顺序是反的：先定各团的半径（有大有小）和方位，
    再按体积加权求质心、整体平移回中轴。没有"主球"这个概念。

    相邻团的心距取 0.55-0.75 倍半径和：小于这个读成一坨，大于就散架。
    第一版是"主球 + 探出 0.12 冠半径的小球"，缩小之后只剩交线上一条缝。

    各团同色系。深浅交给分档光照和 vgrad 去产生，不要在颜色上先分好 ——
    各团是独立连通块，vgrad 和 COLOR.a 会各给各的顶亮底暗。
    """
    rng = seeded(name)
    height, crown, lobes, trunk_f, flat_z, lean, kinds = TREE_SHAPES[shape]
    parts = []

    th = height * trunk_f
    # 树干更细：参考图里树干只有两三个像素宽
    tr = cyl(0.10, th, (0, 0, th * 0.5), "Trunk", verts=5)
    tr.rotation_euler = (lean, 0.0, rng.uniform(0.0, math.tau))
    parts.append(tint(tr, "Trunk", rng, 0.04))

    # 有大有小，最大的那团定尺度
    rs = [rng.uniform(0.60, 1.0) for _ in range(lobes)]
    rs = [crown * r / max(rs) for r in rs]

    if lobes > 1:
        mean_r = sum(rs) / lobes
        sep = rng.uniform(0.55, 0.75) * 2.0 * mean_r      # 目标相邻心距
        ring = sep / (2.0 * math.sin(math.pi / lobes))
    else:
        ring = 0.0

    a0 = rng.uniform(0.0, math.tau)
    pos = []
    for i in range(lobes):
        ang = a0 + math.tau * i / lobes + rng.uniform(-0.30, 0.30)
        dd = ring * rng.uniform(0.85, 1.15)
        pos.append([math.cos(ang) * dd, math.sin(ang) * dd,
                    crown * rng.uniform(-0.26, 0.26)])

    # 相邻团心距松弛到 0.50-0.75 倍半径和。
    # 半径有大有小时，光按均值算的环半径会让某一对拉到 1.10 ——
    # 那两个球根本不相交，读出来是飘在旁边的一团。
    for _it in range(24):
        moved = 0.0
        for i in range(lobes):
            j = (i + 1) % lobes
            if i == j:
                break
            dv = [pos[j][k] - pos[i][k] for k in range(3)]
            d = max(math.hypot(math.hypot(dv[0], dv[1]), dv[2]), 1e-5)
            want = min(max(d / (rs[i] + rs[j]), 0.50), 0.75) * (rs[i] + rs[j])
            f = (want - d) / d * 0.5
            moved += abs(want - d)
            for k in range(3):
                pos[i][k] -= dv[k] * f * 0.5
                pos[j][k] += dv[k] * f * 0.5
        if moved < 1e-4:
            break

    # 按体积加权把质心拉回中轴：整体平衡，没有哪一团是"中心"
    w = [r ** 3 for r in rs]
    tw = sum(w)
    for k in range(3):
        c0 = sum(p[k] * wi for p, wi in zip(pos, w)) / tw
        for p in pos:
            p[k] -= c0

    cz = th + crown * 0.62
    for i, (r, p) in enumerate(zip(rs, pos)):
        o = _lobe(kinds[i % len(kinds)], r, (p[0], p[1], cz + p[2]),
                  flat_z, rng)
        parts.append(tint(o, "Leaf", rng, 0.07))

    # 打印判读用的两个数：相邻团心距/半径和（0.55-0.75 才读得出是几团），
    # 以及质心偏移（应当≈0，否则树冠是歪的）。改比例时很容易无声地跑掉。
    gaps = []
    for i in range(lobes):
        j = (i + 1) % lobes
        if lobes < 2:
            break
        d = math.dist(pos[i], pos[j])
        gaps.append(d / (rs[i] + rs[j]))
    off = math.hypot(sum(p[0] * wi for p, wi in zip(pos, w)) / tw,
                     sum(p[1] * wi for p, wi in zip(pos, w)) / tw) / crown
    print("  %-8s %d 团 %-24s 心距/半径和 %s，质心偏移 %.3f"
          % (name, lobes, "+".join(kinds),
             ", ".join("%.2f" % g for g in gaps) or "-", off))
    return flat(parts, name, loc)


def bush(name, loc=(0, 0, 0), radius=0.85, seed=0):
    rng = seeded(name)
    b = ico(radius, (0, 0, radius * 0.62), "Leaf", subdiv=1)
    b.scale = (1.15, 1.0, 0.72)
    tint(b, "Leaf" if rng.random() < 0.6 else "LeafDeep", rng, 0.10)
    return flat([b], name, loc)


def build_trees(out_dir):
    clear()
    for i in range(len(TREE_SHAPES)):
        tree("tree_%d" % i, (i * 6.0 - 9.0, 0, 0), shape=i, seed=i)
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
