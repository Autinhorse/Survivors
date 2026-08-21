# 风格 hellrider

参考：`reference/`（Hellrider, BoomBit）。极简平面着色低多边形。

```
python styles/hellrider/assets.py                      # 需在 Blender 里跑，见下
blender --background --factory-startup --python styles/hellrider/assets.py \
    -- --out-dir assets/hellrider/environment
python tools/gen_scene.py --style hellrider            # -> scenes/VisualBenchmark_hellrider.tscn
```

## 和 gatling 的关系：方法几乎处处相反

| | gatling | hellrider |
|---|---|---|
| 石头 | 凸包 22–26 点，倒角，按角度平滑 | 凸包 8–10 点，**不倒角、不平滑** |
| 表面 | UV + 方向性贴图 + 三平面 + 法线扰动 | **没有 UV、没有贴图、没有法线扰动** |
| 植被 | 细枝干 + alpha 贴片叶子 | **实体低面球** |
| 直边 | 拆成一件件去破掉 | **直边就是风格本身，保留** |
| 光照 | 夕阳天光 + 深度雾 + 饱和度微调 | 分档着色，**不开雾、不开 glow** |
| 布局 | 蜿蜒河道 + 曲线路网 | **笔直河道 + 轴向方形场地** |
| 材质数 | 17 | **5** |
| 每栋房子 | 约 3900 面 | **80 面** |

所以两个风格**不共用布局**（`layout.py` 各有一份）。共用的是
`tools/tscnlib.py` / `tools/blenderlib.py` / `tools/gen_scene.py` 和全部测量工具。

## 验收指标（`python tools/scene_audit.py`）

参考图之间本身有跨度（褐色区和水/冰区差别不小），所以判据是
**落在两张参考图之间**，而不是对齐某一张：

| 指标 | 水/冰参考 | 褐色参考 | 当前 |
|---|---|---|---|
| p90/p10 | 2.49 | 1.55 | 1.90 |
| 平均饱和度 | 0.71 | 0.59 | 0.69 |
| 亮于 170 % | 5.0 | 1.4 | 4.3 |
| 块内 std 中位 | 4.5 | 5.5 | 5.3 |
| 安静块 % | 70 | 61 | 56 |

只有"安静块"还偏低（画面偏满），下一步要减散布、留更大的空地。

作为对照，gatling 风格同一套指标是 std 中位 **18.7**、安静块 **4%** ——
这两个数字最能说明两种风格根本不在同一个régime 上。

## 三条不能破的规则

1. **不许有贴图和法线扰动。** 一旦加上，纯色块的读法立刻消失。
   gatling 那一整套（§3 的世界坐标程序化、三平面、法线扰动）在这里全部关掉。
2. **明暗必须分档。** `hr_flat` / `hr_ground` 的 `light_steps` 把 N·L 量化。
   连续的 Lambert 会让画面"软"下来，风格就散了。
3. **不开 glow、不开雾。** bloom 会给纯色块镶光晕，白色小兵直接变成发光的团。

## 已知待办

- 疏密：安静块 56%，参考 61–70%。散布还要再减。
- 地面的土路（`hr_ground` 已留 `path_mask` 接口，还没做遮罩图）。
- 参考图里有踩出来的拖痕、小草丛、更大的地形色块分区（不同区域不同底色）。
- 单位（玩家/敌人）现在是临时的方块，只为尺度参照。
