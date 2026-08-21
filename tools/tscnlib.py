# -*- coding: utf-8 -*-
"""`.tscn` 发射器：资源登记、变换、节点，以及占位检查。

**完全与美术风格无关。** 从 gen_greybox.py 里抽出来，
好让多个风格共用同一套场景生成机制（见 styles/README.md）。

用法上有一点要注意：这个模块持有**模块级的可变状态**
（extres / subres / nodes 三个登记表）。一次进程只生成一个场景，
所以没做成类；要在同一进程里生成多个场景，先调 reset()。
"""
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENES = os.path.join(ROOT, "scenes")


# ---------------------------------------------------------------- resources --
subres = []
_sub_ids = set()


def sub(rtype, rid, props=None, **kw):
    if rid not in _sub_ids:
        _sub_ids.add(rid)
        merged = dict(props or {})
        merged.update(kw)
        lines = ["%s = %s" % (k.replace("__", "/"), v) for k, v in merged.items()]
        subres.append((rtype, rid, lines))
    return 'SubResource("%s")' % rid


extres = []
_ext_ids = {}


def ext(rtype, path):
    """Reference an on-disk resource (shader, script) from the scene."""
    if path not in _ext_ids:
        rid = "ext_%d_%s" % (len(extres) + 1,
                             path.rsplit("/", 1)[-1].split(".")[0])
        _ext_ids[path] = rid
        extres.append((rtype, path, rid))
    return 'ExtResource("%s")' % _ext_ids[path]


def noise_tex(tid, freq, lo=0.60, hi=1.0, octaves=4, size=256, **noise_props):
    """Seamless noise texture, ramped so it multiplies albedo gently."""
    n = sub("FastNoiseLite", tid + "N",
            dict(frequency="%g" % freq, fractal_octaves=str(octaves),
                 **noise_props))
    g = sub("Gradient", tid + "G",
            offsets="PackedFloat32Array(0, 1)",
            colors="PackedColorArray(%g, %g, %g, 1, %g, %g, %g, 1)"
                   % (lo, lo, lo, hi, hi, hi))
    return sub("NoiseTexture2D", tid, noise=n, color_ramp=g, seamless="true",
               width=str(size), height=str(size))


def noise_normal(tid, freq, octaves=4, size=256, strength=12.0, **noise_props):
    """同一份噪声的法线图。

    实测目标图的屋顶/墙面细节比我们高约 30%，而且差的主要不是 albedo 的花纹，
    是**受光**：平坦的法线让每个面成为一块均匀的色板。
    NoiseTexture2D 自带 as_normal_map，不需要额外美术资源、也不需要 UV
    （材质走世界空间三平面投影）。

    **strength（NoiseTexture2D 的 bump_strength）默认是 8，别往下调。**
    这里第一版填了 1.4-2.4，结果整条法线贴图路径看着像"完全没生效" ——
    把 normal_scale 从 0.8 拉到 8.0（10 倍）画面纹丝不动。
    根因是这个尺度的分形噪声梯度本来就很平缓，bump_strength 再压低，
    算出来的法线几乎等于 (0,0,1)。用一张普通灰度噪声当法线图做对照实验，
    画面立刻有 4.4% 的像素变化 —— 才定位到不是渲染路径的问题。"""
    n = sub("FastNoiseLite", tid + "N",
            dict(frequency="%g" % freq, fractal_octaves=str(octaves),
                 **noise_props))
    return sub("NoiseTexture2D", tid, noise=n, seamless="true",
               as_normal_map="true", bump_strength="%g" % strength,
               width=str(size), height=str(size))


def shader_mat(name, shader_path, **params):
    props = {"shader": ext("Shader", shader_path)}
    for k, v in params.items():
        props["shader_parameter/" + k] = v
    return sub("ShaderMaterial", name, props)


def tex_mean(rel_path):
    """贴图的平均色，**在线性空间求平均**。

    第一版是先用 Image.BOX 降采样（等于在 sRGB 空间平均）再转线性 ——
    错的。sRGB->线性是凸函数，f(mean) < mean(f)，算出来的均值偏小，
    着色器里 tex/mean 就整体偏大：实测屋顶亮度 140，目标 68，
    而且被推到色调映射的肩部去，颜色跟着发白（R/B 1.31 vs 目标 2.43）。
    """
    import os
    import numpy as np
    from PIL import Image
    p = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     rel_path)
    a = np.asarray(Image.open(p).convert("RGB")).astype(np.float64) / 255.0
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    m = lin.reshape(-1, 3).mean(axis=0)
    return col(m[0], m[1], m[2])


def col(r, g, b, a=1.0):
    return "Color(%g, %g, %g, %g)" % (r, g, b, a)


