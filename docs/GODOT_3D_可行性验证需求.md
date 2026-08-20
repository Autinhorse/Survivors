# Godot 3D 可行性验证需求 / Vertical Slice Benchmark
版本：0.1  
用途：技术可行性 + 视觉可行性验证  
引擎：Godot 4.x

---

# 1. 项目目的

这个项目**不是正式游戏工程**。

它是一个规模较小、可以随时丢弃，但结构清晰的 Vertical Slice / Benchmark，用来回答一个核心问题：

> Godot 是否能够支持我们计划中的视觉质量、同屏敌人数量、特效密度，以及低配 PC 性能要求？

本测试应大体复现一款成熟的斜俯视 3D 动作游戏的视觉复杂度和完成度，例如 **Gatling Gears（2011）**。

目标**不是逐像素复刻参考图**，而是复现参考图所体现的：

- 场景密度；
- 摄像机角度；
- 环境复杂度；
- 光照质量；
- 低面数资产表现；
- 同屏对象数量；
- 战斗信息可读性；
- 弹道和 VFX 密度；
- 整体“完成度较高的商业游戏”观感。

这个实验需要在正式开发大量投入之前，验证核心技术路线是否成立。

---

# 2. 目标游戏概念

计划中的正式游戏是一款：

- 3D；
- 斜俯视 / 高机位；
- 动作 / 生存类；
- 主角是大型机械平台、机甲城市或机甲单位；
- 敌人以机械、小型机甲、小人为主；
- 同屏敌人数量较多；
- 战斗依赖大量弹道、爆炸、烟雾、电击、激光等特效；
- 美术风格为 Stylized / Low-to-Mid Poly，而不是现代 AAA 写实。

核心视觉体验来自：

- 相对较远的固定或半固定镜头；
- 强轮廓、清晰色块；
- 大量敌人；
- 大量武器火力；
- 环境丰富但模型本身不过度精细；
- 机械部件通过程序控制做动画；
- 场景和单位主要依赖可复用资产和模块化构件。

我们的目标不是达到 AAA 级别，而是达到：

> 一款成熟、完成度较高、视觉舒服的商业 3D 独立游戏水平。

---

# 3. 为什么适合低面数 3D

由于摄像机距离较远，因此：

- 小尺寸几何细节价值较低；
- 轮廓比拓扑细节更重要；
- 角色面部通常不重要；
- 机械构造比复杂人形角色更适合；
- 动画可以大量采用刚体构件旋转、摆动、平移；
- 环境资产可以高度复用；
- 小兵不需要复杂 Skeleton / Skinning。

美术方向应主动利用这些特点，而不是追求近景高精度。

---

# 4. 目标单位规模

## 4.1 小型敌人

预计最终游戏同屏数量：

    500–1000

性能压力测试：

    1500–2000+

大致面数：

    100–300 triangles / unit

机械构件数量：

    约 3–8 个

例如：

- 主体；
- 左腿；
- 右腿；
- 武器；
- 炮塔；
- 天线；
- 轮子 / 履带。

这类敌人应尽量避免传统复杂骨骼动画。

优先采用：

- 程序化 Transform；
- 刚体构件动画；
- Shader 动画；
- 批量动画；
- 共享动画参数。

最终应考虑：

> Data-Oriented + MultiMesh

而不是让 1000 个敌人各自拥有完整复杂 SceneTree。

---

## 4.2 中型敌人

预计同屏：

    10–30

大致面数：

    1,000–3,000 triangles

机械构件：

    约 10–30 个

可以使用正常 Godot 场景结构：

- Node3D；
- 多构件；
- Collision；
- 程序动画；
- 较复杂的状态控制。

---

## 4.3 大型敌人 / Boss

预计同屏：

    1–3

允许：

- 更高面数；
- 正常 Node3D 层级；
- 更复杂动画；
- 更贵的材质；
- 专属 VFX；
- 实时阴影；
- 更复杂逻辑。

优化重点不应放在 Boss，而应放在大量小型敌人。

