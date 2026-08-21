# -*- coding: utf-8 -*-
"""整幅画面级别的对照：色相、饱和度、明暗层次、疏密节奏。

`surface_detail.py` 量的是"一块表面内部"的细节；这个量的是**整张图的组织**：
太黄不太黄、光平不平、够不够疏密有致。这些是靠眼睛最容易判断错的东西 ——
一整片暖色调里，任何偏冷的东西都会被看成"发蓝"，
而整体黄不黄只能和参考图**同口径**比才有意义。

    python tools/scene_audit.py shot.png docs/target.png

输出的几个量：

  亮度 p90/p10   明暗层次。**不是越大越好** —— 要和参考图对齐。
                 这个项目里"光照偏平，该加对比"的直觉错过两次。
  地面色相       0.083=橙 0.125=黄 0.167=黄绿 0.25=绿。
                 判断"该不该往绿调"只能看这个，不能看感觉。
  亮于 170/200   过曝和"发白"的客观判据（水面用得上）。
  安静块占比     32x32 分块里 std < 8 的比例 = 画面里"没有东西"的区域有多少。
                 疏密节奏的量化，参考图通常明显高于程序化撒点的场景。
"""
import colorsys
import sys

import numpy as np
from PIL import Image

LUMA = np.array([0.2126, 0.7152, 0.0722])


def load(path, width=1280):
    im = Image.open(path).convert("RGB")
    h = int(round(im.size[1] * float(width) / im.size[0]))
    return np.asarray(im.resize((width, h), Image.LANCZOS)).astype(float)


def ground_mask(a):
    """地面像素的粗略掩码：暖色、中等亮度。用于比较"地面固有色"。"""
    r, b = a[..., 0], a[..., 2]
    lum = a @ LUMA
    return (r > b * 1.6) & (lum > 60) & (lum < 190)


def quiet_fraction(lum, tile=32, thresh=8.0):
    h, w = lum.shape
    vals = [lum[y:y + tile, x:x + tile].std()
            for y in range(0, h - tile + 1, tile)
            for x in range(0, w - tile + 1, tile)]
    vals = np.array(vals)
    return float((vals < thresh).mean()), float(np.median(vals))


def audit(path):
    a = load(path)
    lum = a @ LUMA
    mx = a.max(axis=2)
    sat = np.where(mx > 0, (mx - a.min(axis=2)) / np.maximum(mx, 1e-6), 0.0)
    gm = ground_mask(a)
    gr = a[gm]
    rs = np.random.RandomState(0)
    idx = rs.choice(len(gr), size=min(4000, len(gr)), replace=False)
    hues = np.array([colorsys.rgb_to_hsv(*(gr[i] / 255.0))[0] for i in idx])
    q, med = quiet_fraction(lum)
    return {
        "p5": np.percentile(lum, 5), "p10": np.percentile(lum, 10),
        "p50": np.percentile(lum, 50), "p90": np.percentile(lum, 90),
        "p99": np.percentile(lum, 99),
        "ratio": np.percentile(lum, 90) / max(np.percentile(lum, 10), 1),
        "sat": sat.mean(),
        "ground_hue": hues.mean(),
        "ground_rb": gr[:, 0].mean() / max(gr[:, 2].mean(), 1),
        "hot170": 100.0 * (lum > 170).mean(),
        "hot200": 100.0 * (lum > 200).mean(),
        "quiet": 100.0 * q, "tile_std": med,
    }


ROWS = [("亮度 p5", "p5", "%6.0f"), ("亮度 p10", "p10", "%6.0f"),
        ("亮度 p50", "p50", "%6.0f"), ("亮度 p90", "p90", "%6.0f"),
        ("亮度 p99", "p99", "%6.0f"), ("p90/p10", "ratio", "%6.2f"),
        ("平均饱和度", "sat", "%6.3f"), ("地面色相", "ground_hue", "%6.3f"),
        ("地面 R/B", "ground_rb", "%6.2f"),
        ("亮于170 %", "hot170", "%6.1f"), ("亮于200 %", "hot200", "%6.1f"),
        ("安静块 %", "quiet", "%6.0f"), ("块内std中位", "tile_std", "%6.1f")]


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cols = [(p, audit(p)) for p in argv]
    names = [p.split("\\")[-1].split("/")[-1] for p, _ in cols]
    print("%-14s" % "" + "".join("%12s" % n[:12] for n in names))
    for label, key, fmt in ROWS:
        print("%-14s" % label + "".join(("%12s" % (fmt % d[key])) for _, d in cols))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
