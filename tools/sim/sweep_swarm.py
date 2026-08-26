#!/usr/bin/env python3
"""杂兵轨道的量降下来，混合 build 能不能翻过纯机枪？

只动 data/waves.json 的 base.count，其余不变。
判据不是"谁活得久"，而是**排名会不会翻转**——
现在 8 门机枪刚好够应付杂兵，一门都匀不出来，所以混合必然更差。
如果杂兵压力降到 4 门机枪就够，剩下 4 门才有余裕去干别的。
"""
import json
import pathlib
import re
import subprocess

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
WAVES = pathlib.Path("data/waves.json")
COUNTS = [15.0, 10.0, 7.0, 5.0]
CAP = 600.0        # 局长上限：够看出排名，不必等到 1800 秒
RUNS = 4
ORDER = ["纯机枪线", "混合 3机枪+3散弹+2单发", "混合 4机枪+2散弹+2单发"]


def run_once():
    out = subprocess.run(
        [GODOT, "--headless", "--path", PROJ, "--script",
         "res://demos/03_balance/LadderTest.gd", "--", "runs=%d" % RUNS,
         "cap=%.0f" % CAP],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
    got = {}
    for line in out.stdout.split("\n"):
        line = line.rstrip()
        for name in ORDER:
            if line.startswith(name):
                m = re.search(r"([\d.]+)\s+(\d+)\s", line[len(name):])
                if m:
                    got[name] = (float(m.group(1)), int(m.group(2)))
    return got


_install_guard([WAVES])

backup = WAVES.read_text(encoding="utf-8")
try:
    header = "%-10s" % "杂兵数量" + "".join("%-16s" % n.replace("混合 ", "") for n in ORDER)
    print(header)
    for c in COUNTS:
        d = json.loads(backup)
        d["base"]["count"] = c
        WAVES.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
        g = run_once()
        row = "%-10.0f" % c
        best = max((v[0], n) for n, v in g.items()) if g else (0, "")
        for n in ORDER:
            v = g.get(n)
            cell = "%.0fs" % v[0] if v else "-"
            if v and n == best[1]:
                cell += "*"
            row += "%-16s" % cell
        print(row)
    print("\n* = 该行最优。排名翻转（星号从纯机枪移到混合）才算杂兵压力降到位。")
finally:
    WAVES.write_text(backup, encoding="utf-8")
    print("（data/waves.json 已还原）")
