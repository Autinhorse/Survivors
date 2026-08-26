#!/usr/bin/env python3
"""按设计文档 v0.3 §4.5 推演波次曲线。改了 §4.5 就来改这里的 OPS，再跑一遍。

    python tools/sim/wave_curve.py           # 逐波表 + 周期汇总
    python tools/sim/wave_curve.py --waves 40

波间隔 10 秒，8 波一个循环（= 80 秒）。第九波回到第一波的形态，
数量/血量/攻击力/金币继承第八波，然后重复。
"""
import argparse

# 进入周期内第 k 位时施加的算子。cnt: ('+',n) 加法 / ('*',x) 乘法
OPS = {
    1: dict(cnt=('+', 0),    hp=1.0,   atk=1.00, coin=1.00),  # 继承上一波
    2: dict(cnt=('+', 10),   hp=1.10,  atk=1.00, coin=1.05),
    3: dict(cnt=('+', 0),    hp=1.20,  atk=1.02, coin=1.05),
    4: dict(cnt=('*', 1/6),  hp=6.00,  atk=1.02, coin=4.00),
    5: dict(cnt=('*', 8.0),  hp=0.125, atk=1.00, coin=0.25),
    6: dict(cnt=('+', 10),   hp=1.00,  atk=1.00, coin=1.05),
    7: dict(cnt=('*', 4.0),  hp=0.20,  atk=1.00, coin=1.00),
    8: dict(cnt=('*', 0.25), hp=6.00,  atk=1.01, coin=1.05),
}
PATTERN = {1: 'random 2.0s', 2: 'random 1.0s', 3: 'Group 瞬发', 4: 'Circle 瞬发',
           5: 'random 0.4s', 6: 'Circle 瞬发 远程', 7: 'Group 瞬发', 8: 'Circle 瞬发 直线'}
SPEED = {1: 1.0, 2: 1.0, 3: 1.5, 4: 0.5, 5: 2.5, 6: 1.5, 7: 2.5, 8: 2.0}
INTERVAL = {1: 2.0, 2: 1.0, 3: 0.0, 4: 0.0, 5: 0.4, 6: 0.0, 7: 0.0, 8: 0.0}

START = dict(cnt=20.0, hp=100.0, atk=10.0, coin=50.0)
WAVE_GAP = 10.0
CYCLE = 8

# 对照基准
CEILING = 38400.0     # 4 门满级穿刺枪 4x(8000+2x800)，即 4x4 底座的火力上限
TREE_COST = 831200.0  # 上面那 4 门的全链条造价
ARMOR_COST = 204600.0 # 四面满级旋转滚筒
MECH_HP = 1000.0
CONTACT = 12          # 3x3 车体一圈同时能贴住的敌人数（估）
ARMOR_CUT = 0.45      # 装甲减伤封顶
MAP_CELLS = 200 * 100


def simulate(n_waves):
    rows, cum = [], 0.0
    cnt, hp, atk, coin = START['cnt'], START['hp'], START['atk'], START['coin']
    for n in range(1, n_waves + 1):
        k = (n - 1) % CYCLE + 1
        if n > 1:
            op = OPS[k]
            mode, v = op['cnt']
            cnt = cnt + v if mode == '+' else cnt * v
            hp *= op['hp']; atk *= op['atk']; coin *= op['coin']
        cum += cnt * coin
        rows.append(dict(n=n, k=k, cycle=(n - 1) // CYCLE + 1, t=WAVE_GAP * (n - 1),
                         cnt=cnt, hp=hp, atk=atk, coin=coin, cum_coin=cum,
                         total_hp=cnt * hp, spawn_sec=cnt * INTERVAL[k]))
    return rows


