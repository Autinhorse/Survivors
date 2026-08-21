# -*- coding: utf-8 -*-
"""把 docs/reference/m2_visual.png 的历次版本从 git 里取出来，排成一份迭代记录。

每次视觉迭代都会覆盖 m2_visual.png，所以"上一版长什么样"其实一直躺在 git 里，
只是看不见。这个脚本把它们摊开：

    styles/<风格>/history/NN_<hash>.png        每次提交时的那一版
    styles/<风格>/history/contact_sheet.png    拼图总览，一眼看完全过程
    styles/<风格>/history/README.md            序号 / 提交 / 日期 / 那一版做了什么

工作区里如果有还没提交的改动，会额外排在最后一格，标成"未提交"。
提交之后重跑一次，它就会归位成正式的一版。

用法：  python tools/snapshot_visual.py
"""
import io
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 每个美术风格一份迭代记录。gatling 沿用原来的路径，
# 这样 git --follow 能一路取到最早那一版。
STYLE = "gatling"
for _i, _a in enumerate(sys.argv[1:]):
    if _a == "--style":
        STYLE = sys.argv[_i + 2]
TRACKED = ("docs/reference/m2_visual.png" if STYLE == "gatling"
           else "docs/reference/m2_visual_%s.png" % STYLE)
OUT_DIR = os.path.join(REPO, "styles", STYLE, "history")

CELL_W, CELL_H = 480, 270
COLS, PAD, HDR = 3, 10, 26


def git(*args):
    r = subprocess.run(["git"] + list(args), cwd=REPO, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode("utf-8", "replace"))
    return r.stdout


def history():
    txt = git("log", "--reverse", "--follow", "--format=%H|%ad|%s",
              "--date=short", "--", TRACKED).decode("utf-8")
    out = []
    for line in txt.strip().split("\n"):
        if line.strip():
            h, d, subj = line.split("|", 2)
            out.append((h, d, subj))
    return out


def main():
    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)
    for f in os.listdir(OUT_DIR):
        if f.endswith(".png"):
            os.remove(os.path.join(OUT_DIR, f))

    rows = []
    for i, (h, d, subj) in enumerate(history(), 1):
        name = "%02d_%s.png" % (i, h[:7])
        with open(os.path.join(OUT_DIR, name), "wb") as fh:
            fh.write(git("show", "%s:%s" % (h, TRACKED)))
        rows.append((i, name, name, "`" + h[:7] + "`", d, subj))

    # 工作区里未提交的那一版
    cur = os.path.join(REPO, TRACKED)
    dirty = git("status", "--porcelain", "--", TRACKED).decode("utf-8").strip()
    if dirty and os.path.exists(cur):
        i = len(rows) + 1
        name = "%02d_working.png" % i
        with open(os.path.join(OUT_DIR, name), "wb") as fh:
            fh.write(open(cur, "rb").read())
        rows.append((i, name, name, "—", "—",
                     "**未提交**（提交后重跑本脚本归位）"))

    io.open(os.path.join(OUT_DIR, "README.md"), "w", encoding="utf-8").write(
        u"# M2 视觉迭代记录\n\n"
        u"每一格都是当时那次提交里的 `%s`，由 `tools/snapshot_visual.py`\n"
        u"从 git 历史中取出。最新一版始终在 `%s`。\n\n"
        u"拼图总览：![contact sheet](contact_sheet.png)\n\n"
        u"| # | 图 | 提交 | 日期 | 这一版做了什么 |\n|---|---|---|---|---|\n"
        % (TRACKED, TRACKED)
        + u"".join(u"| %d | [%s](%s) | %s | %s | %s |\n" % r for r in rows))

    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("[snapshot] %d 版已导出；未装 Pillow，跳过拼图" % len(rows))
        return
    n = len(rows)
    nrows = (n + COLS - 1) // COLS
    sheet = Image.new("RGB",
                      (COLS * (CELL_W + PAD) + PAD,
                       nrows * (CELL_H + HDR + PAD) + PAD), (24, 24, 26))
    d = ImageDraw.Draw(sheet)
    for i, (_, name, _, _, _, _) in enumerate(rows):
        im = Image.open(os.path.join(OUT_DIR, name)).convert("RGB")
        im = im.resize((CELL_W, CELL_H), Image.LANCZOS)
        x = PAD + (i % COLS) * (CELL_W + PAD)
        y = PAD + (i // COLS) * (CELL_H + HDR + PAD)
        sheet.paste(im, (x, y + HDR))
        d.text((x + 2, y + 6), name[:-4], fill=(230, 230, 235))
    sheet.save(os.path.join(OUT_DIR, "contact_sheet.png"))
    print("[snapshot] %d 版 -> %s（含拼图 %dx%d）"
          % (n, os.path.relpath(OUT_DIR, REPO), sheet.size[0], sheet.size[1]))


if __name__ == "__main__":
    sys.exit(main())
