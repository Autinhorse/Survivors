#!/usr/bin/env python3
"""波次曲线 —— 形状 x 成长 模型（提议中的写法，见 docs/balance/）。

    第 c 周期第 k 位的数值 = 基准 x G^(c-1) x SHAPE[k]

SHAPE 就是现有 §4.5 系数在一个周期内的累乘结果，原样保留 —— 第 1 个周期和现在
逐波完全一致。变的只是第 9 波起：不再继续累乘，而是回到本周期基准 x 成长系数。
好处：四个 G 都 >= 1 天然成立，且"局长"（G_hp x G_cnt）和"坦克有多硬"（SHAPE_HP[4]）
变成两个互不干扰的旋钮。

    python tools/sim/wave_shape.py
    python tools/sim/wave_shape.py --g-atk 1.08 --g-coin 1.08
    python tools/sim/wave_shape.py --sweep atk
"""
import argparse
import csv  # noqa: F401

import json, pathlib
_W = json.loads(pathlib.Path("data/waves.json").read_text(encoding="utf-8"))
_b, _g = _W["base"], _W["growth"]
BASE = dict(hp=_b["hp"], cnt=_b["count"], atk=_b["attack"], coin=_b["coin"])
DEFAULT_G = dict(hp=_g["hp"], cnt=_g["count"], atk=_g["attack"], coin=_g["coin"])

# 周期内形状（相对本周期第 1 位）。索引 0..7 对应第 1..8 位。
SHAPE = dict(
    hp=[w["shape"]["hp"] for w in _W["waves"]],
    cnt=[w["shape"]["count"] for w in _W["waves"]],
    atk=[w["shape"]["attack"] for w in _W["waves"]],
    coin=[w["shape"]["coin"] for w in _W["waves"]],
)
PATTERN = ['random 2.0s', 'random 1.0s', 'Group 瞬发', 'Circle 瞬发',
           'random 0.4s', 'Circle 瞬发 远程', 'Group 瞬发', 'Circle 瞬发 直线']
SPEED = [1.0, 1.0, 1.5, 0.5, 2.5, 1.5, 2.5, 2.0]

WAVE_GAP, CYCLE = 10.0, 8
CEILING = 38400.0        # 4 门满级穿刺枪
TREE_COST = 1040000.0    # 整棵树 + 四面满级装甲
MECH_HP, CONTACT, ARMOR = 1000.0, 12, 0.45


# 每波可带自己的 base/growth（独立威胁轨道），和 SpawnDirector 的规则保持一致
_WB = [w.get("base", {}) for w in _W["waves"]]
_WG = [w.get("growth", {}) for w in _W["waves"]]
_KEY = {"hp": "hp", "cnt": "count", "atk": "attack", "coin": "coin"}


def simulate(G, n_waves, shape):
    rows, cum = [], 0.0
    for n in range(1, n_waves + 1):
        k = (n - 1) % CYCLE
        c = (n - 1) // CYCLE + 1
        v = {}
        for f in BASE:
            key = _KEY[f]
            if key in _WB[k]:
                v[f] = _WB[k][key] * _WG[k].get(key, 1.0) ** (c - 1)
            else:
                v[f] = BASE[f] * G[f] ** (c - 1) * shape[f][k]
        cum += v['cnt'] * v['coin']
        rows.append(dict(n=n, k=k + 1, cycle=c, t=WAVE_GAP * (n - 1), cum_coin=cum,
                         total_hp=v['cnt'] * v['hp'], **v))
    return rows


def f(x):
    if x >= 1e9:  return '%.2e' % x
    if x >= 1e6:  return '%.2fM' % (x / 1e6)
    if x >= 1000: return '{:,.0f}'.format(x)
    if x >= 10:   return '%.0f' % x
    return '%.2f' % x


def report(G, shape, cycles):
    rows = simulate(G, cycles * CYCLE, shape)
    hit = None
    for c in range(1, cycles + 1):
        seg = [r for r in rows if r['cycle'] == c]
        if sum(r['total_hp'] for r in seg) / (CYCLE * WAVE_GAP) > CEILING:
            hit = (c, seg[0]['t'] / 60)
            break
    rich = next((r for r in rows if r['cum_coin'] > TREE_COST), None)
    end = hit[0] if hit else cycles
    seg = [r for r in rows if r['cycle'] == end]
    tank = max(r['hp'] for r in seg)
    atk = seg[-1]['atk']
    dps = CONTACT * atk / 2 * (1 - ARMOR)
    return dict(rows=rows, hit=hit, rich=rich, tank=tank, atk=atk,
                hold=MECH_HP / dps, base_hp=seg[0]['hp'], cnt=seg[0]['cnt'],
                cum=next(r for r in rows if r['cycle'] == end and r['k'] == 8)['cum_coin'])