def mat(name, rgb, rough=1.0, metal=0.0, alpha=None, tex=None, tex_scale=0.30,
        nrm=None, nrm_scale=1.0):
    """Flat or noise-textured StandardMaterial3D.

    Textures are projected triplanar in WORLD space so the surface reads at a
    consistent density across primitives that are non-uniformly scaled --
    every rock here is a squashed unit sphere."""
    rgba = rgb + ((alpha,) if alpha is not None else ())
    p = {"albedo_color": col(*rgba), "roughness": rough, "metallic": metal}
    if tex is not None:
        p["albedo_texture"] = tex
        p["uv1_triplanar"] = "true"
        p["uv1_world_triplanar"] = "true"
        p["uv1_scale"] = "Vector3(%g, %g, %g)" % (tex_scale, tex_scale, tex_scale)
    if nrm is not None:
        p["normal_enabled"] = "true"
        p["normal_texture"] = nrm
        p["normal_scale"] = "%g" % nrm_scale
    if alpha is not None:
        p["transparency"] = 1
    return sub("StandardMaterial3D", name, p)



def footprint(cx, cz, w, d, ry):
    """XZ 平面上的四角。ry 与 T() 的约定一致（绕 Y 轴，度）。"""
    c, sn = math.cos(math.radians(ry)), math.sin(math.radians(ry))
    return [(cx + dx * c + dz * sn, cz - dx * sn + dz * c)
            for dx, dz in ((-w / 2, -d / 2), (w / 2, -d / 2),
                           (w / 2, d / 2), (-w / 2, d / 2))]


def _overlap_1d(a0, a1, b0, b1):
    return min(a1, b1) - max(a0, b0)


def check_clearance(items, min_gap=0.6, allowed=()):
    """作者手摆的大件之间留没留出间距。

    桥加宽一倍之后和 HouseB 撞了，而这件事**在截图里很难看出来** ——
    60° 俯视下前后错开几米和真的重叠长得差不多，只有算一遍才知道。
    用轴对齐包围盒近似（都是接近轴向的矩形），够用了。

    allowed 列本来就该贴在一起的组合（比如引桥土坡和桥面端头）——
    否则真正的问题会淹没在预期内的报告里。
    """
    bad = []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            (n1, f1), (n2, f2) = items[i], items[j]
            ox = _overlap_1d(min(p[0] for p in f1), max(p[0] for p in f1),
                             min(p[0] for p in f2), max(p[0] for p in f2))
            oz = _overlap_1d(min(p[1] for p in f1), max(p[1] for p in f1),
                             min(p[1] for p in f2), max(p[1] for p in f2))
            gap = max(-ox, -oz)          # 两轴都重叠时为负 = 真重叠
            if gap < min_gap and (n1, n2) not in allowed and (n2, n1) not in allowed:
                bad.append((n1, n2, gap))
    for n1, n2, gap in bad:
        print("  [clearance] %s <-> %s : %s%.2f m"
              % (n1, n2, "重叠 " if gap < 0 else "间距 ", abs(gap)))
    return bad



# --------------------------------------------------------------- transforms --
def _emit(ax, ay, az, pos):
    """ax/ay/az are the basis COLUMNS (the transformed X/Y/Z axes).

    The .tscn text format serialises Transform3D by ROWS, i.e. the transpose of
    the column list -- verified against ResourceSaver output on Godot 4.7.
    """
    v = (ax[0], ay[0], az[0],
         ax[1], ay[1], az[1],
         ax[2], ay[2], az[2],
         pos[0], pos[1], pos[2])
    return "Transform3D(" + ", ".join("%.5f" % f for f in v) + ")"


def _matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)]
            for i in range(3)]


def T(pos=(0.0, 0.0, 0.0), ry=0.0, scale=(1.0, 1.0, 1.0), rx=0.0, rz=0.0):
    """Basis = Ry(ry) * Rz(rz) * Rx(rx) * Scale.

    用矩阵连乘而不是手推分量：手推过一版，rx 那几项是错的，
    而错法很隐蔽（只在同时给 ry 和 rx 时才看得出来）。
    rz 是做斜坡引桥用的 —— 沿桥向倾斜要绕 Z 转。
    """
    def rot_y(d):
        c, s_ = math.cos(math.radians(d)), math.sin(math.radians(d))
        return [[c, 0.0, s_], [0.0, 1.0, 0.0], [-s_, 0.0, c]]

    def rot_z(d):
        c, s_ = math.cos(math.radians(d)), math.sin(math.radians(d))
        return [[c, -s_, 0.0], [s_, c, 0.0], [0.0, 0.0, 1.0]]

    def rot_x(d):
        c, s_ = math.cos(math.radians(d)), math.sin(math.radians(d))
        return [[1.0, 0.0, 0.0], [0.0, c, -s_], [0.0, s_, c]]

    m = _matmul(_matmul(rot_y(ry), rot_z(rz)), rot_x(rx))
    ax = tuple(m[i][0] * scale[0] for i in range(3))
    ay = tuple(m[i][1] * scale[1] for i in range(3))
    az = tuple(m[i][2] * scale[2] for i in range(3))
    return _emit(ax, ay, az, pos)


