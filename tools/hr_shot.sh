#!/bin/bash
# hellrider 的渲染 + 量地面明暗，一条命令。
#   bash tools/hr_shot.sh [out.png]
# 判据见 styles/hellrider/README.md「地面明暗」一节：
# 取一块不含物体的纯地面，和参考图 zone_green_open 的同尺寸干净块比
#   总 std 5.54 / 半幅块均值 std 3.04 / 最亮:最暗 1.12
OUT="${1:-C:/Users/WIN11/AppData/Local/Temp/claude/C--My-Works-Survivors-Survivors/c4b1f951-fc36-4f76-9c8a-3cc4fea40e25/scratchpad/hr.png}"
cd "C:/My_Works/Survivors/Survivors" || exit 1
GODOT="/c/Godot4.7/Godot_v4.7-stable_win64_console.exe"
# **改了 GLB 一定要先重新导入。** 直接跑场景不会触发导入 ——
# Godot 用的是 .godot/imported/ 里的缓存，源文件更新了也不管。
# 踩过一次：Blender 那边把石头改完了，渲出来还是旧模型，
# 差点得出"这个改动没效果"的结论。
timeout 250 "$GODOT" --headless --path "C:\My_Works\Survivors\Survivors"   --import > /dev/null 2>&1
python tools/gen_scene.py --style hellrider > /dev/null || exit 1
timeout 250 "$GODOT" --path "C:\My_Works\Survivors\Survivors" \
  --resolution 1920x1080 --position 40,40 res://tools/Screenshot.tscn -- "$OUT" \
  res://scenes/VisualBenchmark_hellrider.tscn > /dev/null 2>&1
python tools/hr_ground_stats.py "$OUT"