def main():
    ap = argparse.ArgumentParser()
    for k in ['hp', 'cnt', 'atk', 'coin']:
        ap.add_argument('--g-' + k, type=float, default=DEFAULT_G[k])
    ap.add_argument('--tank-hp', type=float, default=SHAPE['hp'][3], help='SHAPE_HP[4]')
    ap.add_argument('--tank-cnt', type=float, default=SHAPE['cnt'][3], help='SHAPE_CNT[4]')
    ap.add_argument('--cycles', type=int, default=24)
    ap.add_argument('--sweep', choices=['atk', 'coin', 'both'])
    a = ap.parse_args()

    shape = {k: list(v) for k, v in SHAPE.items()}
    shape['hp'][3] = a.tank_hp
    shape['cnt'][3] = a.tank_cnt
    G = dict(hp=a.g_hp, cnt=a.g_cnt, atk=a.g_atk, coin=a.g_coin)

    if a.sweep in ('atk', 'both'):
        print('攻击力成长 G_atk（其余不变）：')
        print('  G_atk   撞天花板时攻击力  被围能撑   开局被围能撑')
        for g in [1.04, 1.06, 1.08, 1.10, 1.13, 1.16]:
            r = report({**G, 'atk': g}, shape, a.cycles)
            r0 = report({**G, 'atk': g}, shape, a.cycles)['rows'][0]
            hold0 = MECH_HP / (CONTACT * r0['atk'] / 2 * (1 - ARMOR))
            print('  %-7s %-17s %-10s %.1f 秒' % (g, f(r['atk']), '%.1f 秒' % r['hold'], hold0))
        print()
    if a.sweep in ('coin', 'both'):
        print('金币成长 G_coin（其余不变）：')
        print('  G_coin  收入周期倍率  买得起整棵树(104万)  局末累计金币  = 造价的')
        for g in [1.00, 1.03, 1.05, 1.08, 1.10, 1.15]:
            r = report({**G, 'coin': g}, shape, a.cycles)
            rich = r['rich']
            print('  %-7s %-13s %-21s %-13s %s 倍' % (
                g, '%.3f' % (G['cnt'] * g),
                ('%.1f 分钟' % (rich['t'] / 60)) if rich else '一局都不够',
                f(r['cum']), f(r['cum'] / TREE_COST)))
        print()
    if a.sweep:
        return

    r = report(G, shape, a.cycles)
    rows = r['rows']
    print('G_hp=%.2f  G_cnt=%.2f  G_atk=%.2f  G_coin=%.2f   SHAPE_HP[4]=%s  SHAPE_CNT[4]=%s'
          % (G['hp'], G['cnt'], G['atk'], G['coin'], a.tank_hp, a.tank_cnt))
    print('\n逐波（前 2 个周期）：')
    print('波   周期.位  时间   生成方式          速度  数量     单只血量   攻击力  单只金币  波总血量')
    for x in rows[:16]:
        print('%-4d %d.%d    %5ds %-17s %.1f  %-8s %-10s %-7s %-9s %s' % (
            x['n'], x['cycle'], x['k'], x['t'], PATTERN[x['k'] - 1], SPEED[x['k'] - 1],
            f(x['cnt']), f(x['hp']), f(x['atk']), f(x['coin']), f(x['total_hp'])))
    print('\n周期汇总：')
    print('周期  时间段        基础血量   坦克血量    数量     攻击力  周期总血量  需求DPS   占天花板  被围能撑  累计金币')
    for c in range(1, a.cycles + 1):
        seg = [r2 for r2 in rows if r2['cycle'] == c]
        if c > 3 and c % 2 and c < a.cycles:
            continue
        tot = sum(r2['total_hp'] for r2 in seg)
        need = tot / (CYCLE * WAVE_GAP)
        atk = seg[-1]['atk']
        hold = MECH_HP / (CONTACT * atk / 2 * (1 - ARMOR))
        print('%-5d %4d-%4ds  %-10s %-11s %-8s %-7s %-11s %-9s %-9s %-9s %s' % (
            c, seg[0]['t'], seg[-1]['t'] + 10, f(seg[0]['hp']), f(max(x['hp'] for x in seg)),
            f(seg[0]['cnt']), f(atk), f(tot), f(need),
            '%.0f%%' % (100 * need / CEILING), '%.1fs' % hold, f(seg[-1]['cum_coin'])))
    print('\n交叉点：')
    if r['hit']:
        print('  需求DPS 超过天花板 38,400：周期 %d（%.1f 分钟）' % r['hit'])
        print('  此时：基础敌人 %s 血，坦克波 %s 血，数量 %s，被围能撑 %.1f 秒'
              % (f(r['base_hp']), f(r['tank']), f(r['cnt']), r['hold']))
    if r['rich']:
        print('  累计金币买得起整棵树 104 万：波 %d（%.1f 分钟）' % (r['rich']['n'], r['rich']['t'] / 60))


if __name__ == '__main__':
    main()
