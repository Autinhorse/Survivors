#!/usr/bin/env python3
"""把 data/weapons.json 算出来的 DPS 和设计文档 §7.8 自己写的 DPS 列对一遍。
录数值最容易出的错就是抄漏一位，这个脚本专门抓它。"""
import json, pathlib, re

DOC = pathlib.Path("docs/机甲幸存者_核心玩法与武器升级系统_v0.3.md")
W = json.loads(pathlib.Path("data/weapons.json").read_text(encoding="utf-8"))

# 从文档里抓每个条目的 DPS 行（只取第一个括号/数字对）
doc_dps = {}
cur = None
for line in DOC.read_text(encoding="utf-8").split("\n"):
    m = re.match(r"^(\d+)\. 名字：(.+)$", line.strip())
    if m:
        cur = (int(m.group(1)), m.group(2).strip())
    elif cur and line.strip().startswith("DPS"):
        nums = re.findall(r"[\d.]+", line.replace(",", ""))
        if nums:
            doc_dps[cur[0]] = (cur[1], float(nums[0]), float(nums[1]) if len(nums) > 1 else 0.0)
        cur = None

print("%-4s %-16s %-10s %-10s %-10s %-10s %s" % ("号", "名称", "实测DPS", "文档DPS", "每级实测", "每级文档", ""))
bad = 0
for wid, w in W.items():
    if wid.startswith("_"):
        continue
    no = w["no"]
    if no not in doc_dps:
        continue
    # 文档 DPS 列写的是"单发 DPS"，连射倍数写在后面的 * N 里（Fragment Cannon 那种），
    # 所以这里也用单发 DPS 对比，连射另算。
    burst = w.get("mechanic", {}).get("burst", 1)
    dps = w["damage"] / w["interval"]
    per = w.get("upgrade", {}).get("damage", 0) / w["interval"]
    name, ddps, dper = doc_dps[no]
    flag = ""
    if abs(dps - ddps) > max(1.0, ddps * 0.02):
        flag = "  ← 对不上"
        bad += 1
    note = ("  连射x%d → 实际 %.0f" % (burst, dps * burst)) if burst > 1 else ""
    print("%-4d %-16s %-10.0f %-10.0f %-10.0f %-10.0f%s%s" % (no, w["name"], dps, ddps, per, dper, flag, note))
print("\n%d 条对不上" % bad)
