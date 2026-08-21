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

> **实测结论（2026-08-21，Milestone 5）**
>
> 三种实现在相同几何（约 150 面/单位）、阴影模式 B 下的对比：
>
> | 数量 | 传统 Node | MultiMesh + CPU 逐部件 Transform | MultiMesh 合并网格 + Shader 动画 |
> |---|---|---|---|
> | 500 | 1.92 ms / 2,622 dc | 1.45 ms / 301 dc | 0.74 ms / 297 dc |
> | 1000 | 4.25 ms / 5,113 dc | 2.60 ms / 301 dc | 0.79 ms / 297 dc |
> | 2000 | 10.64 ms / 10,073 dc | 4.99 ms / 301 dc | 1.02 ms / 297 dc |
>
> **结论：小兵采用「合并网格 + Shader 动画」的 MultiMesh 方案**，
> 2000 单位时比传统 Node 快 10.4 倍，16,000 单位仍有 162 FPS。
> 中型敌人（§4.2）和 Boss（§4.3）继续用传统 Node —— 实测 6.4 µs/单位，
> 30 个中型敌人约 0.2 ms，不值得为它们放弃 Node 的灵活性。
>
> 重要的是收益的来源是**两半**：减少 draw call 只占约 59%，
> 另外 41% 来自把逐单位 Transform 计算搬进 Shader。只换渲染不换动画方式，
> 2000 单位只能从 10.64 ms 降到 4.99 ms。
>
> 适用边界（MultiMesh 无逐实例视锥剔除、一网格一材质、未测碰撞等）
> 详见 `docs/M5_architecture_报告.md` §7。

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

> **实测结论（2026-08-21，Milestone 5）**：这段数学应该跑在**顶点着色器**里，
> 每单位的 `phase` 通过 `INSTANCE_CUSTOM` 传入，CPU 每帧每单位只写一个 Transform。
> 同样的动画放在 CPU 逐部件算，1000 单位的更新循环要 3.16 ms；
> 搬进 Shader 后只剩 0.10 ms（约 32 倍）。
> 参考实现：`shaders/enemy_crowd.gdshader` + `scripts/units/EnemyCrowdMM.gd`。

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

> **宽高比策略（2026-08-21 实测）**
>
> Godot 的 `Camera3D` 默认 `keep_aspect = KEEP_HEIGHT`：垂直 FOV 固定、
> **水平 FOV 随宽高比增长**。对固定机位俯视射击来说这是玩法问题而不只是画面问题：
>
> | 宽高比 | 水平 FOV | 可见地面宽 |
> |---|---|---|
> | 16:9 | 65.8° | 65.7 m |
> | 21:9 | 81.6° | 87.7 m |
> | 32:9 | 104.6° | **131.5 m（16:9 的两倍）** |
>
> 带鱼屏玩家能在两倍远处看见敌人。已加 `scripts/environment/GameplayCameraPolicy.gd`，
> 默认策略 `clamp`：取更受限的那个轴，任何屏幕都不会比基准看得更多。
> 对比图见 `docs/reference/aspect_policy.png`。
>
> 附带说明：**编辑器视口不能用来判断画面**。它默认 FOV 75，
> 视口面板又常是超宽的（3.2:1 时水平 FOV 达 136°），边缘物体会明显外倾成鱼眼。
> 判断视觉一律以 gameplay 相机的截图为准。

