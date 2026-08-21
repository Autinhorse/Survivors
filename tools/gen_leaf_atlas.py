"""生成叶片 alpha 图集。

target.png 的树冠是**细枝干 + 一片片独立叶子贴片**，中间透光、能看见底下的影子。
之前用实体几何堆叶簇，无论怎么调都是"一坨"，因为实体不可能透光。

图集是 2x2 四块，每块一小簇叶子（贴在枝头）。
RGB 存的是**明暗变化**而不是颜色 —— 真正的颜色来自顶点色（每株植物一个色系），
这样一张图集就能同时长出深绿、黄绿、红褐、紫花。
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw

TILE = 512
SS = 3          # 超采样倍数，边缘才不会有锯齿
GRID = 2


def leaf(dr, cx, cy, length, width, angle, shade):
    """一片叶子：椭圆 + 一头收尖，接近参考图里的水滴形。"""
    pts = []
    n = 14
    for i in range(n + 1):
        t = i / float(n) * math.pi
        # 上半轮廓，尖端在 t=0
        r = math.sin(t) ** 0.62
        pts.append((math.cos(t) * length * 0.5, r * width * 0.5))
    for i in range(n, -1, -1):
        t = i / float(n) * math.pi
        r = math.sin(t) ** 0.62
        pts.append((math.cos(t) * length * 0.5, -r * width * 0.5))
    ca, sa = math.cos(angle), math.sin(angle)
    poly = [(cx + x * ca - y * sa, cy + x * sa + y * ca) for x, y in pts]
    v = int(shade * 255)
    dr.polygon(poly, fill=(v, v, v, 255))
    # 叶脉：一条略暗的中线，放大看才有细节，缩小后只是轻微的明暗
    d = int(shade * 200)
    dr.line([(cx - ca * length * 0.42, cy - sa * length * 0.42),
             (cx + ca * length * 0.42, cy + sa * length * 0.42)],
            fill=(d, d, d, 255), width=max(1, int(width * 0.06)))


def sprig(rng, size, count, lmin, lmax):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dr = ImageDraw.Draw(im)
    c = size * 0.5
    for i in range(count):
        # 极坐标撒点：中心密、边缘稀，一簇叶子才有中心
        a = rng.uniform(0.0, math.tau)
        r = (rng.uniform(0.0, 1.0) ** 0.55) * size * 0.32
        ln = rng.uniform(lmin, lmax) * size
        wd = ln * rng.uniform(0.30, 0.44)
        # 叶子大体朝外，像是从枝头向四周张开
        ang = a + rng.uniform(-0.9, 0.9)
        leaf(dr, c + math.cos(a) * r, c + math.sin(a) * r, ln, wd, ang,
             rng.uniform(0.62, 1.0))
    return im


def main(out_path):
    rng = random.Random(20260821)
    big = Image.new("RGBA", (TILE * GRID * SS, TILE * GRID * SS), (0, 0, 0, 0))
    # 一张贴片在游戏机位下只有 30-40 像素，单片叶子约 6 像素 ——
    # 稀疏的簇会糊成灰点，必须画密
    specs = [(58, 0.13, 0.22), (44, 0.16, 0.27),
             (72, 0.10, 0.18), (36, 0.19, 0.30)]
    for i, (n, a, b) in enumerate(specs):
        s = sprig(rng, TILE * SS, n, a, b)
        big.paste(s, ((i % GRID) * TILE * SS, (i // GRID) * TILE * SS))
    out = big.resize((TILE * GRID, TILE * GRID), Image.LANCZOS)
    # 边缘的半透明像素要有合理的 RGB，否则 alpha scissor 之后会渗出黑边
    px = out.load()
    for y in range(out.size[1]):
        for x in range(out.size[0]):
            r, g, b, al = px[x, y]
            if al == 0:
                px[x, y] = (200, 200, 200, 0)
    out.save(out_path)
    cov = sum(1 for y in range(0, out.size[1], 4) for x in range(0, out.size[0], 4)
              if px[x, y][3] > 128)
    total = (out.size[0] // 4) * (out.size[1] // 4)
    print("[leaf] %s %dx%d  不透明面积占比 %.1f%%"
          % (os.path.basename(out_path), out.size[0], out.size[1],
             100.0 * cov / total))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1
         else "assets/environment/leaf_atlas.png")
