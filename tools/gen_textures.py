# -*- coding: utf-8 -*-
"""生成可外部编辑的贴图。

这些 PNG 是**普通图片文件**，程序只负责给出一版能用的初始内容。
之后你可以用任何画图软件直接改（或者整张换掉），
只要保持尺寸和"可平铺"这两点，重新导入就生效，不需要改代码。

    python tools/gen_textures.py                 # 全部
    python tools/gen_textures.py wood            # 只生成木纹

改完之后：
    Godot_v4.7-stable_win64_console.exe --path . --import --headless

平铺密度在 Godot 侧调（ShaderMaterial 的 uv_tex_scale），不用改图。
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "assets", "textures")


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


TEXTURES = {"wood": ("wood_planks.png", wood)}


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