> **本 benchmark 的方案：锁定可见范围 + 左右黑边（2026-08-21）**
> （正式项目未必用这个 —— 见本节末尾「半透明遮罩」一节的三个选项对比）
>
> `project.godot`：`stretch/mode="viewport"` + `stretch/aspect="keep"`。
> 实测三种窗口形状（16:9 / 2.37:1 / 1:1）渲染出的世界完全一致
> （平均像素差 1.8，仅来自水面与 VFX 动画）。
>
> 决定因素不是画面而是**玩法**：敌人必须在屏幕外生成。可见范围随分辨率变化的话，
> 要么按屏幕决定生成位置（不同分辨率玩到不同的游戏），
> 要么按最宽屏幕统一生成（窄屏玩家白等敌人走进来）。
> ~~《吸血鬼幸存者》在 21:9 上同样是加黑边。~~
> **更正**：它用的是半透明遮罩，敌人就在遮罩区里生成 —— 见本节末尾的实测记录。
>
> `mode="viewport"` 才能让 3D 一起走拉伸系统（`canvas_items` 只管 2D，
> 3D 仍会铺满窗口）。代价是渲染分辨率固定为基准值再缩放 ——
> 对本项目反而合适（§24 本来就要 Resolution Scale）。
>
> **连带收益：屏幕外生成半径变成固定的世界常量。**
> 由相机参数推导（`tools/gen_greybox.py` 的 `spawn_radius()`）：
>
>     可见地面四角：近边 ±27.2 m @ z=+18.1，远边 ±41.6 m @ z=-26.5
>     决定半径的是**远端的角**（49.4 m），不是画面宽度的一半
>     留 10% 余量 -> 生成半径 54.3 m
>
> 透视让远边比近边宽得多，这一点只有算才知道 —— 凭直觉取"画面宽度一半"
> （32.9 m）会让敌人在画面上半部凭空出现。

正式游戏预计不会依赖自由旋转镜头。

受控镜头本身就是优化和降低资产要求的重要手段。

---


> **补充记录（2026-08-21）：吸血鬼幸存者用的是「半透明遮罩」，不是硬黑边。**
> 参考截图 `docs/reference/vs_side_mask.png`。
>
> 之前这里记的是「两边加黑边」。看过实际游戏过程后更正：它两侧**照常渲染世界和敌人**，
> 只是盖了一层黑色半透明遮罩。**敌人就在遮罩区域里生成**，玩家看得见（只是暗），
> 但注意力集中在自身周围，所以不太在意。
>
> 实测（2560×1080 ultrawide 截图）：
>
> | 项 | 值 |
> |---|---|
> | 画面 | 2560×1080，21:9（2.370） |
> | 明亮区 | x 415–2143，宽 1728 px = 全宽的 **67.5%** |
> | 明亮区宽高比 | 1728 / 1080 = **1.600，正好 16:10** |
> | 两侧亮度 | 约为明亮区的 **0.3 倍**（黑色遮罩 α≈0.65–0.7），三通道比值接近中性 |
> | 边界 | **硬边**，3 像素内跳变，没有渐变 |
> | 遮罩位置 | 固定在屏幕上（居中），**不跟随玩家** |
>
> 这是个折中，不是解法 —— 宽屏玩家仍然能提前看到敌人，只是看得暗。
> 但它解决了真正的约束（见本节生成半径的推导）：
> **屏幕外生成位置不必推到荒谬的远处，也不必按分辨率改生成规则。**
>
> 三个选项，实现时再定：
>
> | | 做法 | 公平性 | 观感 | 对生成半径的影响 |
> |---|---|---|---|---|
> | A | 硬黑边（letterbox / pillarbox） | 完全公平 | 差，浪费屏幕 | 按基准比例算即可 |
> | B | VS 式半透明遮罩 | 有折损（暗处仍可见） | 好 | 必须按**最宽支持比例**算 |
> | C | `clamp`（本 benchmark 当前默认） | 完全公平 | 宽屏上下被裁 | 按基准比例算即可 |
>
> 注意 B 与本节已推导的生成半径是耦合的：现在的 **54.3 m 是按 16:9 的画面四角**
> 算出来的，若支持到 21:9 必须重算，否则宽屏玩家会看见敌人凭空出现。
>
> **一个从这张截图看不出来、实现前必须验证的问题**：VS 的明亮区在不同宽高比下
> **世界宽度是否恒定**。
> 若恒定，B 就等价于「C + 把多出来的部分调暗」，公平性折损只剩「能看见暗处的敌人」；
> 若不恒定，宽屏就是实打实地多看到世界，那 B 的公平性折损比看上去大得多。

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

