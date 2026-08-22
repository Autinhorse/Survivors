#!/bin/bash
# 大地图截图：重新导入 + 生成场景 + 渲染。
#   bash tools/hr_map_shot.sh out.png [pos=x,z] [ortho=N]
# **--import 那一步不能省**：改了 GLB 之后直接跑场景不会触发重新导入，
# 渲出来还是旧模型。踩过两次。
OUT="$1"; shift
GODOT="/c/Godot4.7/Godot_v4.7-stable_win64_console.exe"
cd "C:/My_Works/Survivors/Survivors" || exit 1
timeout 250 "$GODOT" --headless --path "C:\My_Works\Survivors\Survivors" --import > /dev/null 2>&1
python tools/gen_scene.py --style hellrider > /dev/null || exit 1
timeout 250 "$GODOT" --path "C:\My_Works\Survivors\Survivors" \
  --resolution 1920x1080 --position 40,40 res://tools/Screenshot.tscn -- \
  "$OUT" res://scenes/VisualBenchmark_hellrider.tscn "$@" 2>&1 \
  | grep -i "screenshot\|SCRIPT ERROR"
