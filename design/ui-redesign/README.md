# 快传 · 界面重构 02（工业仪表方向）

## 定调

| 项 | 决策 |
|---|---|
| 目的 | 局域网文件传输 App「快传」的全量界面重设计；解决「传得快不快、对端是谁、文件落在哪」三件事看不清的问题 |
| 受众 | 会用局域网传大文件的普通用户 + 开发者本人（关心速度、指纹、路径这类硬数据） |
| 调性 | **工业实用 Industrial** —— 仪表盘密度、等宽数字、发丝边框、状态色体系。只选这一个方向，不混搭 |
| 展示字 | JetBrains Mono（所有数字、标签、路径） |
| 正文字 | Noto Sans SC（900 做中文标题，负字距 -0.03em） |
| 主色 | `#3BE49A` 信号绿，**只给在线 / 接收 / 主操作**，面积 ≤ 10% |
| 记忆点 | 接收时的同心波束 + 48px 速度读数 —— 像示波器，不像进度条 |

## 为什么是这个方向

传输工具本质是一块仪表：链路的速率、延迟、加密状态、落盘位置，都是读数。
所以界面里没有「大圆角白卡 + 彩色图标」那一套：

- **层级靠发丝线，不靠阴影**。设备列表、文件列表、设置项一律 1px 分隔线，行高 48/52/60。
- **数字全部等宽**。IP、端口、指纹、大小、速度用 `tabular-nums`，滚动时不会跳字。
- **强调色克制**。整屏只有「在线点」「进度条」「主按钮」是绿的，其余全是灰阶。
- **不用胶囊/圆点做选中**。Tab 选中是顶边 2px 短线，开关是 3px 圆角矩形滑块 —— 都是仪表元件的形状。

## 六个屏

| # | 屏幕 | 关键设计 |
|---|---|---|
| 01 | 接收 | 本机铭牌（大字号设备名 + 等宽 IP + 指纹）+ 同心信号环 + 在线设备行 |
| 02 | 发送 | 目标设备大字 + 待发文件行 + 底部「总大小 / 发送」条 |
| 03 | 接收确认 | 底部上滑面板；拒绝描边、接收实心绿；120 秒倒计时 |
| 04 | 传输中 | 同心波束 + 48px 速度 + 2px 进度线 + 落盘路径 |
| 05 | 历史 | 时间轴（竖线 + 节点），接收实心 / 发送空心，动作按钮在条目内 |
| 06 | 设置 | 分组行式；路径用终端风格 path-box；开关为矩形滑块 |

## 令牌（CSS 变量）

`styles/tokens.css` 是唯一色值来源，组件内不写死颜色。

```
--bg #0A0D0C    --surface #101614   --surface-2 #151D1A
--text #E9F1EE  --text-dim #9AA8A3  --text-mute #78877F
--accent #3BE49A   --line rgba(233,241,238,.08)
--fs-hero 30  --fs-display 48  --fs-body 14  --fs-label 11
--sp 4/8/12/16/24/32/48   --r 2/8/14
--dur 160/320/640  --ease cubic-bezier(.16,1,.3,1)
```

## 动效

- 入场：`IntersectionObserver` 触发，同批元素错峰 80ms，只动 `opacity` + `translateY(22px)`。
- 持续动效：仅两处 —— 信号环脉冲、波束脉冲，都是 `transform: scale`，不触发布局。
- 悬停：设备行左侧 2px 绿线从中间长出（而不是整行变亮）；手机壳上浮 6px。
- 降级：`prefers-reduced-motion: reduce` 下全部关闭，入场直接显示。

## 自检

| 关卡 | 结果 |
|---|---|
| 无禁用展示字（Inter/Roboto/Arial/system-ui） | 通过，JetBrains Mono + Noto Sans SC |
| 无白底紫渐变 / 平均分配配色 | 通过，深底 + 单一强调色 |
| 对比度 | 正文 15:1 / 次要 6.9:1 / 微型标签 4.6:1 |
| 触摸目标 | 按钮 44px，行 48px+，开关 40×22（外覆 44 高点击区） |
| 焦点可见 | `:focus-visible` 2px 绿描边 + 2px 偏移 |
| 状态覆盖 | 设备行 hover/选中、Tab 选中、开关开/关、空态、进度、弹层 |
| 动效降级 | 已在 CSS 与 JS 双向关闭 |
| 响应式 | ≥1120 三列 / 三列以下自动换行 / <460 单列 |

## 运行

直接双击 `index.html`，或：

```bash
npx serve design/ui-redesign
```

字体走 Google Fonts，离线时自动回退到 JetBrains Mono → 系统等宽、Noto Sans SC → HarmonyOS Sans / 苹方。

## 落地到 ArkUI 的映射

| Web | ArkUI |
|---|---|
| CSS 变量 | `common/Theme.ets` 里的常量（或 `$r('app.color.*')`） |
| `.phone` 阴影/描边 | `.border({ width: 1, color })` + `.shadow({ radius, color })` |
| 入场 `translateY` | `animateTo` + `@State appeared: boolean` |
| `backdrop-filter` | 半透明背景色（ArkUI 模糊成本高，建议直接 rgba） |
| 波束脉冲 | `Stack` + 三个 `Circle`，用 `animateTo` 改 `scale`/`opacity` 循环 |
| 等宽数字 | 系统字体无 mono，用 `fontFamily('HarmonyOS Sans')` + 固定宽度容器对齐 |

> 说明：ArkUI 字体只有系统字族，`JetBrains Mono` 的等宽效果需要用「固定宽度列 + 右对齐」近似，
> 数字部分可以内嵌一个 woff2（约 40KB）换取仪表感，这是本设计里最值得的那份体积。
