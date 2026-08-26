# Demo 3：数值验证 —— 工程结构与用法

2026-08-24 起。前两个 Demo 验证的是"能不能做得好看、跑得动"（`scenes/` + `shaders/` +
`benchmark/`，结论见 `docs/最终结论_GoNoGo.md`）。第三个 Demo 的目标完全不同：
**在没有美术的前提下，把规则和数值跑通、跑快、跑很多次**，对应设计文档
`docs/机甲幸存者_核心玩法与武器升级系统_v0.2.md` §10。

## 一句话结构

> 规则写在 `sim/`（纯逻辑），数值写在 `data/`（JSON），
> `demos/03_balance/Play.tscn` 是给人玩的壳，`Batch.gd` 是不带壳的批量跑。

```
sim/                纯逻辑。禁止 Node / get_tree() / randf() / 引擎 delta
  core/             SimWorld(固定步长 tick) SimConfig Rng(种子化) Grid SpatialHash
  entities/         Mech(3x3 平台/四面装甲/8 槽位) Turret Enemy Projectile
  systems/          SpawnDirector(§4.1 四种 pattern) CombatSystem UpgradeSystem
  agent/            Agent(输入唯一入口) HumanAgent ScriptedAgent(自动策略)
  data/             DataDB —— 读 data/*.json，并校验没实现的枚举
  telemetry/        RunLog —— §23 那一整套指标，一局一行 CSV
data/               balance / weapons / enemies / waves / upgrades  ← 调数值只改这里
demos/Launcher.tscn 工程入口，三个 Demo 各走各的
demos/03_balance/   Play.gd(2D 占位表现层) Batch.gd(headless 批量)
tools/sim/analyze.py  统计 out/*.csv
out/                 模拟结果（CSV 不进库，结论写进 docs/balance/）
```

## 为什么这么切

要求里有一条是"可以短时间内跑大量的次数统计结果"。这条决定了一切：
**规则代码一旦碰 Godot 的节点树，就跑不了 10000 倍速，也没法复现。**
所以 `sim/` 里一个 Node 都没有，只有 `RefCounted` 和固定步长的 `tick(dt)`：

- 手玩：`Play.gd` 按累加器喂 30Hz，同时把状态画成方块；
- 批量：`Batch.gd` 拿 `while` 死喂，一局 15 分钟游戏时间约 0.2 秒墙钟。

同一个 seed 两边必须跑出一模一样的结果 —— 所以 sim 里禁止 `randf()`（全局状态），
只能用 `Rng`（种子化）。**手玩和自动模拟走同一个 `Agent` 接口**，
不然"模拟说这套强、手玩感觉弱"永远说不清是规则差异还是数值问题。

## 四条规矩

1. `sim/` 里出现 `Node`、`randf()`、`Time`、`get_tree()`、引擎 `delta` —— 算 bug。
2. 表现层单向读 sim，绝不反写。换 2D/3D/真美术不动一行规则。
3. `.gd` 里出现写死的游戏数值 —— 算 bug，挪进 `data/*.json`。
4. 每局（手玩也算）落一行 `RunLog`，两种测试落同一张表才能横向比。

## 怎么跑

手玩：

```
Godot_v4.7-stable_win64_console.exe --path <项目> res://demos/03_balance/Play.tscn
# WASD 移动   Q/E 转 90°   1/2/3 选升级   空格 4 倍速   R 换种子重开
# 调试可加 `-- skip=150` 直接快进到第 150 秒
```

批量模拟（不开窗口）：

```
Godot_v4.7-stable_win64_console.exe --headless --path <项目> \
    --script res://demos/03_balance/Batch.gd -- \
    runs=50 duration=900 move=kite,stand pick=dps,armor out=res://out/runs.csv label=v1
python tools/sim/analyze.py out/runs.csv --weapons
```

`move` / `pick` 用逗号可以列多个策略，跑笛卡尔积，一次比几套打法。
策略本身也是被测对象：`stand`（站着不动）能活多久，正是 §23 里
`time_stationary` / "后期站桩"这条设计红线要回答的问题。

## 现在实现到哪

对应设计文档 §22 的 **Phase 1**：移动、90° 转向、分方向敌潮、自动炮塔（索敌受
槽位弧 × 武器弧限制，所以朝向真的影响火力）、接触伤害、四面装甲/尖刺、
经验升级三选一、遥测落盘。武器三把（单发枪/机枪/加农炮），敌人三种（虫群/疾行者/重装）。

**还没做**（字段/枚举已经留好，加载时会报警提示未实现）：

