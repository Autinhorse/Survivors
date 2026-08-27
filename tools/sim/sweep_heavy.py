#!/usr/bin/env python3
"""重甲炮台的攻击力扫描：多疼才能让纯机枪线翻不过混合 build？

判据不是"谁活得久"，而是**排名会不会翻转**。
现在纯机枪 605 / 最佳混合 583，差 4%——方向对了力度不够。
纯机枪 88% 的伤害来自它一发都打不到的重甲炮台，却还是活得最久，
因为它把杂兵清得太干净，重甲累积到 1000 血要 600 秒。

第一版用 RUNS=3 跑出的表自相矛盾：攻击从 80 涨到 120，两个 build 都
"活得更久"。这里经济是关掉的，敌人更疼不可能延长存活——那一行纯是
噪声。噪声能造出 ±11%，所以 4 档里那次"翻转"同样不可信。改用 8 局，
并且 LadderTest 现在每行都报最短-最长，能一眼看出信号有没有淹掉。

只跑两个 build：纯机枪线（打不到重甲）和混合 4机枪+2散弹+2单发（打得到）。
其余四个已经稳定分出高下，再跑是浪费墙钟。
"""
import atexit
import json
import os
import pathlib
import re
import signal
import subprocess

GODOT = r"C:\Godot4.7\Godot_v4.7-stable_win64_console.exe"
PROJ = r"C:\My_Works\Survivors\Survivors"
WAVES = pathlib.Path("data/waves.json")
ATTACKS = [80.0, 160.0, 240.0]
BUILDS = ["纯机枪线", "混合 4机枪+2散弹+2单发"]
RUNS = 8   # 3 局时噪声能造出 +11% 的假信号（见文件头），不够用
CAP = 700.0


def _install_guard(paths):
    """被 kill 时 finally 不会执行，数据文件会留在污染状态。
    先把原文备份到 .sweepbak，脚本启动时若发现残留就先还原。"""
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


def run(only):
    out = subprocess.run(
        [GODOT, "--headless", "--path", PROJ, "--script",
         "res://demos/03_balance/LadderTest.gd", "--",
         "runs=%d" % RUNS, "cap=%.0f" % CAP, "only=%s" % only],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
    for line in out.stdout.split("\n"):
        if line.startswith(only):
            # 只取名字后面第一个数（平均存活）。别去匹配后面的列——
            # LadderTest 加了「波动 377-670 (±11%)」那一列之后，原来那个
            # "浮点 + 空白 + 整数" 的正则就全部匹配失败，整张表变成 '-'。
            m = re.search(r"^\s*([\d.]+)", line[len(only):])
            if m:
                return float(m.group(1))
    return None


_install_guard([WAVES])
backup = WAVES.read_text(encoding="utf-8")
try:
    print("%-10s %-14s %-22s %s" % ("重甲攻击", BUILDS[0], BUILDS[1], "谁赢"))
    for a in ATTACKS:
        d = json.loads(backup)
        for w in d["waves"]:
            if w.get("keep_distance"):
                w["base"]["attack"] = a
        WAVES.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
        got = [run(b) for b in BUILDS]
        win = "-"
        if got[0] is not None and got[1] is not None:
            win = "纯机枪" if got[0] > got[1] else "**混合**"
        print("%-10.0f %-14s %-22s %s" % (
            a,
            "%.0fs" % got[0] if got[0] is not None else "-",
            "%.0fs" % got[1] if got[1] is not None else "-",
            win))
    print("\n翻转（谁赢那列变成「混合」）才算力度到位。")
finally:
    WAVES.write_text(backup, encoding="utf-8")
    print("（data/waves.json 已还原）")