---

# 5. 性能判断原则

**面数本身预计不是主要瓶颈。**

例如：

    1000 × 300 triangles
    ≈ 300,000 triangles

这个几何量对于现代 GPU 并不大。

真正需要重点测试的是：

- Node 数量；
- draw calls；
- Transform 更新；
- Collision 数量；
- Physics；
- 每个敌人的 `_process()`；
- 寻敌逻辑；
- Pathfinding；
- Shadow；
- Transparency；
- Particle Overdraw；
- Projectile 数量；
- Dynamic Light；
- VFX 密度。

不要为了把 300 面压成 150 面而过早优化，却忽略更大的性能消耗。

---

# 6. 大规模敌人架构验证

实验中需要最终比较两种方案。

## 方案 A：传统 Node 架构

例如：

    Enemy
    ├── Body
    ├── LeftLeg
    ├── RightLeg
    ├── Gun
    └── Collision

它主要作为性能基线。

不默认它适合作为 1000 敌人的最终架构。

---

## 方案 B：Data-Oriented + MultiMesh

概念：

    EnemyManager

        EnemyData[1000+]

        MultiMesh_Body
        MultiMesh_LeftLeg
        MultiMesh_RightLeg
        MultiMesh_Gun

敌人的游戏状态尽可能存储在紧凑数据结构中，而不是完全依赖独立 Node。

典型数据：

    position
    rotation
    velocity
    hp
    enemy_type
    target
    state
    animation_phase

视觉表现尽量批处理。

实验需要测出：

> 传统 Node 与 Data-Oriented + MultiMesh 的性能差距有多大。

---

# 7. 程序化机械动画

小兵应尽量避免：

- Skeleton3D；
- Skinning；
- 复杂 AnimationTree；
- 每个单位独立复杂动画状态机。

机械运动可以用数学方式实现，例如：

    left_leg_rotation  = sin(time + phase)
    right_leg_rotation = -sin(time + phase)
    body_bob           = sin(time * 2 + phase)

每个单位可以带不同的 `animation_phase`，避免所有敌人同步摆动。

实验后期应测试：

- CPU 批量 Transform；
- MultiMesh Instance Transform；
- Shader；
- Instance Custom Data；

以及它们的组合方式。

---

# 8. 首个视觉验证场景

首个 Benchmark 场景尺寸：

    约 60 m × 46 m

约定：

    1 Godot unit = 1 meter

> **尺寸修正记录（2026-08-20，Milestone 1 实测）**
>
> 本节原写 30 m × 30 m，是按参考图目测估的，实测偏小约 1.5 倍。
>
> 方法：不估绝对米数，而是量物体在画面里的**宽度占比**，与本项目同类物体对比。
>
> | 锚点 | 参考图占画面宽 | 30×30 方案 | 倍数 |
> |---|---|---|---|
> | 玩家机甲 | ~5.1% | ~7.4% | 1.45× |
> | 大房子 | ~13.3% | ~19.6% | 1.47× |
> | 小兵 | ~1.7% | ~2.9% | 1.7× |
>
> 三个锚点一致 → 参考图的可视地面范围约 60 m 宽 × 46 m 深。
>
> 关键结论：**物体尺寸本来就是对的**（按 1.5× 换算后房子占比 13.3%，与参考图一致）。
> 错的是相机太近、布局堆得太密。因此修正方式是「摊开布局 + 抬高相机」，
> **不是把物体做小** —— 后者会破坏 1 unit = 1 m，污染之后所有资产的尺寸基准。
>
> 详见 `docs/M1_greybox_报告.md`。

参考目标为当前提供的 Gatling Gears 场景截图。

只要求达到相似的视觉复杂度和场景构成，不要求精确复刻。

场景至少包含：

## 地形

- 草地；
- 泥土地面 / 小路；
- 河流；
- 河岸 / 悬崖；
- 必要的高低差。

## 建筑与结构

- 木桥；
- 1–2 栋小建筑；
- 必要时加入电线杆 / 工业构件；
- 木箱 / 杂物。

