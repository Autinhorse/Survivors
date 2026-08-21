# -*- coding: utf-8 -*-
"""风格 "gatling" 的贴图：木纹、茅草、灰泥、岩石。

可外部编辑。

这些 PNG 是**普通图片文件**，程序只负责给出一版能用的初始内容。
之后你可以用任何画图软件直接改（或者整张换掉），
只要保持尺寸和"可平铺"这两点，重新导入就生效，不需要改代码。

    python styles/gatling/textures.py            # 全部
    python styles/gatling/textures.py wood       # 只生成木纹
                                                 # 可选: wood / thatch / plaster / rock

改完之后：
    Godot_v4.7-stable_win64_console.exe --path . --import --headless

平铺密度在 Godot 侧调（ShaderMaterial 的 uv_tex_scale），不用改图。
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "assets", "gatling", "textures")


def _tile_noise(size, rng, cells, lo, hi):
    """可平铺的低频噪声：在环面上取样本再双线性插值。"""
    g = [[rng.uniform(lo, hi) for _ in range(cells)] for _ in range(cells)]
    out = Image.new("F", (size, size))
    px = out.load()
    step = size / float(cells)
    for y in range(size):
        fy = y / step
        y0 = int(fy) % cells
        y1 = (y0 + 1) % cells
        ty = fy - int(fy)
        for x in range(size):
            fx = x / step
            x0 = int(fx) % cells
            x1 = (x0 + 1) % cells
            tx = fx - int(fx)
            a = g[y0][x0] * (1 - tx) + g[y0][x1] * tx
            b = g[y1][x0] * (1 - tx) + g[y1][x1] * tx
            px[x, y] = a * (1 - ty) + b * ty
    return out


def wood(size=512, seed=4):
    """木纹。纹理**沿 U 方向**跑 —— 桥板的 UV 就是按这个方向铺的。

    可平铺：所有随机源都在环面上取，横竖接缝都对得上。
    """
    rng = random.Random(seed)
    base = Image.new("RGB", (size, size), (208, 176, 140))
    px = base.load()

    warp = _tile_noise(size, rng, 6, -6.0, 6.0).load()
    fine = _tile_noise(size, rng, 40, -1.0, 1.0).load()

    for y in range(size):
        for x in range(size):
            # 年轮：沿 V 方向的条纹，被低频噪声扭一下，才不像斑马线
            v = y + warp[x, y]
            ring = math.sin(v * 0.55) * 0.5 + 0.5
            ring = ring ** 1.6
            grain = fine[x, y] * 0.10
            k = 0.72 + 0.28 * ring + grain
            k = max(0.35, min(1.15, k))
            px[x, y] = (int(208 * k), int(176 * k * 0.98), int(140 * k * 0.94))

    # 结疤：几个深色椭圆，边缘的年轮绕着走（这里只画结疤本身，够用）
    dr = ImageDraw.Draw(base)
    for _ in range(5):
        cx, cy = rng.randrange(size), rng.randrange(size)
        r = rng.randint(5, 11)
        for k in range(4, 0, -1):
            f = k / 4.0
            c = int(150 - 60 * (1 - f))
            dr.ellipse([cx - r * f, cy - r * f * 0.7,
                        cx + r * f, cy + r * f * 0.7],
                       fill=(c, int(c * 0.78), int(c * 0.58)))
    base = base.filter(ImageFilter.GaussianBlur(0.6))
    return base


def thatch(size=512, seed=11):
    """茅草。**条纹沿 U 方向跑**，UV 铺到屋面时让它顺着坡走。

    这是"值噪声做不出来"的典型：茅草的读法来自一束束草秆的**方向性**，
    各向同性的斑点无论怎么调都只是脏，不成材质。
    """
    rng = random.Random(seed)
    im = Image.new("RGB", (size, size), (150, 140, 96))
    px = im.load()
    warp = _tile_noise(size, rng, 5, -4.0, 4.0).load()
    fine = _tile_noise(size, rng, 64, -1.0, 1.0).load()

    # 一束束草：沿 V 方向切成宽窄不等的条，每条一个色调
    bands = []
    v = 0
    while v < size:
        h = rng.randint(4, 11)
        bands.append((v, min(size, v + h), rng.uniform(0.74, 1.16)))
        v += h
    # 让最后一条和第一条接得上（可平铺）
    band_of = [0] * size
    tone = [1.0] * size
    for i, (v0, v1, t) in enumerate(bands):
        for y in range(v0, v1):
            band_of[y] = i
            tone[y] = t

    for y in range(size):
        for x in range(size):
            yy = int((y + warp[x, y]) % size)
            k = tone[yy]
            # 束内还有更细的草秆
            k *= 1.0 + fine[x, y] * 0.13
            # 束与束之间的暗缝
            edge = 1.0
            if band_of[yy] != band_of[(yy + 1) % size]:
                edge = 0.72
            k *= edge
            k = max(0.35, min(1.25, k))
            px[x, y] = (int(150 * k), int(140 * k), int(96 * k * 0.95))
    return im.filter(ImageFilter.GaussianBlur(0.5))


def plaster(size=512, seed=23):
    """灰泥墙。大块的斑驳 + 细颗粒，还有几处露出底色的剥落。"""
    rng = random.Random(seed)
    im = Image.new("RGB", (size, size), (196, 184, 156))
    px = im.load()
    patch = _tile_noise(size, rng, 7, 0.86, 1.14).load()
    grain = _tile_noise(size, rng, 70, -1.0, 1.0).load()
    for y in range(size):
        for x in range(size):
            k = patch[x, y] * (1.0 + grain[x, y] * 0.06)
            k = max(0.6, min(1.3, k))
            px[x, y] = (int(196 * k), int(184 * k), int(156 * k))
    # 剥落：几块偏暗偏冷的斑
    dr = ImageDraw.Draw(im)
    for _ in range(7):
        cx, cy = rng.randrange(size), rng.randrange(size)
        r = rng.randint(9, 26)
        dr.ellipse([cx - r, cy - r * 0.72, cx + r, cy + r * 0.72],
                   fill=(138, 130, 116))
    return im.filter(ImageFilter.GaussianBlur(0.9))


def rock(size=512, seed=31):
    """岩石表面：大块斑驳 + 细颗粒 + 几道裂纹。

    石头之前"太光"的直接原因是贴图根本没挂上（MultiMesh 没有 material_override），
    但即使挂上，各向同性的值噪声也只是让它变脏。
    真正让石头读成石头的是**颗粒感 + 少量裂纹**这两个不同尺度的东西。
    """
    rng = random.Random(seed)
    im = Image.new("RGB", (size, size), (150, 143, 136))
    px = im.load()
    blotch = _tile_noise(size, rng, 6, 0.82, 1.18).load()
    mid = _tile_noise(size, rng, 22, 0.90, 1.10).load()
    grain = _tile_noise(size, rng, 96, -1.0, 1.0).load()
    for y in range(size):
        for x in range(size):
            k = blotch[x, y] * mid[x, y] * (1.0 + grain[x, y] * 0.11)
            k = max(0.55, min(1.35, k))
            px[x, y] = (int(150 * k), int(143 * k), int(136 * k * 0.99))

    # 裂纹：几条折线，两侧各有一点点亮边（受光的破口）
    dr = ImageDraw.Draw(im)
    for _ in range(4):
        x0, y0 = rng.randrange(size), rng.randrange(size)
        pts = [(x0, y0)]
        for _seg in range(rng.randint(3, 6)):
            x0 += rng.randint(-90, 90)
            y0 += rng.randint(-90, 90)
            pts.append((x0, y0))
        # 别太黑：这张图会被缩到每块石头几十像素，
        # 重线在那个尺度下读成黑斑，而不是裂纹
        dr.line(pts, fill=(124, 119, 114), width=1, joint="curve")
    return im.filter(ImageFilter.GaussianBlur(0.55))


TEXTURES = {"wood": ("wood_planks.png", wood),
            "thatch": ("thatch.png", thatch),
            "plaster": ("plaster.png", plaster),
            "rock": ("rock.png", rock)}


def main(names):
    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)
    for key in (names or TEXTURES.keys()):
        fn, gen = TEXTURES[key]
        path = os.path.join(OUT_DIR, fn)
        gen().save(path)
        print("[tex] %s  %d KB" % (fn, os.path.getsize(path) // 1024))


if __name__ == "__main__":
    main(sys.argv[1:])
