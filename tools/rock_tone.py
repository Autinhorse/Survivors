# -*- coding: utf-8 -*-
"""量石头表面的色阶结构。

给 hellrider 用：石头是低饱和的浅棕，地面是高饱和的橙 ——
r-b 差值把两者分得很干净（石头 40-90，地面 130+）。

报三个数：
  级数      —— 表面上能分出几个明确的亮度台阶（风格要求 3-4 级硬边）
  暗侧跨度  —— **暗面内部**还有多少层次。clamp(dot(N,L),0,1) 会把所有
               背光面压成同一个值，这个数就会掉到 0 附近
  亮/暗比   —— 整体明暗对比
"""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage


def rock_mask(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (r > 130) & (r < 252) & (r - b > 30) & (r - b < 95) & (g > b + 10)


def report(path, tag):
    a = np.array(Image.open(path).convert("RGB")).astype(float)
    L = a @ [0.299, 0.587, 0.114]
    m = rock_mask(a)
    v = L[m]
    if v.size < 500:
        print("%-22s 石头像素太少 (%d)" % (tag, v.size))
        return
    # 级数：直方图上的峰。3 像素平滑之后找局部极大
    h, _ = np.histogram(v, bins=64, range=(v.min(), v.max()))
    h = ndimage.uniform_filter1d(h.astype(float), 3)
    pk = int(((h[1:-1] > h[:-2]) & (h[1:-1] >= h[2:]) &
              (h[1:-1] > h.max() * 0.08)).sum())
    med = np.median(v)
    dark = v[v < med]
    spread = (np.percentile(dark, 85) - np.percentile(dark, 15)) / med
    # 最坏邻面跳变：面内是平的，所以 3x3 窗口的极差只在**面与面的交界**
    # 上非零。取高分位就是"相邻两个面最大差多少"。用来盯量化档位造成的
    # 硬跳 —— 法线只差几度的两个面不该差一整档。
    Lm = np.where(m, L, np.nan)
    mx = ndimage.maximum_filter(np.nan_to_num(Lm, nan=-1e9), 3)
    mn = ndimage.minimum_filter(np.nan_to_num(Lm, nan=+1e9), 3)
    edge = (mx - mn)[m]
    edge = edge[np.isfinite(edge) & (edge < 1e6)]
    jump = np.percentile(edge, 99.5) / med if edge.size else float("nan")
    print("%-22s px=%6d  级数 %d  暗侧跨度 %.3f  暗端/亮端 %.2f  最坏邻面跳变 %.3f"
          % (tag, v.size, pk, spread,
             np.percentile(v, 10) / np.percentile(v, 90), jump))


if __name__ == "__main__":
    for i in range(1, len(sys.argv), 2):
        report(sys.argv[i], sys.argv[i + 1])
