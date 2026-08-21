# -*- coding: utf-8 -*-
"""把某个风格的参考图和当前渲染排成一张对照图。

    python tools/style_compare.py hellrider
    python tools/style_compare.py gatling

输出 styles/<风格>/compare.png：上排是参考图，下面是当前渲染。
每次迭代跑一遍，肉眼比对就有固定的版式，不用每次临时拼。

标签用 ASCII —— PIL 的默认位图字体没有中文字形，写中文会变成方块。
"""
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIDTH = 1600

# 每个风格挑几张最有代表性的参考图，以及当前渲染的位置
STYLES = {
    "hellrider": {
        "refs": [("zone_brown_wide.jpg", "ref: brown zone"),
                 ("zone_brown_rocks.jpg", "ref: rocks"),
                 ("zone_green_trees.jpg", "ref: green zone")],
        "shot": "docs/reference/m2_visual_hellrider.png",
    },
    "gatling": {
        "refs": [("../../../docs/target.png", "ref: target.png")],
        "shot": "docs/reference/m2_visual.png",
    },
}


def main(argv):
    if not argv or argv[0] not in STYLES:
        print(__doc__)
        print("可用风格: %s" % ", ".join(sorted(STYLES)))
        return 2
    style = argv[0]
    cfg = STYLES[style]
    rdir = os.path.join(ROOT, "styles", style, "reference")

    shot = Image.open(os.path.join(ROOT, cfg["shot"])).convert("RGB")
    big = shot.resize((WIDTH, int(WIDTH * shot.size[1] / shot.size[0])),
                      Image.LANCZOS)

    n = len(cfg["refs"])
    cw = WIDTH // n
    thumbs = []
    for f, _lab in cfg["refs"]:
        im = Image.open(os.path.join(rdir, f)).convert("RGB")
        thumbs.append(im.resize((cw, int(cw * im.size[1] / im.size[0])),
                                Image.LANCZOS))
    th = max(t.size[1] for t in thumbs)

    sheet = Image.new("RGB", (WIDTH, th + 22 + big.size[1] + 22), (22, 22, 24))
    d = ImageDraw.Draw(sheet)
    x = 0
    for t, (_f, lab) in zip(thumbs, cfg["refs"]):
        sheet.paste(t, (x, 18))
        d.text((x + 4, 4), lab, fill=(235, 235, 240))
        x += cw
    d.text((4, th + 24), "ours: scenes/VisualBenchmark_%s.tscn" % style,
           fill=(235, 235, 240))
    sheet.paste(big, (0, th + 40))

    out = os.path.join(ROOT, "styles", style, "compare.png")
    sheet.save(out)
    print("wrote %s  %dx%d" % (os.path.relpath(out, ROOT), *sheet.size))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
