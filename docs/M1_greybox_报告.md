# Milestone 1 — Greybox / 构图验证 · 完成报告

对应需求：`docs/GODOT_3D_可行性验证需求.md` §32（第一项执行任务）
结果截图：`docs/reference/m1_greybox.png`（由 gameplay camera 直接渲染，1886×1061）

---

## 1. 环境

| 项 | 值 |
|---|---|
| Godot | 4.7 stable — `C:\Godot4.7\Godot_v4.7-stable_win64.exe` |
| Renderer | **Forward Mobile**（`renderer/rendering_method="mobile"`，运行时日志已确认） |
| Blender | 5.2（M1 未使用，留给 M2 / AI 3D 阶段） |
| Python | 3.12（仅用于生成场景的脚手架脚本） |

---

## 2. 已实现（§32 的 15 项）

| # | 需求 | 状态 | 说明 |
|---|---|---|---|
| 1 | Godot 4.x Project | ✅ | `project.godot` |
| 2 | Mobile Renderer | ✅ | 启动日志 `Forward Mobile` |
| 3 | 30×30 m 场景 | ⚠️ 改为 **60×46 m** | 见 §5「场景尺寸修正」。地面块 160×160 只为固定镜头不穿帮 |
| 4 | Fixed High-Angle Camera | ✅ | **h=44 m，俯角 60°，FOV 40**（已人工确认） |
| 5 | Grass / Ground | ✅ | CSG 地块 + 土路 / 空地色块 |
| 6 | River | ✅ | CSG 挖出的峡谷（宽 7.5 m）+ 半透明水面 plane，水面 −2.55 m |
| 7 | Bridge | ✅ | 13 m 跨度：桥面 + 桥板 + 4 根桥墩 + 栏杆 + 引桥 + A 形桅杆 + 斜拉索 |
| 8 | River Bank / Cliff | ✅ | 近岸 2.4 m 崖壁；对岸台地高 +2 m（对应参考图右侧高地） |
| 9 | 两栋建筑 | ✅ | 三栋房屋（墙+屋顶+烟囱）+ 一个棚屋 |
| 10 | 若干 Rock | ✅ | 约 100 块，成组分布（左下巨石带 / 崖沿 / 对岸 / 画面外圈） |
| 11 | 若干 Tree | ✅ | 11 棵主景树 + 边缘树丛 |
| 12 | Player Mech Placeholder | ✅ | 场景中心偏下，橙色，约 3.5 m |
| 13 | 若干 Enemy Placeholder | ✅ | 26 个小兵（约 1.6 m）+ 1 个桥上中型敌人 |
| 14 | DirectionalLight3D | ✅ | 暖色主光，阴影投向右下（与参考图一致），启用阴影 |
| 15 | Basic WorldEnvironment | ✅ | 程序天空 + 天空环境光 + ACES tonemap + 轻微 Glow |

全部为 primitive：Box / Sphere / Cylinder / Capsule / Prism / Plane + CSG。
无脚本逻辑、无 Gameplay、无 VFX、无 Navigation、无优化 —— 符合 §32「暂时不要实现」。

---

## 3. 运行与验证

```
# 直接运行（主场景就是 VisualBenchmark）
C:\Godot4.7\Godot_v4.7-stable_win64.exe --path C:\My_Works\Survivors\Survivors

# 从 gameplay camera 截图（不进编辑器，跑完自动退出）
C:\Godot4.7\Godot_v4.7-stable_win64_console.exe --path C:\My_Works\Survivors\Survivors ^
    --resolution 1920x1080 res://tools/Screenshot.tscn -- D:\some\shot.png
```

验证结果：运行与 `--headless --import` 输出中 **无 ERROR / WARNING**。

---

## 4. 文件

```
project.godot                     Mobile renderer，主场景指向 VisualBenchmark
scenes/VisualBenchmark.tscn       M1 灰盒场景（约 780 节点，24 个 sub-resource）
tools/gen_greybox.py              场景生成脚手架（见下方说明）
tools/Screenshot.tscn + .gd       命令行截图工具，用于对比参考图
docs/reference/m1_greybox.png     当前构图截图
```

`scripts/ assets/ shaders/ benchmark/` 按 §26 建好目录（占位 `.gitkeep`）。

### 关于 `tools/gen_greybox.py`

