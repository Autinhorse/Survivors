# -*- coding: utf-8 -*-
"""兼容壳：转发到 tools/gen_scene.py。

场景生成在 2026-08-21 拆成了三层，好让多个美术风格共存：

    tools/tscnlib.py            .tscn 发射器，风格无关
    tools/layout.py             布局（位置、河道曲线、散布规则），所有风格共享
    styles/<名字>/materials.py  材质槽位，每个风格一份

这个文件只是为了让文档和既有命令继续能用。新代码请直接用 gen_scene.py。
"""
import os
import runpy
import sys

sys.argv = [os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "gen_scene.py")] + sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
