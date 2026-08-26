#!/usr/bin/env python3
"""扫商店经济参数。改 data/shop.json → 跑 Batch → 解析 → 还原。

    python tools/sim/sweep_shop.py
"""
import json, pathlib, re, shutil, subprocess, sys, tempfile

GODOT = r"C:\Godot4.7\Godot_v4.7-stable_win64_console.exe"
PROJ = r"C:\My_Works\Survivors\Survivors"
SHOP = pathlib.Path("data/shop.json")

# (名字, 初始金币, 商店最小间隔, 最大间隔, 最近几屏, 最远几屏)
CASES = [
    ("文档原值 200/30-90s/1-2屏", 200, 30.0, 90.0, 1.0, 2.0),
    ("200/15-40s/1-2屏",          200, 15.0, 40.0, 1.0, 2.0),
    ("200/15-40s/0.4-1屏",        200, 15.0, 40.0, 0.4, 1.0),
    ("800/30-90s/1-2屏",          800, 30.0, 90.0, 1.0, 2.0),
    ("800/15-40s/0.4-1屏",        800, 15.0, 40.0, 0.4, 1.0),
    ("2000/15-40s/0.4-1屏",      2000, 15.0, 40.0, 0.4, 1.0),
]
RUNS, DURATION = 5, 1800


def run(runs=RUNS):
    out = subprocess.run(
        [GODOT, "--headless", "--path", PROJ, "--script",
         "res://demos/03_balance/Batch.gd", "--",
         f"runs={runs}", f"duration={DURATION}", "move=field", "pick=dps",
         "out=res://out/sweep.csv", "label=sweep"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
    m = re.search(r"平均存活\s+([\d.]+)s\s+击杀\s+(\d+)", out.stdout)
    return (float(m.group(1)), int(m.group(2))) if m else (0.0, 0)


def build_stats():
    rows = list(csv.DictReader(open("out/sweep.csv", encoding="utf-8")))
    if not rows:
        return 0.0, 0.0, ""
    visits = sum(int(r["shop_visits"]) for r in rows) / len(rows)
    col = sum(int(r["best_column"]) for r in rows) / len(rows)
    return visits, col, rows[-1]["final_build"][:50]


import csv
backup = SHOP.read_text(encoding="utf-8")
print("%-26s %-9s %-8s %-8s %-7s %s" % ("方案", "平均存活", "击杀", "进店次数", "最高列", "示例 build"))
try:
    for name, coins, lo, hi, s0, s1 in CASES:
        d = json.loads(backup)
        d["start_coins"] = coins
        d["spawn"]["min_gap_sec"] = lo
        d["spawn"]["max_gap_sec"] = hi
        d["spawn"]["min_screens"] = s0
        d["spawn"]["max_screens"] = s1
        SHOP.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
        surv, kills = run()
        visits, col, build = build_stats()
        print("%-26s %-9.1f %-8d %-8.1f %-7.1f %s" % (name, surv, kills, visits, col, build))
finally:
    SHOP.write_text(backup, encoding="utf-8")
    print("\n（data/shop.json 已还原）")
