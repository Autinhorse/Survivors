# -*- coding: utf-8 -*-
"""量 hellrider 画面里**纯地面**的明暗分布，和参考图同口径比。

为什么要单独一个脚本：`scene_audit.py` 量的是整张图（含熔岩、石头、树），
而"地面够不够有色块"这件事一旦把物体算进去就完全测不准 ——
一块石头就能把 std 抬一倍。所以这里只取写死的几块空地。

参考值来自 styles/hellrider/reference/zone_green_open.png 里
一块 750x310、不含任何物体的纯地面：

    总 std 5.54    半幅块均值 std 3.04    最亮:最暗 1.12

半幅块那一行是关键：它只留下大尺度的变化。参考图的总 std 里有一多半
来自"整片地不一样亮"，不是来自细格。
"""
import sys

import numpy as np
from PIL import Image

LUMA = np.array([0.2126, 0.7152, 0.0722])
# MINIMAL 调参场景里几块确定没有物体、没有 blob 影子的空地（1920x1080）
PATCHES = (((430, 860, 1470, 1070), "下方空地"),
           ((1010, 700, 1470, 1040), "右下空地"),
           ((1010, 355, 1470, 545), "右中空地"))
# 参考图两块干净地面，同口径量出来的区间。判据是**落在区间里**，
# 不是对齐某一个数 —— 参考图自己两块就差这么多。
REF = ((5.54, 3.04, 1.133), (6.12, 3.93, 1.188))


def block_std(lum, frac):
    h, w = lum.shape
    bs = max(4, int(min(w, h) * frac))
    ny, nx = h // bs, w // bs
    if ny < 2 or nx < 2:
        return float("nan")
    return lum[:ny * bs, :nx * bs].reshape(ny, bs, nx, bs).mean(axis=(1, 3)).std()


def main(path):
    im = np.asarray(Image.open(path).convert("RGB")).astype(float)
    print("%-10s %8s %8s %8s   %s" % ("区域", "总std", "半幅std", "亮:暗", "均值"))
    for (x0, y0, x1, y1), name in PATCHES:
        lum = im[y0:y1, x0:x1] @ LUMA
        # "亮:暗" 用 p98/p2 而不是 max/min：单个像素的抗锯齿边会污染极值
        hi, lo = np.percentile(lum, 98), np.percentile(lum, 2)
        print("%-10s %8.2f %8.2f %8.3f   %.1f"
              % (name, lum.std(), block_std(lum, 0.5), hi / max(lo, 1), lum.mean()))
    for (t, h, r), tag in zip(REF, ("参考 干净中央", "参考 右上")):
        print("%-10s %8.2f %8.2f %8.3f   <- zone_green_open" % (tag, t, h, r))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "shot.png")