## 自然环境

- 若干石头；
- 大石块；
- 树；
- 灌木；
- 地面草丛 / 花草装饰。

## Gameplay 对象

- 1 个玩家机甲；
- 一批小型敌人；
- 可选 1 个中型敌人。

## VFX

- muzzle flash；
- bullet / tracer；
- hit spark；
- rocket；
- rocket smoke trail；
- explosion；
- smoke / fire；
- Tesla / electric effect。

---

# 9. 摄像机

使用固定高机位 / 斜俯视相机。

初始建议：

    camera height: 25–35 m
    downward angle: 50–60°
    FOV: 35–45°

这些只是初始参考，需要根据视觉效果调整。

> **已确认参数（2026-08-20，Milestone 1）**
>
>     camera height: 44 m
>     downward angle: 60°
>     FOV: 40°
>
> 可视地面约 65.7 m × 44.7 m，与 §8 修正后的场景尺寸匹配。
>
> 注意：**俯角和相机高度必须联动**。俯角越大可见纵深越短，只改俯角不抬相机，
> 场景会装不进画面。`tools/gen_greybox.py` 每次会打印可见地面宽度和纵深，用来校验。
>
> 另外俯角越大，建筑立面 / 桥侧面 / 崖壁露出越少，3D 体积感递减；
> 60° 是「够俯视」和「侧面细节还在」的平衡点（对比过 55 / 60 / 65 / 70）。

正式游戏预计不会依赖自由旋转镜头。

受控镜头本身就是优化和降低资产要求的重要手段。

---

# 10. Renderer 目标

初始使用：

    Godot Mobile Renderer

原因：

- 游戏不依赖复杂现代 AAA 渲染；
- 目标包括集成显卡；
- 斜俯视场景适合较轻量渲染；
- 不需要复杂实时 GI。

之后可以再比较：

    Forward+

用于高画质 Preset。

不要在 Benchmark 一开始就绑定 Forward+ 专属高成本特性。

---

# 11. 目标硬件

不要只在高端开发机上验证。

目标最低性能测试硬件大致包括：

- Intel Iris Xe；
- AMD Radeon 680M；
- AMD Radeon 780M；
- 类似级别现代集显。

高端开发 GPU 只能用于开发，不应作为性能判断依据。

---

# 12. 性能目标

优先目标：

    1920 × 1080
    60 FPS

核心同屏敌人数：

    500–1000

> 注意（2026-08-20）：按 §8 修正后，这些敌人是分布在约 60 × 46 m 的可视范围内，
> 不是原先假定的 30 × 30 m。面积差一倍多，单位密度、寻敌半径、
> 群体行为的实际压力都要按新面积理解。

极端高负载时可接受目标：

    40–60 FPS

如果持续接近或低于：

    30 FPS

需要进一步分析并优化。

这些数字是初始工程目标，可以根据最终测试结果调整。

---

# 13. VFX 设计原则

战斗“热闹感”预计来自两个核心因素：

1. 同屏敌人多；
2. 武器和特效多。

因此 VFX 是一级性能和视觉需求。

可能包括：

- 机枪 tracer；
- muzzle flash；
- projectile trail；
- rocket；
- explosion；
- smoke；
- fire；
- spark；
- hit flash；
- lightning；
- Tesla chain；
- laser；
- shockwave；
- debris；
- ground effect。

测试场景不能只测试几何。

必须测试真实的“战斗繁忙度”。

---

# 14. VFX 生产方式

正式游戏预计不会从零制作所有特效。

可能工作流：

    现成 VFX 资源
        +
    texture / flipbook / mesh
        +
    Godot Particle
        +
    Shader
        +
    程序控制
        +
    AI 辅助修改

AI 可以负责：

- 分析效果结构；
- 写 Shader；
- 配粒子参数；
- 改颜色；
- 改生命周期；
- 生成多种变体；
- 将现有效果接入 Gameplay；
- 优化；
- 看截图 / 视频后提出调整。

