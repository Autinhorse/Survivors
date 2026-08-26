#!/bin/bash
# 只做语法/类型检查，不跑。改完 .gd 先跑这个 —— 比等 headless 跑起来快得多，
# 而且 GDScript 的 `:=` 类型推断错误只有编译期才报，跑之前一定要过一遍。
#   bash tools/sim/check.sh
GODOT="/c/Godot4.7/Godot_v4.7-stable_win64_console.exe"
PROJ="C:\My_Works\Survivors\Survivors"
fail=0
for f in $(cd "$(dirname "$0")/../.." && ls sim/**/*.gd sim/*.gd demos/**/*.gd demos/*.gd 2>/dev/null); do
  out=$(timeout 60 "$GODOT" --headless --path "$PROJ" --check-only --script "res://$f" 2>&1 \
        | grep -E "Parse Error|Compile Error" | head -3)
  if [ -n "$out" ]; then
    echo "✗ $f"
    echo "$out" | sed 's/^/    /'
    fail=1
  fi
done
[ $fail -eq 0 ] && echo "✓ 全部通过" || echo "有编译错误"
exit $fail
