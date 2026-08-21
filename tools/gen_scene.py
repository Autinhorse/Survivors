# -*- coding: utf-8 -*-
"""场景生成驱动：把某个**美术风格**的材质套进**共享的布局**，写出 .tscn。

    python tools/gen_scene.py                       # 默认风格，写 VisualBenchmark.tscn
    python tools/gen_scene.py --style <名字>
    python tools/gen_scene.py --performance         # 写 PerformanceBenchmark.tscn
    python tools/gen_scene.py --forward-plus        # 带上 Forward+ 专有的环境项
    python tools/gen_scene.py --pitch 62 --height 46 --fov 38

分工（见 styles/README.md）：

    tools/tscnlib.py            .tscn 发射器，风格无关
    tools/layout.py             布局（位置、河道曲线、散布规则），**所有风格共享**
    styles/<名字>/materials.py  材质槽位，每个风格一份
    styles/<名字>/assets.py     该风格的 Blender 资产建模

性能基准场景**固定用 REFERENCE_STYLE 生成**，不跟随当前风格 ——
这样 M4/M5 的数字在换风格之后仍然可比（§11 的目标硬件验证也只需跑一次）。
要测某个风格自身的渲染开销，用视觉场景另测，别动这个基准。
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

DEFAULT_STYLE = "gatling"
REFERENCE_STYLE = "gatling"      # 性能基准固定用它，保证数字可比


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def load_style(name):
    """返回 (材质模块, 布局模块)。

    布局默认用共享的 tools/layout.py；风格目录下如果有自己的 layout.py，
    就用它自己的。**这是给"美术语言差得太远"的风格留的出口** ——
    hellrider 的参考图是熔岩走廊，构图逻辑和 gatling 的村庄河谷不同，
    强行共用布局只会两头不讨好。
    """
    d = os.path.join(ROOT, "styles", name)
    mp = os.path.join(d, "materials.py")
    if not os.path.isfile(mp):
        raise SystemExit("找不到风格 '%s'（缺 %s）" % (name, mp))
    materials = _load("style_%s_materials" % name, mp)
    lp = os.path.join(d, "layout.py")
    if os.path.isfile(lp):
        layout = _load("style_%s_layout" % name, lp)
        print("[gen_scene] 风格 '%s' 使用自带布局" % name)
    else:
        import layout
    return materials, layout


def main(argv):
    style = DEFAULT_STYLE
    performance = "--performance" in argv
    for i, tok in enumerate(argv):
        if tok == "--style":
            style = argv[i + 1]
    if performance and style != REFERENCE_STYLE:
        print("[gen_scene] 性能基准固定用风格 '%s'（忽略 --style %s）"
              % (REFERENCE_STYLE, style))
        style = REFERENCE_STYLE

    import tscnlib

    st, layout = load_style(style)
    if "--forward-plus" in argv:
        layout.FORWARD_PLUS = True
    for i, tok in enumerate(argv):
        if tok == "--pitch":
            layout.CAM_PITCH = float(argv[i + 1])
        elif tok == "--height":
            layout.CAM_HEIGHT = float(argv[i + 1])
        elif tok == "--fov":
            layout.CAM_FOV = float(argv[i + 1])

    layout.build(st.materials(), st.MESH, performance=performance)

    name = ("PerformanceBenchmark.tscn" if performance
            else ("VisualBenchmark.tscn" if style == DEFAULT_STYLE
                  else "VisualBenchmark_%s.tscn" % style))
    out = os.path.join(tscnlib.SCENES, name)
    n_ext, n_sub, n_node = tscnlib.write_scene(out)
    print("wrote %s : %d ext + %d sub_resources, %d nodes"
          % (os.path.normpath(out), n_ext, n_sub, n_node))

    tscnlib.check_clearance(layout.clearance_items(),
                            allowed=[("Bridge", "Ramp")])
    zf, zn, w = layout.frame_size()
    print("camera: pitch %.1f deg, height %.1f m, fov %.1f, z %.2f"
          % (layout.CAM_PITCH, layout.CAM_HEIGHT, layout.CAM_FOV,
             layout.camera_z()))
    print("visible ground: %.1f m wide, depth z %.1f .. %.1f (%.1f m)"
          % (w, zf, zn, zn - zf))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