def T_seg3(p0, p1, thickness):
    """把单位立方体拉成连接 p0 -> p1 的一根杆（真三维，不限于 XY 平面）。

    原来的 T_segment 只在 XY 平面里算，z 恒定 —— 桥绕 Y 轴转了 15.6°，
    拉索却拉在恒定 z 上，于是斜着穿过桥面。静帧上像一堆乱线。
    """
    d = [p1[i] - p0[i] for i in range(3)]
    ln = math.sqrt(sum(v * v for v in d)) or 1e-6
    ax = [v / ln for v in d]
    up = (0.0, 1.0, 0.0) if abs(ax[1]) < 0.95 else (1.0, 0.0, 0.0)
    az = [ax[1] * up[2] - ax[2] * up[1],
          ax[2] * up[0] - ax[0] * up[2],
          ax[0] * up[1] - ax[1] * up[0]]
    n = math.sqrt(sum(v * v for v in az)) or 1e-6
    az = [v / n for v in az]
    ay = [az[1] * ax[2] - az[2] * ax[1],
          az[2] * ax[0] - az[0] * ax[2],
          az[0] * ax[1] - az[1] * ax[0]]
    mid = tuple((p0[i] + p1[i]) * 0.5 for i in range(3))
    return _emit(tuple(v * ln for v in ax), tuple(v * thickness for v in ay),
                 tuple(v * thickness for v in az), mid)


def T_segment(p0, p1, thickness):
    """Unit box stretched along the XY-plane segment p0 -> p1 (cables, braces)."""
    (x0, y0, z0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    ln = math.hypot(dx, dy)
    ux, uy = dx / ln, dy / ln
    return _emit((ux * ln, uy * ln, 0.0),
                 (-uy * thickness, ux * thickness, 0.0),
                 (0.0, 0.0, thickness),
                 ((x0 + x1) / 2.0, (y0 + y1) / 2.0, z0))


# -------------------------------------------------------------------- nodes --
nodes = []


def node(name, ntype, parent, props=None, transform=None):
    head = '[node name="%s" type="%s" parent="%s"]' % (name, ntype, parent)
    body = []
    if transform:
        body.append("transform = " + transform)
    for k, v in (props or {}).items():
        body.append("%s = %s" % (k.replace("__", "/"), v))
    nodes.append(head + "\n" + "\n".join(body))
    return (parent + "/" + name) if parent != "." else name


def instance(name, parent, packed, transform=None, child=None, override=None):
    """实例化一个外部场景（GLB 导入后就是 PackedScene）。

    child/override：给实例内部的某个子节点挂 material_override。
    .tscn 里覆盖实例的子节点属性要单独起一个 [node] 段，
    名字必须和 GLB 里的节点名一致。"""
    head = '[node name="%s" parent="%s" instance=%s]' % (name, parent, packed)
    if transform:
        head = head + chr(10) + "transform = " + transform
    nodes.append(head)
    path = (parent + "/" + name) if parent != "." else name
    if child and override:
        nodes.append('[node name="%s" parent="%s" index="0"]%smaterial_override = %s'
                     % (child, path, chr(10), override))
    return path


def mesh(name, parent, meshres, material, pos=(0.0, 0.0, 0.0), ry=0.0,
         scale=(1.0, 1.0, 1.0), rx=0.0, cast_shadow=None, xform=None):
    p = {"mesh": meshres, "surface_material_override/0": material}
    if cast_shadow is not None:
        p["cast_shadow"] = cast_shadow
    return node(name, "MeshInstance3D", parent, p, xform or T(pos, ry, scale, rx))



def reset():
    """清空登记表，以便在同一进程里生成第二个场景。"""
    del extres[:], subres[:], nodes[:]
    _ext_by_path.clear()


def write_scene(path):
    with open(os.path.abspath(path), "w", encoding="utf-8") as f:
        f.write("[gd_scene load_steps=%d format=3]\n\n"
                % (len(extres) + len(subres) + 1))
        for rtype, p, rid in extres:
            f.write('[ext_resource type="%s" path="%s" id="%s"]\n'
                    % (rtype, p, rid))
        if extres:
            f.write("\n")
        for rtype, rid, lines in subres:
            f.write('[sub_resource type="%s" id="%s"]\n' % (rtype, rid))
            f.write("\n".join(lines) + "\n\n")
        f.write("\n\n".join(nodes) + "\n")
    return len(extres), len(subres), len(nodes)
