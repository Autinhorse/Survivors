#!/usr/bin/env python3
"""击退到底贡献了多少？把散弹线的击退关掉再跑一遍。"""
import csv, json, pathlib, statistics, subprocess
from collections import defaultdict

def _install_guard(paths):
    """被 kill 时 finally 不会执行，数据文件会留在污染状态。
    先把原文备份到 .sweepbak，脚本启动时若发现残留就先还原。"""
    import atexit, os, signal
    for p in paths:
        bak = p.with_suffix(p.suffix + ".sweepbak")
        if bak.exists():
            p.write_text(bak.read_text(encoding="utf-8"), encoding="utf-8")
            print("检测到上次扫描残留，已从 %s 还原" % bak.name)
        else:
            bak.write_text(p.read_text(encoding="utf-8"), encoding="utf-8")

    def _restore(*_a):
        for p in paths:
            bak = p.with_suffix(p.suffix + ".sweepbak")
            if bak.exists():
                p.write_text(bak.read_text(encoding="utf-8"), encoding="utf-8")
                bak.unlink()
        os._exit(1)

    atexit.register(lambda: [
        (p.write_text(b.read_text(encoding="utf-8"), encoding="utf-8"), b.unlink())
        for p, b in ((q, q.with_suffix(q.suffix + ".sweepbak")) for q in paths) if b.exists()])
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, _restore)
        except (ValueError, OSError):
            pass



GODOT = r"C:\Godot4.7\Godot_v4.7-stable_win64_console.exe"
PROJ = r"C:\My_Works\Survivors\Survivors"
W = pathlib.Path("data/weapons.json")
_install_guard([W])

backup = W.read_text(encoding="utf-8")

def run(tag):
    subprocess.run([GODOT, "--headless", "--path", PROJ, "--script",
        "res://demos/03_balance/Batch.gd", "--", "runs=15", "duration=1800",
        "move=field", "pick=spread", "out=res://out/kb.csv", "label=kb"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1200)
    v = [float(r["run_duration"]) for r in csv.DictReader(open("out/kb.csv", encoding="utf-8"))]
    kills = [int(r["kills_total"]) for r in csv.DictReader(open("out/kb.csv", encoding="utf-8"))]
    print("%-16s 中位 %6.0fs   平均 %6.0fs   击杀 %5.0f" % (
        tag, statistics.median(v), statistics.mean(v), statistics.mean(kills)))

try:
    run("散弹线（有击退）")
    d = json.loads(backup)
    for wid in ["spread_gun", "shotgun", "fragment_cannon", "wall_of_lead"]:
        if "mechanic" in d[wid]:
            d[wid]["mechanic"]["knockback"] = 0.0
    W.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
    run("散弹线（无击退）")
finally:
    W.write_text(backup, encoding="utf-8")
    print("（data/weapons.json 已还原）")