def f(x):
    if x >= 1e9:  return '%.2e' % x
    if x >= 1e6:  return '%.2fM' % (x / 1e6)
    if x >= 1000: return '{:,.0f}'.format(x)
    if x >= 10:   return '%.0f' % x
    return '%.1f' % x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--waves', type=int, default=24)
    ap.add_argument('--cycles', type=int, default=19)
    a = ap.parse_args()
    rows = simulate(max(a.waves, a.cycles * CYCLE))

    print('逐波：')
    print('波   周期.位  时间   生成方式          速度  数量       单只血量   攻击力  单只金币  波总血量')
    for r in rows[:a.waves]:
        print('%-4d %d.%d    %5ds %-17s %.1f  %-10s %-10s %-7s %-9s %s' % (
            r['n'], r['cycle'], r['k'], r['t'], PATTERN[r['k']], SPEED[r['k']],
            f(r['cnt']), f(r['hp']), f(r['atk']), f(r['coin']), f(r['total_hp'])))

    print('\n周期汇总：')
    print('周期  时间段        周期总血量  平均需求DPS  占天花板  末攻击力  被围承受DPS(45%甲)  抗住秒  累计金币')
    for c in range(1, a.cycles + 1):
        seg = [r for r in rows if r['cycle'] == c]
        tot = sum(r['total_hp'] for r in seg)
        need = tot / (CYCLE * WAVE_GAP)
        last = seg[-1]
        dps = CONTACT * last['atk'] / 2.0 * (1 - ARMOR_CUT)
        pct = '%.0f%%' % (100 * need / CEILING) if need < CEILING * 100 else '>>100x'
        print('%-5d %4d-%4ds  %-11s %-12s %-9s %-9s %-19s %-7s %s' % (
            c, seg[0]['t'], last['t'] + WAVE_GAP, f(tot), f(need), pct,
            f(last['atk']), f(dps), '%.1f' % (MECH_HP / dps), f(last['cum_coin'])))

    print('\n收敛后的周期倍率：')
    a8 = [r for r in rows if r['k'] == 8]
    p, q = a8[-2], a8[-1]
    print('  数量 x%.2f   单只血量 x%.3f   攻击力 x%.3f   单只金币 x%.3f   波总血量 x%.2f'
          % (q['cnt']/p['cnt'], q['hp']/p['hp'], q['atk']/p['atk'],
             q['coin']/p['coin'], q['total_hp']/p['total_hp']))

    print('\n交叉点：')
    for c in range(1, a.cycles + 1):
        seg = [r for r in rows if r['cycle'] == c]
        if sum(r['total_hp'] for r in seg) / (CYCLE * WAVE_GAP) > CEILING:
            print('  需求DPS 超过火力天花板 %s：周期 %d（波 %d-%d，%.1f 分钟）'
                  % (f(CEILING), c, seg[0]['n'], seg[-1]['n'], seg[0]['t'] / 60))
            break
    for label, cost in [('4 门满级穿刺枪 %s' % f(TREE_COST), TREE_COST),
                        ('整棵树+四面满级装甲 %s' % f(TREE_COST + ARMOR_COST), TREE_COST + ARMOR_COST)]:
        r = next((r for r in rows if r['cum_coin'] > cost), None)
        if r:
            print('  累计金币买得起%s：波 %d（%.1f 分钟）' % (label, r['n'], r['t'] / 60))
    r = next((r for r in rows if r['k'] == 7 and r['cnt'] > MAP_CELLS / 4), None)
    if r:
        print('  单次瞬发数量超过地图容量的 1/4（%s 格地图放 %s 只）：波 %d（%.1f 分钟）'
              % (f(MAP_CELLS), f(r['cnt']), r['n'], r['t'] / 60))
    r = next((r for r in rows if r['k'] == 5 and r['spawn_sec'] > CYCLE * WAVE_GAP), None)
    if r:
        print('  第5位大群刷不完（需 %s 秒 > 一个周期 80 秒）：波 %d（%.1f 分钟）起'
              % (f(r['spawn_sec']), r['n'], r['t'] / 60))


if __name__ == '__main__':
    main()
