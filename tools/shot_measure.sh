#!/bin/bash
# 渲染 + 量亮度分布，一条命令，避免靠眼睛来回猜
SP="C:/Users/WIN11/AppData/Local/Temp/claude/C--My-Works-Survivors-Survivors/5ce0213a-e546-4564-86df-0ed5a4ab91ca/scratchpad"
cd "C:/My_Works/Survivors/Survivors" || exit 1
python tools/gen_greybox.py > /dev/null || exit 1
timeout 250 "/c/Godot4.7/Godot_v4.7-stable_win64_console.exe" --path "C:\My_Works\Survivors\Survivors" \
  --resolution 1920x1080 --position 40,40 res://tools/Screenshot.tscn -- "$SP/tune.png" \
  res://scenes/VisualBenchmark.tscn > /dev/null 2>&1
python -c "
from PIL import Image
def stats(path, label, box):
    im = Image.open(path).convert('RGB').crop(box)
    px = list(im.getdata()); n = len(px)
    lum = sorted(0.2126*r+0.7152*g+0.0722*b for r,g,b in px)
    mr = sum(p[0] for p in px)/n; mg = sum(p[1] for p in px)/n; mb = sum(p[2] for p in px)/n
    print('%-8s mean=%5.1f p10=%5.1f p50=%5.1f p90=%5.1f  ratio=%4.1f  RGB=(%3.0f,%3.0f,%3.0f)'
          % (label, sum(lum)/n, lum[int(n*0.1)], lum[n//2], lum[int(n*0.9)],
             lum[int(n*0.9)]/max(lum[int(n*0.1)],1), mr, mg, mb))
stats('docs/target.png','target', (100,250,1180,700))
stats(r'$SP/tune.png','mine', (150,430,1740,1030))
" 2>/dev/null