> **实测结论（2026-08-21，河岸）：CSG 做倒角要用旋转扫掠，叠圆柱做不出来。**
>
> 单个圆柱挖出来的河道是**纯竖直的墙 + 90° 硬棱**，草地和岸壁之间没有过渡，
> 一眼就是被铣刀切出来的槽。
>
> 试过用一圈圈更宽更浅的圆柱做台阶 —— **原理上就不行**：
> 叠圆柱必然在每一级留下一个水平台面。3 级读成梯田，7 级读成灯芯绒，
> 台阶再多也只是把平行条纹变密，不会变成斜面。
>
> 正确的做法是 `CSGPolygon3D` 的**旋转扫掠**（`mode=1`，2D 剖面绕 Y 轴转一圈）：
> 剖面本身是斜的，转出来就是连续斜面，没有台阶可言。
> 剖面里做了**两处外扩**，因为两岸标高不同（近岸 y=0、远岸高台 y=+2），
> 一处外扩只能照顾一岸。
>
> 分工：水线轮廓仍由步长 0.9 m 的圆柱挖槽决定（细节不能丢），
> 岸口是又宽又软的特征，扫掠用 2.0 m 步长就够。
>
> 另外，**河岸立面主要靠贴图，不是靠堆石头**。参考图确实有明显的单块石头，
> 但大部分立面是石质纹理。立面纹理用**元胞噪声**（`noise_type=2`,
> `cellular_return_type=4`）而不是值噪声 —— 值噪声只有各向同性斑点，
> 出不来"一块块石头"的读法。散布的石头相应减了约四成。
>
> 岸壁细节度（判据见 §20）：改前 6.5% -> 20.2% -> **16.9%**，目标 16.9%。
> 帧时 1.093 -> 1.107 ms，三角形 167k -> 194k（倒角本身的地形面数）。

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

> **实测结论（2026-08-21，表面细节）：这个风格不需要手绘贴图，
> 但需要「世界坐标程序化纹理 + 在着色器里算法线扰动」。**
>
> 判据用的是**同一块平面内部、去掉光照低频之后的亮度起伏**
> （9 像素均值滤波取高频，std / 均值）。这个量能区分"有材质"和"一块色板"，
> 而整体 std 不能 —— 后者主要反映光照梯度。
>
> | 表面 | target | 改前 | 改后 |
> |---|---|---|---|
> | 屋顶 | 14.6% | 12.2% | 15.3% |
> | 墙面 | 18.9% | 13.6% | 15.3% |
> | 河岸岩壁 | 16.9% | **6.5%** | 20.2% |
> | 木桥面 | 9.2% | 15.6% | 15.6% ※ |
>
> ※ 桥面这一格取样区里有板缝和阴影等真实几何，测的不全是表面细节，参考价值低。
>
> **三条踩过的坑，每条都会让人得出错误结论：**
>
> 1. **StandardMaterial3D 的法线贴图在程序化网格上会静默失效。**
>    `rocks_lp.glb` / `pebbles.glb` 没有 UV（`bmesh.ops.convex_hull` 不产生 UV），
>    Godot 没 UV 就生成不了切线，法线贴图既不报错也不生效。
> 2. **`NoiseTexture2D.bump_strength` 默认是 8，别往下调。**
>    这里填过 1.4–2.4，结果把 `normal_scale` 从 0.8 拉到 8.0（10 倍）画面纹丝不动，
>    一度误判成"渲染路径不支持"。用普通灰度噪声当法线图做对照实验才定位到根因。
> 3. **纹理尺度必须按屏幕像素反算，不能凭感觉填。**
>    `detail_noise` 频率 0.035、256 texel，特征波长 = 0.1117 / scale 米；
>    游戏机位 29 px/m，屏幕特征 ≈ 3.24 / scale 像素。
>    填过 scale = 2.2（1.5 px），纹理度反而掉回改前水平 —— 全被抗锯齿平均掉了。
>    这个机位下**特征要落在 4–7 像素**，对应 scale 0.5–0.8。
>
> **另一个和贴图无关、但影响更大的发现**：房屋是 GLB 实例、没有 `material_override`，
> 生成器里那套 `MAT["wall"]` / `MAT["roof"]` 对它们**根本没生效**，
> 屋顶墙面一直用的是 Blender 里的纯色材质。
> 修法和植被同一套：**把 8 个材质槽的颜色烘进顶点色 + 合并成单一材质**，
> Godot 侧整体挂 `shaders/prop.gdshader`。
> 顺带把每栋房子从 8 次 draw call 降到 1 次。
>
> **结论：正式项目要不要做手绘贴图？**
> 在这个机位（29 px/m）和这个低多边形风格下，**大面积表面不需要**：
> 世界坐标程序化噪声 + 着色器法线扰动已经能打到目标水平，
> 而且不需要 UV 展开、不占显存、对程序化生成的网格天然适用。
> **真正需要贴图的是有"结构"的东西** —— 屋顶瓦片的排列、木板的走向、石墙的砌缝。
> 值噪声只有各向同性的斑点，做不出方向性和重复结构。
> 那属于 §21 点名的管线缺口（UV / 展开 / 烘焙），要单独立项。
>
> 开销：帧时 1.153 -> 1.093 ms（**反而降了**，因为房屋 draw call 从 8 降到 1，
> 抵消了着色器多出的几次取样）。

