#!/usr/bin/env python3
"""扫商店经济参数。改 data/shop.json → 跑 Batch → 解析 → 还原。

    python tools/sim/sweep_shop.py
"""
import json, pathlib, re, shutil, subprocess, sys, tempfile

GODOT = r"C:\Godot4.7\Godot_v4.7-stable_win64_console.exe"
PROJ = r"C:\My_Works\Survivors\Survivors"
SHOP = pathlib.Path("data/shop.json")
AGENTS = pathlib.Path("data/agents.json")

# (名字, 初始金币, 商店最小间隔, 最大间隔, 最近几屏, 最远几屏)
# 机甲 2 格/秒，视野半对角 27.5 格 → 1 屏要走 14 秒，2 屏 28 秒，还要边躲边走。
# 所以商店距离是硬瓶颈，这一轮专门扫它。
# 上一轮"距离不影响结果"是在 AI 根本不去商店的情况下测的，无效。
# shop_pull 的量纲修好之后重测，同时扫引力强度。
CASES = [
    ("1-2屏 / pull 1.0",   200, 30.0, 90.0, 1.0, 2.0, 1.0),
    ("0.3-0.8屏 / pull 1.0", 200, 30.0, 90.0, 0.3, 0.8, 1.0),
    ("0.3-0.8屏 / pull 0.5", 200, 30.0, 90.0, 0.3, 0.8, 0.5),
    ("0.2-0.5屏 / pull 0.5", 200, 20.0, 50.0, 0.2, 0.5, 0.5),
    ("0.2-0.5屏 / pull 0.3", 200, 20.0, 50.0, 0.2, 0.5, 0.3),
]
RUNS, DURATION = 20, 1800


def run(runs=RUNS):
    out = subprocess.run(
        [GODOT, "--headless", "--path", PROJ, "--script",
         "res://demos/03_balance/Batch.gd", "--",
         f"runs={runs}", f"duration={DURATION}", "move=field", "pick=spread",
         "out=res://out/sweep.csv", "label=sweep"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
    m = re.search(r"平均存活\s+([\d.]+)s\s+击杀\s+(\d+)", out.stdout)
    return (float(m.group(1)), int(m.group(2))) if m else (0.0, 0)


def build_stats():
    import statistics
    rows = list(csv.DictReader(open("out/sweep.csv", encoding="utf-8")))
    if not rows:
        return 0.0, 0.0, ""
    visits = sum(int(r["shop_visits"]) for r in rows) / len(rows)
    col = sum(int(r["best_column"]) for r in rows) / len(rows)
    dur = sorted(float(r["run_duration"]) for r in rows)
    turrets = sum(len(r["final_build"].split()) for r in rows) / len(rows)
    return visits, col, "中位 %.0fs  最短 %.0f  最长 %.0f  终局 %.1f 门" % (
        statistics.median(dur), dur[0], dur[-1], turrets)


import csv
backup = SHOP.read_text(encoding="utf-8")
abackup = AGENTS.read_text(encoding="utf-8")
print("%-26s %-9s %-8s %-8s %-7s %s" % ("方案", "平均存活", "击杀", "进店次数", "最高列", "示例 build"))
try:
    for name, coins, lo, hi, s0, s1, pull in CASES:
        a = json.loads(abackup)
        a["field"]["shop_pull"] = pull
        AGENTS.write_text(json.dumps(a, ensure_ascii=False, indent=2), encoding="utf-8")
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
    AGENTS.write_text(abackup, encoding="utf-8")
    print("\n（data/shop.json 与 data/agents.json 已还原）")
