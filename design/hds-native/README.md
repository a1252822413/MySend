# 快传 · HDS 原生方向（Rebuild 04）

## 这一版换的是什么

03 版是"设计一个 App"：自定义配色、自定义 TabBar、自定义卡片。
04 版反过来——**能用系统组件就不自己画**。竞品那个底部胶囊不是画出来的，是鸿蒙 6.1 的 HDS 组件库渲染的。

| | 03 工业仪表 | 04 HDS 原生 |
|---|---|---|
| 底部栏 | 自己拼的 4 个文字卡片 | `HdsTabs` + `barFloatingStyle`，系统渲染悬浮胶囊 |
| 材质 | 无 | `systemMaterialEffect` 沉浸光感（ADAPTIVE） |
| 卡片 | 1px 描边 + 浅阴影 | 无描边，24 圆角，纯色块 |
| 标题 | 21px | 32px，右侧圆形图标按钮 |
| Tab 图标 | 无（只有文字） | `BottomTabBarStyle` + 系统符号 |
| 列表 | 自绘行 | HDS ListItem 结构（40 图标块 + 双行文字 + 右值 + chevron） |

## 胶囊的几何（对应 `barFloatingStyle`）

| 参数 | 值 | 说明 |
|---|---|---|
| `barSideMargin` | 16 | 左右距 |
| `barBottomMargin` | 20 | 离底距离（实机还要叠加安全区） |
| 高度 | 64 | 圆角 32（全圆） |
| 材质 | blur 22 + saturate 1.7 | 对应 `MaterialType.ADAPTIVE` |
| 阴影 | `0 12px 34px` | 悬浮感来源 |
| 选中态 | 图标 2.1 描边 + 品牌绿 | 系统自绘高亮，不需要额外背景块 |

三个必要条件（少一个悬浮就不生效）：`barPosition(End)` + `vertical(false)` + `barOverlap(true)`。

## 六个屏

| # | 屏 | 关键结构 |
|---|---|---|
| 01 | 接收 | 大标题 + 圆形按钮 / 本机卡 / 在线设备（列表卡）/ 最近接收 / 网络 |
| 02 | 发送 | 接收方列表卡（选中态整行浅绿 + 绿对勾）/ 待发文件卡 / 底部 action-bar |
| 03 | 历史 | 独立日志卡 + 类型 tag（接收绿 / 发送灰） |
| 04 | 设置 | 三组列表卡：设备 / 接收 / 安全，每行 40 图标块 + 标题 + 副标题 + 右值 |
| 05 | 接收中 | 进度浮卡压在胶囊上方，速度 30px |
| 06 | 接收确认 | 底部 sheet（28 圆角）盖住胶囊 |

## 令牌

`styles/tokens.css`，亮色是主场景（HDS 默认浅色），暗色对等。

```
亮：bg #F1F3F5 · card #FFFFFF · text #0B0F0E · accent #0B8F5B · tab rgba(255,255,255,.82)
暗：bg #0B0F0E · card #171D1B · text #F2F5F4 · accent #3BE49A · tab rgba(40,48,45,.82)
圆角：card 24 / inner 16 / pill 999
行高：64
```

## 自检

| 关卡 | 结果 |
|---|---|
| 对比度 | 亮 16:1 / 6.8:1 / 4.9:1；暗 15:1 / 6.9:1 / 4.7:1 |
| 触摸目标 | 行 64、按钮 46、圆形按钮 40（外扩热区 44）、开关 44×26 |
| 状态覆盖 | 行 hover、Tab 选中、开关开合、选中设备、空态、sheet、进度 |
| 降级 | `prefers-reduced-motion` 全关 |
| 响应式 | ≥1120 三列 / 更窄换行 / <460 单列 |

## 落地到 ArkUI（代码已实现大半）

| 设计 | ArkUI |
|---|---|
| 胶囊 Tab | `HdsTabs` + `.barFloatingStyle({ barSideMargin, barBottomMargin, systemMaterialEffect })` |
| 系统图标 | `new SymbolGlyphModifier($r('sys.symbol.xxx'))`，注意不是 `$r()` 直接传 |
| 列表卡 | `Column` + `backgroundColor(surface)` + `borderRadius(24)` + `Row` 行 |
| 圆形按钮 | `Stack` + `borderRadius(50%)` + `shadow` |
| 沉浸光感 | `hdsMaterial.MaterialType.ADAPTIVE`，让系统按算力降级 |

> 已踩过的坑：`BottomTabBarStyle` 的图标参数类型是 `SymbolGlyphModifier`；
> `@kit.UIDesignKit` 在 HMS 扩展 SDK（`sdk/default/hms/ets`），需要 API 23+。