- 敌人运动方式只有 `chase`，§4.2 的停顿/波浪/螺旋/直线还没写；
- 远程敌人、分裂敌人（§4.3）；
- 金币商店（§8）—— 现在是升级即三选一，接商店时只换 `UpgradeSystem` 的发牌来源；
- 融合、终极大招（§7.4 / Phase 4-5）—— `RunLog` 里的相关字段先输出 0，免得以后改表头；
- 底座 4x4 升级（§6.3）。

## 首轮数值的状态

`data/` 里的是**首轮拍脑袋值，还没调过**。当前 10 局 × 4 策略的基线：

| 策略 | 平均存活 | 击杀 | 等级 |
|---|---|---|---|
| kite/dps | 270s | 377 | 10.2 |
| kite/armor | 154s | 157 | 6.9 |
| stand/dps | 150s | 169 | 7.2 |
| stand/armor | 89s | 79 | 4.9 |

排序是对的（走位 > 站桩，火力 > 装甲），但 15 分钟局长的存活率是 0%，
中期敌潮压过成长曲线。这正是这个 Demo 要解决的问题 —— 从 `data/waves.json` 和
`data/weapons.json` 开始调，每轮结论记到 `docs/balance/`。

## 自动模拟的策略：四档谱系

模拟结果 = f(数值, 玩家策略)。只写一个 AI，测出来的是 AI 的水平而不是数值的好坏。
所以有四档，结果读成**区间**：

| 档 | 移动 | 转向 | 用途 |
|---|---|---|---|
| `stand` | 不动 | 不转 | 绝对下界：一点操作都没有能活多久 |
| `line` | 固定方向直跑 | 车头跟着移动方向 | 下界+：环形地图上最笨的有效解 |
| `field` | 三层（势场 + 短程试探 + 战略方向） | 效用比较 | 主力，代表"会玩的普通人" |
| `oracle` | 同上，视野更远、预测更长、试探更密 | 同上 | 上界：打得再好也就这样 |

- 带宽太窄（`field` 和 `stand` 差不多）→ 技术不影响结果，数值没意思；
- 带宽太宽 → 结论被技术掩盖，数值调不准；
- 拿 `oracle` 的存活时间去和 `tools/sim/wave_shape.py` 的推演对齐才有意义。

参数在 `data/agents.json`——**AI 的参数本身也是被测对象**，扫数值时要连它一起扫。

### 移动的三层

```
第 3 层 · 1 Hz   · 战略方向：读 §7.6 的四方向威胁，往最空的那边偏（strategic_weight）
第 2 层 · 4 Hz   · 短程试探：四个方向各做 lookahead_sec 的线性外推，
                   算"未来会被多少威胁碰到"。敌人位置要外推——
                   第 5/7 波是 2.5 格/秒，比机甲的 2 还快，不预测一定被贴上
第 1 层 · 每 tick · 势场微调：panic_radius 内有敌人时，排斥力直接压过缓存的试探结果，
                   防止在密集区里卡住
```

所有距离走 `Torus`；平局按 上>右>下>左 的固定顺序打破，保证可复现。

### 转向的效用比较

转向是**要付 1 秒零输出的离散决策**（§3.3），所以不是"敌人在哪边转哪边"：

```
收益 = 转 90° 后的火力覆盖 - 当前覆盖
覆盖 = Σ_方向 min(该方向己方DPS, 该方向敌人血量 / turn_expect_sec)
       （超出"T 秒内清空"所需的火力算浪费，不计入）
代价 = 当前覆盖 × 转向秒数
只有 收益 × T > 代价 × (1 + turn_hysteresis) 且距上次转向超过 turn_min_gap 才转
```

有个便宜的实现技巧：机甲顺时针转 90°，所有槽位的弧也整体转 90°，
所以"转后各方向的己方 DPS"就是把 `MapEval.dir_dps` **循环移一位**，不用重算几何。

**对称 build 下收益恒为 0，AI 自然不转**——这正好把"转向到底有没有用"变成可观测的数据，
而不是靠感觉断言。

### 怎么校验 AI 不蠢也不神

`RunLog` 里为此加了两个量：`time_contacted`（被敌人贴住的时长占比）和
`avg_nearest`（离最近敌人的平均距离）。判据：

1. 人机同种子对拍——手玩 seed=1000，AI 也跑 seed=1000，比存活时间和贴身占比；
2. 上界差距——`oracle` 比 `field` 好太多说明 `field` 还有明显改进空间，当前结论不可信；
3. 单调性——机甲速度调高存活必须变长，敌人速度调高必须变短；不满足说明 AI 卡在局部最优。