但：

> VFX 最终仍需要人类视觉判断。

不要假设完全无人监督的 AI 可以自动把特效调到满意。

---

# 15. VFX 性能风险

重点关注：

- 大量透明粒子；
- smoke overdraw；
- additive blend；
- 大量重叠爆炸；
- trails；
- dynamic lights；
- shadow；
- projectile 数量。

很可能出现：

> 几何很轻，但 VFX 成为 GPU 瓶颈。

因此必须把“敌人数量测试”和“VFX 压力测试”分开。

---

# 16. 光照策略

参考图的视觉质量高度依赖：

- 明确主光方向；
- 强阴影；
- 环境光；
- 色调；
- Bloom / Glow；
- 空间层次。

初始建议：

- 1 个 DirectionalLight3D；
- WorldEnvironment；
- 受控 Ambient；
- Tonemapping；
- 少量 Glow / Bloom；
- Shadow；
- 必要时 SSAO。

避免大量 Dynamic Light。

武器效果尽量通过：

- emission；
- particle；
- glow；

制造“发光感”，而不是每个爆炸都创建真实动态光源。

---

# 17. 阴影测试

1000 个敌人的实时阴影可能昂贵。

至少测试：

## Shadow A

所有可见单位都投实时阴影。

## Shadow B

只有：

- 环境；
- 玩家；
- 中型敌人；
- Boss；

投真实阴影。

小兵不投。

## Shadow C

小兵使用：

- blob shadow；
- 简单投影假阴影。

记录：

- 视觉差异；
- 性能差异。

---

# 18. 水面

不要使用真实流体模拟。

河流使用低成本方案，例如：

- 简单 River Mesh；
- scrolling normal；
- scrolling texture；
- Fresnel；
- 简单透明；
- foam；
- 瀑布 / 急流使用 particle。

目标是：

> 从 Gameplay Camera 看起来可信。

不追求物理准确。

---

# 19. 地形

60×46 m Benchmark 不需要复杂 Terrain System。

可以直接使用：

    Ground Mesh
        +
    Material Blend
        +
    Mask
        +
    Decal
        +
    River Mesh
        +
    Modular Cliff

正式游戏 Terrain 系统以后再考虑。

---

# 20. 资产原则

环境应优先使用模块化、可复用资产。

一个正式 Biome 可能最终只需要：

    5–10 rocks
    5–10 trees
    several bushes
    cliff modules
    bridge modules
    buildings
    fences
    crates
    industrial props
    ground materials

来源可以是：

- AI 生成；
- 程序生成；
- 手工建模；
- 商业 / 免费授权资源；
- 现有资产修改。

第一阶段视觉验证不要求必须使用 AI 3D。

---

# 21. AI 3D 资产工作流：单独验证

AI 3D 应独立于 Godot 基础渲染验证。

建议测试资产：

- 一组 Rock；
- 一座 Bridge；
- 一个 Mech。

可能流程：

    Reference / Prompt
        ↓
    AI 3D
        ↓
    Blender
        ↓
    Cleanup
        ↓
    Poly Reduction / Retopo
        ↓
    Scale / Origin 统一
        ↓
    Material 统一
        ↓
    GLB Export
        ↓
    Godot Import

记录：

- 生成时间；
- 人工 Cleanup 时间；
- 最终质量；
- 风格一致性；
- 是否可直接用于游戏。

不要让 AI 资产生成问题阻碍第一轮 Godot Renderer 验证。

---

# 22. 实验里程碑

整个实验分为五个 Milestone。

每个 Milestone 回答一个不同问题。

不要自动全部做完。

---

# Milestone 1 — Greybox / 构图验证

## 要回答的问题

Godot 是否能快速搭出符合目标的场景比例、镜头和构图？

## 实现内容

全部使用 Primitive / Placeholder：

