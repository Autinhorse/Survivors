#!/usr/bin/env python3
"""少而硬 vs 多而脆：保持"波总血量"不变，只改单只血量与数量的比例，
看三条武器线各自怎么变。

    python tools/sim/sweep_density.py
"""
import csv, json, pathlib, re, statistics, subprocess
from collections import defaultdict

GODOT = r"C:\Godot4.7\Godot_v4.7-stable_win64_console.exe"
PROJ = r"C:\My_Works\Survivors\Survivors"
WAVES = pathlib.Path("data/waves.json")

RUNS, DURATION = 15, 1800
FACTORS = [1.0, 2.0, 4.0, 8.0]      # 单只血量 ×f，数量 ÷f，波总血量不变

backup = WAVES.read_text(encoding="utf-8")
base = json.loads(backup)["base"]
print("基准 hp %.0f × count %.0f = 波总血量不变" % (base["hp"], base["count"]))
print("%-22s %-11s %-11s %-11s %s" % ("配置", "散弹线中位", "rifle中位", "机枪线中位", "散弹/单体 倍数"))
try:
    for f in FACTORS:
        d = json.loads(backup)
        d["base"]["hp"] = base["hp"] * f
        d["base"]["count"] = base["count"] / f
        WAVES.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
        subprocess.run(
            [GODOT, "--headless", "--path", PROJ, "--script",
             "res://demos/03_balance/Batch.gd", "--",
             f"runs={RUNS}", f"duration={DURATION}", "move=field",
             "pick=spread,dps,rapid", "out=res://out/density.csv", "label=density"],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1800)
        g = defaultdict(list)
        for r in csv.DictReader(open("out/density.csv", encoding="utf-8")):
            g[r["pick_policy"]].append(float(r["run_duration"]))
        med = {k: statistics.median(v) for k, v in g.items() if v}
        single = max(med.get("dps", 0), med.get("rapid", 0))
        ratio = med.get("spread", 0) / single if single else 0
        print("%-22s %-11.0f %-11.0f %-11.0f %.2f" % (
            "血量×%.0f 数量÷%.0f (%.0f血/%.1f只)" % (f, f, d["base"]["hp"], d["base"]["count"]),
            med.get("spread", 0), med.get("dps", 0), med.get("rapid", 0), ratio))
finally:
    WAVES.write_text(backup, encoding="utf-8")
    print("\n（data/waves.json 已还原）")