场景是脚本生成的，方便在 M1 阶段快速迭代构图（改一个数字重生成 + 截图，比手拖 500 个节点快得多）。
**它会覆盖 `scenes/VisualBenchmark.tscn`。** 一旦开始在编辑器里手工调整场景，就不要再跑它。

一个踩到的坑（已写进代码注释）：`.tscn` 里的 `Transform3D(...)` 12 个参数是**按行**序列化的，
不是按列 —— 按列写会得到转置矩阵（第一次渲染出来整屏是天空）。

---

## 5. 场景尺寸修正：30×30 → 60×46

需求文档 §8 假定参考图是 30×30 m 的场景。实测这个假定偏小约 1.5 倍。

方法：不猜绝对米数，而是量**物体在画面里的宽度占比**，再和本项目同类物体对比。

| 锚点 | 参考图占画面宽 | 修正前本项目 | 倍数 |
|---|---|---|---|
| 玩家机甲 | ~5.1% | ~7.4% | 1.45× |
| 大房子 | ~13.3% | ~19.6% | 1.47× |
| 小兵 | ~1.7% | ~2.9% | 1.7× |

三个锚点一致 → 参考图的可视地面范围约 **60 m 宽 × 46 m 深**。

关键结论：**物体尺寸本来就是对的**（按 1.5× 换算后房子占比 13.3%，和参考图完全一致）。
错的是相机太近 + 布局堆得太密。所以修正方式是：

- 物体尺寸**不动**（保持 1 unit = 1 m，房子 6.8 m、机甲 3.5 m、小兵 1.6 m）；
- 布局锚点整体摊开约 1.5×（村庄、路环、河道位置、散布物）；
- 相机 30 m → **44 m**（俯角/FOV 不变），可见地面 65.7 m × 44.7 m；
- 补充内容填满放大后的画面：第三栋房子、两段栅栏、第三根电线杆、更多石头/树丛。

**这一条需要回写需求文档 §8 和 §32**（当前文档仍写 30×30 m），否则后续 Agent 会按旧尺寸做。
同时影响 §12 的性能目标语义：500–1000 敌人是分布在 60×46 m 上，不是 30×30 m。

### 其他差异 / 取舍

- **地面块 160×160**：只为固定镜头不穿帮，核心内容仍集中在 60×46 内，之外只放稀疏填充物。
- **水面**：纯半透明材质，没有流动 / 泡沫 / 急流（§18 属于 M2）。
- **材质**：全部纯色 StandardMaterial3D，没有贴图 / 混合 / 装饰草（§M2）。
- **河道走向**：直线 + 固定斜率，参考图是弯的。M2 换成模块化河道时再处理。
- **对岸高地**：参考图右侧是深色岩壁，这里用 +2 m 台地 + 深色切面代替。

---

## 6. 需要人工确认（§29 Rule 9）

请看 `docs/reference/m1_greybox.png` 对比 `docs/target.png`，确认：

1. ~~镜头俯角~~ —— **已定：60° / 44 m / FOV 40**（2026-08-20 人工确认）。
   对比过 55° / 60° / 65° / 70°：俯角越大，建筑立面、桥侧面、峡谷崖壁露出越少，
   3D 体积感递减；60° 是「更俯视」和「侧面细节还在」的平衡点。
   注意俯角与相机高度必须联动，否则场景纵深装不进画面（当前可见纵深 44.7 m）。
2. **场景尺寸**：接受 §5 的 60×46 m 修正吗？接受的话需求文档 §8 / §32 要同步改。
3. **比例**：小兵 1.6 m / 玩家机甲 3.5 m / 房屋 6.8×4.8 m / 桥跨 13 m / 河宽 7.5 m —— 是否合适？
4. **构图**：村庄左上、桥+峡谷右上、河流右侧斜向、巨石带左下、开阔草地居中，
   是否已经算「大致符合参考图」？

### 镜头参数怎么改

镜头是 `tools/gen_greybox.py` 顶部的常量，相机 z 由俯角自动推导（始终对准同一个地面焦点）：

```
python tools/gen_greybox.py --pitch 62 --height 46 --fov 38
```

脚本会打印可见地面宽度和纵深；纵深不够就抬高相机或加大 FOV，两者必须联动。

确认后再进入 **Milestone 2（视觉质量验证）**。M1 阶段不继续往下做。