- 约 60×46 m 场景（见 §8 尺寸修正记录）；
- 草地 / 地面；
- 河流；
- 木桥；
- 河岸 / Cliff；
- 两栋建筑；
- 石头；
- 树；
- 玩家机甲占位；
- 若干敌人占位；
- 固定相机；
- DirectionalLight3D；
- 基础 WorldEnvironment。

## 暂时不要实现

- Gameplay；
- Pathfinding；
- AI；
- 复杂材质；
- VFX；
- 正式资产生产；
- 优化。

## 通过标准

从最终 Gameplay Camera 看：

> 场景结构、比例和视觉构成已经大致符合参考图。

---

# Milestone 2 — 视觉质量验证

## 要回答的问题

Godot 是否能够达到令人满意的静态 3D 商业游戏画面？

## 增加内容

- Grass Material；
- Dirt；
- Water Shader；
- Rocks；
- Cliffs；
- Trees；
- Bushes；
- Bridge Material；
- Buildings；
- Props；
- Lighting Refinement；
- Shadows；
- Ambient；
- Glow / Tonemapping；
- 可选 SSAO；
- 简单 Atmospheric Effect。

## 通过标准

截图不能再像“引擎测试场景”。

目标：

> 达到参考画面大约 70–80% 或更高的主观视觉完成度。

这一项必须人工判断。

如果视觉不满意：

> 停止后续性能测试，优先解决视觉问题。

---

# Milestone 3 — 战斗表现 / VFX 验证

## 要回答的问题

战斗是否可以做到足够热闹、清晰、好看？

至少实现三类代表性武器。

## Machine Gun

包含：

- muzzle flash；
- rapid tracer；
- hit spark。

建议初始：

    约 10 rounds/sec

---

## Rocket

包含：

- visible projectile；
- smoke trail；
- impact explosion；
- debris / sparks。

建议初始：

    约 2 rockets/sec

---

## Tesla / Electric

包含：

- electric arc / beam；
- emission；
- hit flash；
- 可选 chain / area effect。

建议初始：

    约 1 activation/sec

---

## 通过标准

动态战斗应：

- 足够热闹；
- 武器有区分；
- 信息可读；
- 不依赖大量高成本动态光；
- 特效质量达到可接受商业游戏水平。

需要人工视觉评估。

---

# Milestone 4 — 群体性能测试

## 要回答的问题

Godot 在合理架构下到底能支持多少小型敌人？

初始敌人逻辑保持简单：

    Spawn
        ↓
    Move
        ↓
    Hit
        ↓
    Death

暂时不要加入：

- Navigation；
- 复杂 Pathfinding；
- Formation；
- Behavior Tree；
- 大规模 target search。

测试人数：

    100
    250
    500
    750
    1000
    1500
    2000

如果性能仍足够，可以继续增加。

至少记录：

- enemy count；
- FPS；
- frame time；
- draw calls；
- instance count；
- triangle count；
- CPU / GPU timing（如果可获取）。

结果尽量保存为：

    benchmark/results.csv

---

# Milestone 5 — 架构 / 优化比较

## 要回答的问题

正式项目大量小兵应该使用什么架构？

比较：

### Conventional Node

vs

### EnemyManager + Data-Oriented + MultiMesh

使用尽可能相同的可见单位结构。

至少比较：

    500
    1000
    2000

如有必要继续提高。

最终结果用于确定正式游戏小兵架构。

---

# 23. 独立 VFX Stress Test

不要把 Enemy 性能和 VFX 性能混在一起。

当场景可以稳定支持约 1000 敌人后，再固定人数测试 VFX。

示例：

## VFX Level 0

    VFX Off

## VFX Level 1

    ~100 projectiles
    ~10 explosions/sec

## VFX Level 2

    ~300 projectiles
    ~30 explosions/sec

## VFX Level 3

    ~500 projectiles
    ~50 explosions/sec

## VFX Level 4

    ~1000 projectiles
    ~100 explosions/sec

这些属于 Stress Test，不代表正式玩法。

目的：

确认瓶颈来自：

