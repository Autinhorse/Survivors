# -*- coding: utf-8 -*-
"""量"表面看着平不平"，以及反算纹理尺度该填多少。

做视觉对齐时，靠眼睛判断"这个面是不是太平"会反复走弯路 ——
这个项目里连续三次判断失误都来自没有量：
把纹理度调过头、调不足、以及以为渲染路径坏了（其实是参数填错）。

# 判据

**同一块平面内部、去掉光照低频之后的亮度起伏**（std / 均值）。

为什么要去低频：整块区域的 std 主要反映的是光照梯度和阴影，
不是表面本身有没有材质。用 9 像素的均值滤波取出高频再统计，
量到的才是"表面细节"。

# 用法

  # 单图量几块区域
  python tools/surface_detail.py shot.png \\
      --region 屋顶 195,110,265,165 --region 墙面 192,196,278,234

  # 和参考图逐项对比（区域按名字配对）
  python tools/surface_detail.py shot.png --ref docs/target.png \\
      --region 屋顶 195,110,265,165 --ref-region 屋顶 250,60,350,120

  # 反算纹理尺度：给定噪声参数和机位，列出每档 scale 在屏幕上多大
  python tools/surface_detail.py --scale-table --noise-freq 0.035 \\
      --texture-size 256 --px-per-metre 29

区域坐标按 --width（默认 1280）归一化后的图算，两张图分辨率不同也能直接比。
"""
import argparse
import sys

import numpy as np
from PIL import Image

LUMA = np.array([0.2126, 0.7152, 0.0722])


def box_blur(a, k):
    """k x k 均值滤波。用积分图实现，不依赖 scipy。"""
    r = k // 2
    p = np.pad(a, r + 1, mode="edge")
    c = p.cumsum(0).cumsum(1)
    c = np.pad(c, ((1, 0), (1, 0)))
    h, w = a.shape
    y0, x0 = np.arange(h)[:, None], np.arange(w)[None, :]
    y1, x1 = y0 + k, x0 + k
    s = c[y1, x1] - c[y0, x1] - c[y1, x0] + c[y0, x0]
    return s / float(k * k)


def load(path, width):
    im = Image.open(path).convert("RGB")
    h = int(round(im.size[1] * width / float(im.size[0])))
    return np.asarray(im.resize((width, h), Image.LANCZOS)).astype(float)


def detail(img, box, k=9):
    x0, y0, x1, y1 = box
    lum = img[y0:y1, x0:x1] @ LUMA
    if lum.size == 0:
        return float("nan"), float("nan")
    hi = lum - box_blur(lum, k)
    return 100.0 * hi.std() / max(lum.mean(), 1.0), lum.mean()


def parse_box(t):
    v = [int(x) for x in t.split(",")]
    if len(v) != 4:
        raise argparse.ArgumentTypeError("区域要写成 x0,y0,x1,y1")
    return v


def scale_table(freq, size, ppm):
    """噪声的特征波长 = (1/freq) / size 个纹理平铺周期。

    纹理平铺一次覆盖 1/scale 米，所以特征尺寸（米）= 1/(freq*size*scale)，
    屏幕上（像素）= ppm / (freq*size*scale)。

    这个换算是必须算的：填过 scale=2.2，特征只有 1.5 像素，
    整层纹理被抗锯齿平均掉，量出来的纹理度反而低于不加纹理。
    这个机位下**特征要落在 4-7 像素**才既看得见又不显脏。
    """
    print("噪声 frequency=%g, 纹理 %dpx, 机位 %g px/m" % (freq, size, ppm))
    print("特征尺寸(px) = %.4g / scale" % (ppm / (freq * size)))
    print()
    print("%8s %10s %10s   %s" % ("scale", "特征(m)", "特征(px)", ""))
    for sc in (0.25, 0.35, 0.5, 0.55, 0.75, 1.0, 1.5, 2.2, 3.0, 4.6):
        m = 1.0 / (freq * size * sc)
        px = m * ppm
        tag = "  <- 合适" if 4.0 <= px <= 7.0 else ("  太细，会被平均掉" if px < 2.5 else "")
        print("%8.2f %10.3f %10.1f   %s" % (sc, m, px, tag))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("image", nargs="?")
    ap.add_argument("--ref")
    ap.add_argument("--region", nargs=2, action="append", default=[],
                    metavar=("NAME", "X0,Y0,X1,Y1"))
    ap.add_argument("--ref-region", nargs=2, action="append", default=[],
                    metavar=("NAME", "X0,Y0,X1,Y1"))
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--kernel", type=int, default=9, help="低频滤波核，默认 9")
    ap.add_argument("--scale-table", action="store_true")
    ap.add_argument("--noise-freq", type=float, default=0.035)
    ap.add_argument("--texture-size", type=int, default=256)
    ap.add_argument("--px-per-metre", type=float, default=29.0)
    a = ap.parse_args()

    if a.scale_table:
        scale_table(a.noise_freq, a.texture_size, a.px_per_metre)
        return 0

    if not a.image or not a.region:
        ap.print_help()
        return 2

    img = load(a.image, a.width)
    ref = load(a.ref, a.width) if a.ref else None
    refbox = dict((n, parse_box(b)) for n, b in a.ref_region)

    if ref is not None:
        print("%-10s %10s %10s %8s" % ("区域", "参考", "本图", "比值"))
    else:
        print("%-10s %10s %10s" % ("区域", "细节度", "平均亮度"))
    for name, box in a.region:
        d, mean = detail(img, parse_box(box), a.kernel)
        if ref is not None:
            rb = refbox.get(name)
            if rb is None:
                print("%-10s %10s %9.1f%% %8s   (没给参考区域)" % (name, "-", d, "-"))
                continue
            rd, _ = detail(ref, rb, a.kernel)
            print("%-10s %9.1f%% %9.1f%% %8.2f" % (name, rd, d, d / max(rd, 1e-6)))
        else:
            print("%-10s %9.1f%% %10.1f" % (name, d, mean))
    return 0


if __name__ == "__main__":
    sys.exit(main())
