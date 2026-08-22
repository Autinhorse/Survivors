#!/bin/bash
# hellrider 的渲染 + 量地面明暗，一条命令。
#   bash tools/hr_shot.sh [out.png]
# 判据见 styles/hellrider/README.md「地面明暗」一节：
# 取一块不含物体的纯地面，和参考图 zone_green_open 的同尺寸干净块比
#   总 std 5.54 / 半幅块均值 std 3.04 / 最亮:最暗 1.12
OUT="${1:-C:/Users/WIN11/AppData/Local/Temp/claude/C--My-Works-Survivors-Survivors/c4b1f951-fc36-4f76-9c8a-3cc4fea40e25/scratchpad/hr.png}"
cd "C:/My_Works/Survivors/Survivors" || exit 1
python tools/gen_scene.py --style hellrider > /dev/null || exit 1
timeout 250 "/c/Godot4.7/Godot_v4.7-stable_win64_console.exe" --path "C:\My_Works\Survivors\Survivors" \
  --resolution 1920x1080 --position 40,40 res://tools/Screenshot.tscn -- "$OUT" \
  res://scenes/VisualBenchmark_hellrider.tscn > /dev/null 2>&1
python tools/hr_ground_stats.py "$OUT"