- crowd simulation；
- geometry；
- draw calls；
- shadows；
- particles；
- transparency；
- projectile；
- 其他 renderer feature。

---

# 24. Graphics Preset

最终架构应支持：

- Low；
- Medium；
- High。

概念例如：

| Feature | Low | Medium | High |
|---|---|---|---|
| Renderer / Features | 轻量 | 平衡 | 高画质 |
| Small Enemy Shadow | Off / Fake | Fake | Optional Real |
| Environment Shadow | Yes | Yes | Yes |
| SSAO | Off | Low | High |
| Glow | Low | Medium | High |
| Particle Density | ~50% | ~75% | 100% |
| Smoke Density | Low | Medium | High |
| Ground Decoration | Low | Medium | High |
| Resolution Scale | 可降低 | 可选 | Native |

具体参数通过 Benchmark 决定。

---

# 25. Visual / Performance Scene 分离

视觉场景满意后保存为：

    scenes/VisualBenchmark.tscn

然后复制：

    scenes/PerformanceBenchmark.tscn

VisualBenchmark 作为视觉参考尽量保持稳定。

PerformanceBenchmark 专门用于：

- 加敌人；
- 加 VFX；
- 改架构；
- 压测；
- 优化。

---

# 26. 建议项目结构

    /
    ├── project.godot
    │
    ├── docs/
    │   ├── GODOT_3D_可行性验证需求.md
    │   └── reference/
    │       └── reference_scene.png
    │
    ├── scenes/
    │   ├── VisualBenchmark.tscn
    │   └── PerformanceBenchmark.tscn
    │
    ├── scripts/
    │   ├── environment/
    │   ├── units/
    │   └── vfx/
    │
    ├── assets/
    │   ├── environment/
    │   ├── units/
    │   ├── textures/
    │   └── vfx/
    │
    ├── shaders/
    │
    └── benchmark/
        ├── BenchmarkManager.gd
        └── results/

如果有明确技术理由可以调整。

不要为了 Benchmark 过度工程化。

---

# 27. Benchmark Manager

随着项目推进建立简单 Benchmark 系统。

最终尽量记录：

    timestamp
    hardware/profile
    graphics preset
    enemy_count
    projectile_count
    explosion_rate
    shadow_mode
    FPS_average
    FPS_1_percent_low
    frame_time
    CPU_time
    GPU_time
    draw_calls
    triangle_count

CSV 优先。

Milestone 1 不需要花大量时间做 Benchmark 系统。

---

# 28. 性能测试方法

测试必须可复现。

不要仅凭：

> “看起来挺流畅。”

每次 Stress Test 应：

    warm-up: 5 sec
    measurement: 20–30 sec

尽量记录：

- Average FPS；
- Frame Time；
- 1% Low；
- Worst Frame / Percentile。

比较不同实现时应保持：

- Camera；
- Scene；
- Resolution；
- Enemy Behavior；
- VFX 参数；

一致。

---

# 29. AI Agent / Claude Code / Codex 执行规则

AI Agent 修改项目时遵循：

## Rule 1

先读本文件，再做架构修改。

## Rule 2

一次只实现一个 Milestone。

不要直接把整个测试工程一次做完。

## Rule 3

不要增加当前实验不需要的 Gameplay System。

## Rule 4

优先使用：

> 最简单、可以回答当前问题的实现方式。

## Rule 5

不要提前实现：

- Save System；
- Menu；
- Progression；
- Card System；
- Inventory；
- 正式 AI；
- 正式 Navigation；
- Procedural World；
- 完整 Production Architecture。

这些都不属于当前 Benchmark。

## Rule 6

性能敏感系统必须可测量。

避免隐藏复杂度。

## Rule 7

不要默认：

> 面数越少性能一定越好。

必须测。

## Rule 8

重大修改后：

- 启动 Godot；
- 检查错误；
- 汇报修改文件；
- 汇报未解决问题。

## Rule 9

当前 Milestone 未经过人工确认，不要自动进入下一个阶段。

---

# 30. Git 工作流

