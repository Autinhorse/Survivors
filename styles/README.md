# 美术风格

一个"风格"是一整套外观：调色板、材质、贴图、资产建模。
**布局不属于风格** —— 所有风格共用 `tools/layout.py` 里的同一套构图、机位和物件位置，
这样两个风格的差异是纯粹的美术差异，可以直接并排比较，
`surface_detail.py` / `scene_audit.py` 的取样框也能复用。

## 分层

| 文件 | 归属 | 说明 |
|---|---|---|
| `tools/tscnlib.py` | 共享 | `.tscn` 发射器：资源登记、变换、节点、占位检查 |
| `tools/layout.py` | **共享** | 布局：地形、河道曲线、桥、建筑与散布物的位置 |
| `tools/blenderlib.py` | 共享 | Blender 建模辅助：构件、合并、倒角、UV、顶点色、导出 |
| `tools/gen_scene.py` | 共享 | 驱动：把某风格的材质套进共享布局 |
| `styles/<名字>/materials.py` | 风格 | 填充材质槽位，并给出 `MESH(名字)` 资产路径 |
| `styles/<名字>/assets.py` | 风格 | 该风格的 Blender 资产建模 |
| `styles/<名字>/textures.py` | 风格 | 该风格的程序化贴图（可外部编辑） |
| `styles/<名字>/leaf_atlas.py` | 风格 | 叶片 alpha 图集（如果这个风格用贴片植被） |
| `assets/<名字>/` | 风格 | 该风格的 GLB 和贴图产物 |
| `styles/<名字>/history/` | 风格 | 迭代记录（`tools/snapshot_visual.py` 生成） |

## 新增一个风格

```
mkdir styles/<名字>
cp styles/gatling/materials.py styles/<名字>/materials.py     # 改材质
cp styles/gatling/assets.py    styles/<名字>/assets.py        # 改资产
cp styles/gatling/textures.py  styles/<名字>/textures.py      # 改贴图
```

然后：

```
python styles/<名字>/textures.py
blender --background --factory-startup --python styles/<名字>/assets.py \
    -- --out-dir assets/<名字>/environment
python tools/gen_scene.py --style <名字>          # -> scenes/VisualBenchmark_<名字>.tscn
```

## 材质槽位约定

`materials()` 必须返回一个字典，含以下键（布局代码按这些名字引用，缺一个就 KeyError）：

```
grass / cliff     地形（同一个材质，着色器按坡度分草/土/石）
dirt              路面补丁
water             河面
leafA / leafB     树冠
bush              灌木
tuft              草丛
rock              实体石头（旧路径，仍被少量地方引用）
proprock          石头（三平面 + 岩石贴图）
prop              硬表面道具
prophouse         房屋
propwood          桥
wood / woodlt     木构件
wall / roof       建筑（旧路径）
metal             金属
player / enemy    单位
```

还要提供 `MESH(名字) -> "res://..."`，把资产文件名映射到该风格的资产目录。

## 两条不变量

1. **性能基准场景固定用 `gen_scene.py` 的 `REFERENCE_STYLE` 生成**，不跟随当前风格。
   这样 M4/M5 的数字在换风格之后仍然可比，§11 的目标硬件验证也只需跑一次。
   要测某个风格自身的渲染开销，用视觉场景另测。

2. **资产生成必须是确定的。** 不要用 `hash(str)` 做随机种子 ——
   Python 3 的 `str.__hash__` 每个进程都加随机盐，会让每次导出的资产都不一样，
   "改前/改后"的像素对比就失效了。用 `zlib.crc32(name.encode())`。
