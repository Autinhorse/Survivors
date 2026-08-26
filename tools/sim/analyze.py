#!/usr/bin/env python3
"""out/*.csv 的统计。批量模拟只负责产出原始行，结论在这里算。

    python tools/sim/analyze.py out/runs.csv
    python tools/sim/analyze.py out/runs.csv --by move_policy pick_policy
    python tools/sim/analyze.py out/runs.csv --weapons     # 按武器看击杀/伤害份额
"""
import argparse
import csv
import statistics
from collections import defaultdict


def load(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def kv(cell):
    out = {}
    for part in cell.split(" "):
        if ":" in part:
            k, v = part.rsplit(":", 1)
            try:
                out[k] = float(v)
            except ValueError:
                pass
    return out


def summarize(rows, keys):
    groups = defaultdict(list)
    for r in rows:
        groups[tuple(r.get(k, "") for k in keys)].append(r)
    print(f"{'/'.join(keys) or 'all':28} {'局数':>5} {'存活率':>7} {'平均时长':>9} "
          f"{'中位':>7} {'击杀':>8} {'等级':>6} {'静止%':>7} {'首炮塔':>7}")
    for g in sorted(groups):
        rs = groups[g]
        dur = [float(r["run_duration"]) for r in rs]
        surv = sum(1 for r in rs if r["result"] == "survived") / len(rs)
        stat = sum(float(r["time_stationary"]) for r in rs) / max(1e-6, sum(dur))
        first = [float(r["first_turret_time"]) for r in rs if float(r["first_turret_time"]) >= 0]
        print(f"{'/'.join(g):28} {len(rs):5d} {surv*100:6.1f}% {statistics.mean(dur):9.1f} "
              f"{statistics.median(dur):7.1f} {statistics.mean(float(r['kills_total']) for r in rs):8.0f} "
              f"{statistics.mean(float(r['player_level']) for r in rs):6.1f} {stat*100:6.1f}% "
              f"{(statistics.mean(first) if first else -1):7.1f}")


def weapons(rows):
    kills, dmg = defaultdict(float), defaultdict(float)
    for r in rows:
        for k, v in kv(r["kills_by_weapon"]).items():
            kills[k] += v
        for k, v in kv(r["damage_by_weapon"]).items():
            dmg[k] += v
    tk, td = sum(kills.values()) or 1, sum(dmg.values()) or 1
    print(f"\n{'武器':24} {'击杀':>9} {'占比':>7} {'伤害':>12} {'占比':>7}")
    for k in sorted(dmg, key=lambda x: -dmg[x]):
        print(f"{k:24} {kills[k]:9.0f} {kills[k]/tk*100:6.1f}% {dmg[k]:12.0f} {dmg[k]/td*100:6.1f}%")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--by", nargs="*", default=["move_policy", "pick_policy"])
    ap.add_argument("--weapons", action="store_true")
    a = ap.parse_args()
    rows = load(a.csv)
    if not rows:
        print("空表")
        return
    summarize(rows, a.by)
    if a.weapons:
        weapons(rows)


if __name__ == "__main__":
    main()