从第一天开始使用 Git。

建议里程碑 Commit：

    M1 - greybox
    M2 - visual quality
    M3 - combat VFX
    M4 - crowd benchmark
    M5 - MultiMesh optimization

不要把 broken state 作为 Milestone commit。

`main` 保持可运行。

---

# 31. 多 AI Agent 分工

如果同时使用 Claude Code 和 Codex：

不要让两个 Agent 无协调地同时修改同一批文件。

建议：

    Primary Agent
        → Implementation

    Secondary Agent
        → Review / Profiling / Optimization

Secondary Agent 可以重点检查：

- SceneTree 是否过重；
- Shader 是否昂贵；
- MultiMesh 是否合理；
- 是否有不必要的 per-frame update；
- Benchmark 方法是否准确；
- 是否存在明显性能陷阱。

---

# 32. 第一项执行任务

**第一项任务只做 Milestone 1。**

不要开始：

- VFX；
- AI 3D；
- Crowd；
- MultiMesh；
- Optimization。

实现：

1. Godot 4.x Project；
2. Mobile Renderer；
3. 约 60×46 m Scene（见 §8）；
4. Fixed High-Angle Camera；
5. Grass / Ground Placeholder；
6. River Placeholder；
7. Bridge Placeholder；
8. River Bank / Cliff；
9. 两个 Building Placeholder；
10. 若干 Rock；
11. 若干 Tree；
12. Player Mech Placeholder；
13. 若干 Enemy Placeholder；
14. DirectionalLight3D；
15. Basic WorldEnvironment。

全部使用 Primitive / Placeholder。

完成后必须：

- 能运行；
- 无 Godot Error；
- 镜头构图基本符合参考图。

**不要继续 Milestone 2，等待人工确认。**

---

# 33. 最终 Go / No-Go 标准

实验只有在以下四项都大体通过后，才说明这条技术路线成立。

## A. Visual

Godot 能产生令人满意的固定镜头 3D 场景。

目标：

    参考图约 70–80%+ 的主观视觉完成度

无需大量手工精雕即可达到。

---

## B. Combat Presentation

Machine Gun、Rocket、Explosion、Smoke、Tesla / Electric 等效果组合后：

> 战场足够热闹、清晰、有商业游戏感。

---

## C. Performance

在代表性低配硬件上：

优先目标：

    500 enemies ≈ 60 FPS+

期望目标：

    1000 enemies ≈ 40–60 FPS+

同时保留合理环境和战斗 VFX。

最终目标可以根据实测调整。

---

## D. Production Pipeline

普通 3D 环境资产可以通过以下组合高效产出：

- Existing Asset；
- Licensed Asset；
- AI Generation；
- Blender；
- Procedural Tool；
- AI-Assisted Coding；
- Godot Import。

流程成熟后，一个普通环境资产的人工 Cleanup 时间理想目标：

    ≤ 30 minutes

---

# 34. Benchmark 结束后的决策方式

如果：

- Visual；
- VFX；
- Performance；
- Asset Pipeline；

都通过：

> Godot 被认为适合正式项目。

正式工程可继承此 Benchmark 得到的架构经验。

如果失败：

先找出失败原因。

可能包括：

- Renderer；
- VFX Ecosystem；
- GPU；
- CPU Crowd Simulation；
- Asset Workflow；
- AI Workflow；
- 开发成本。

不要仅仅因为某一次测试结果不好，就直接得出：

> Godot 不适合。

必须先定位瓶颈。

---

# 35. 核心原则

这个项目的目的就是：

> 用实测替代猜测。

不要优化理论问题。

不要提前开发正式游戏。

构建一个最小但足够代表最终游戏的场景，其中包含：

> Environment + Lighting + Water + Mech + Enemies + Weapons + VFX + Crowd

然后测量：

- 好不好看；
- 跑不跑得动；
- AI 能不能帮忙；
- 资产生产是否高效。

最终由 Benchmark 结果，而不是对某个引擎的主观印象，决定正式技术路线。