> **实测结论（2026-08-21，植被）：树木和灌木必须是「细枝干 + alpha 贴片叶子」，
> 不能用实体几何。**
>
> 这条走了三版才对，值得写下来，因为前两版的失败是**原理性的**、不是调参没调好：
>
> | 版本 | 做法 | 结果 |
> |---|---|---|
> | 1 | 缩放的光滑球体 | 轮廓是连续曲线，一眼假 |
> | 2 | 凸包叶簇堆积（实心核 + 外圈） | 轮廓碎了，但仍然是"一坨"——**实体不透光** |
> | 3 | 细枝干（真几何）+ 叶片贴片（alpha 裁剪） | 对了 |
>
> 关键在于 target.png 的树冠**中间是透光的**，能看见底下的地面和影子。
> 只要叶子是实体，这件事就做不到，和面数、平滑角、颜色都无关。
>
> 具体决定：
>
> - **alpha 裁剪，不是 alpha 混合。** 裁剪走不透明通道：不需要按距离排序、
>   阴影自动正确、没有透明层的填充开销。§15 点名的 overdraw 风险主要来自混合。
> - **一张灰度叶片图集 + 顶点色着色。** 图集的 RGB 存叶片自身的明暗、alpha 存形状，
>   颜色来自顶点色，所以一张 1024² 的图集长出了深绿/黄绿/红褐/紫花全部变体。
> - **木头和叶片合并成一个网格**（一个 surface = 一次 draw call），
>   靠**顶点色的 alpha** 区分：1 = 采样图集做裁剪，0 = 实体木头强制不透明。
> - 面数反而降了：实体叶簇版每棵树约 950 面，贴片版约 630 面。
>
> **代价（本机 RTX 5080 Laptop，1600×900，同一场景同一相机，各 3 次 180 帧）：**
>
> | | 三角形 | 帧时 |
> |---|---|---|
> | 实体叶簇 | 176k | 1.033–1.056 ms |
> | 细枝 + 贴片 | 166k | 1.153 ms（±0.001） |
>
> **三角形少了 6%，帧时反而涨了约 11%。** 这正是 §12 规则 7 说的那件事 ——
> 成本转移到了填充率：alpha 裁剪让 early-Z 失效，而树冠上的贴片是层层重叠的。
> 按 §11，**集显上这个比例很可能明显更大**（集显是填充率受限的），
> 目标硬件验证时这一项要单独测，必要时按距离降低贴片数量（LOD）。

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
