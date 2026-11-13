# 快传 · 双端统一设计 v1.3

PC 用 **WinUI 3（XAML + C#）**，手机用 **ArkUI（ArkTS）**，共用一套设计令牌与一套信息架构。
本目录只做设计与可预览稿，**未修改 PcDemo / HmSend 任何源码**；HTML 只是评审载体，不是实现方案。

| 文件 | 作用 |
|---|---|
| `index.html` + `styles.css` + `app.js` | 双端并排评审板：浅/深主题、5 页、8 种弹窗、4 态顶部提醒 |
| `tokens.css` / `tokens.json` | 唯一视觉源 + 带三端映射的机器可读副本 |
| `handoff/DesignTokens.xaml` | WinUI 3 资源字典（Light/Dark 双字典 + 尺寸/字阶/材质画刷） |
| `handoff/Theme.ets` | ArkTS `ThemeTokens`（保留原 API，新增尺寸/间距常量） |
| `check.py` | 自检脚本（66 项） |
| `preview-*.png` | 真实浏览器渲染截图 |

键盘：`1–7` 切页（7 = 提醒）、`T` 主题、`M` 循环系统材质（仅预览）。URL 参数：`?theme=dark&material=acrylic&view=pc&page=toasts&toast=send-fail&scroll=bottom`。

---

## 一、v1.3：进度弹窗里看得见每个文件

**问题**：v1.2 的进度弹窗只给一根总进度条 + 当前文件名。PC 发送侧虽列了 2 个文件，但只有「完成 / 传输中」文字标签，没有逐文件进度条；PC 接收侧与手机两个浮层**连文件列表都没有**。多文件传输时完全看不出「传了几个、各到哪了」。

**新组件 `FileProgressList`**：4 个进度容器（PC ContentDialog × 2、ArkUI bindSheet × 2）使用同一套 DOM 与同一套状态语义。

| 层 | 内容 | 口径 |
|---|---|---|
| `prog-summary` 总进度 | 大百分比 + 总条 + 已完成 N/M + 速度/剩余 + 已传字节/总字节 | **按字节**：`已传字节 / 总字节` |
| `prog-files` 文件进度 | 标题 + 计数 + 队列说明 + 可滚动 `fp-list` | **每个文件各自百分比** |

每个 `fp-row` 固定包含：状态图标、类型图标、文件名、大小、状态标签、**一条独立进度条**、`role="progressbar"` + `aria-valuenow`；当前文件额外一行「已传/总量 · 速度 · 剩余时间」。

| 状态 | 视觉 | 含义 |
|---|---|---|
| `is-done` | 绿勾 + 100% 实条 + `chip.success` | 已完成 / 已校验 |
| `is-active` | `--accent-soft` 行底 + 4px 左竖条 + 实心按钮色图标 + 动态条 | 正在传输，带字节明细 |
| `is-wait` | 灰图标 + **空心描边轨道** + 0% | 队列中未开始，深色下也能看见「这有一条 0% 的进度条」 |
| `is-fail` | 预留：`--danger` 图标 + 停在原位的条 + 重试 | 单文件失败不影响其余文件 |

- **两层口径不混淆**：总进度按字节加权，单文件是各自百分比，标题分别写「总进度」「文件进度」。示例：接收场景总进度 18%、当前文件 72%、第三个文件 0%，三个数字各有含义且自洽。
- **多文件不撑破弹窗**：`fp-list` 独立 `max-height` + `overflow-y:auto`，文件再多也只滚列表，总进度区与底部操作保持固定。
- **手机端**：同一 DOM，隐藏大小列、大数字降到 22、状态标签缩写为纯百分比；标题补「第 N / M 个」，避免与下方大百分比重复。
- **数据口径统一**：示例统一 3 个文件 / 18.6 MB（与接收请求、传输详情一致），不再出现「2 个文件已完成却显示总进度 72%」的矛盾。
- **无障碍**：16 个进度条全部带 `role="progressbar"` 与 `aria-valuenow/min/max`；状态同时有文字标签，不只靠颜色。

> 发送页的文件卡原本就带逐条进度条，这次补齐的是**弹窗层**；两端实现时复用同一个进度数据源，避免页面与弹窗数值不同步。

---

## 二、v1.2 回顾

### 1. 设置项收敛：只留主题，材质与动画交给系统

上一稿在「外观」里放了窗口材质与减少动效两个开关，是错的——它们不是产品能力，而是系统状态：

| 项 | 之前 | 现在 |
|---|---|---|
| 主题 | 跟随系统 / 浅色 / 深色 | **保留**，双端同名同三选 |
| 界面材质 | 云母 / 亚克力 / 不透明 | **移除**。PC 由系统 `Mica`/`Acrylic` 与省电、高对比度状态决定；鸿蒙由系统模糊策略决定 |
| 减少动效 | 开关 | **移除**。读系统无障碍开关（WinUI `UISettings.AnimationsEnabled`、ArkUI 系统设置），应用不提供入口 |

评审板顶部仍保留「系统材质」按钮，标注 `*`，**只用于预览系统差异，不对应任何设置项**。

### 2. 顶部悬浮提醒（4 态）

之前只有接收页里一张「已接收」卡片，发送成功/失败、接收失败都没有。现在统一为顶部悬浮提醒层：

| 状态 | 标题 | 副文本 | 动作 |
|---|---|---|---|
| `receive-ok` | 已接收 3 个文件 | 18.6 MB · 保存到 下载\快传 | 打开文件夹 / 查看历史 |
| `receive-fail` | 接收失败 | 存储空间不足，3 个文件未保存 | 重试 / 查看详情 |
| `send-ok` | 已发送到 HUAWEI Mate 70 | 2 个文件 · 3.6 MB · 用时 4.2 秒 | 查看详情 / 再次发送 |
| `send-fail` | 发送失败 | Office-PC 拒绝接收 · 已自动重试 2 次 | 重试 / 查看详情 |

- **位置**：PC 悬浮在内容区顶部右侧（桌面通知习惯，不遮页面标题）；手机悬浮在状态栏下方通栏。
- **层级**：`z-index` 低于弹窗，弹窗打开时提醒隐藏；不占布局，纯覆盖。
- **形态**：卡片 12 圆角 + `--shadow-dialog` + 1px 描边；成功用 `--accent-soft` 图标底 + `--accent-ink`，失败用 `--danger-soft` + `--danger`；底部 2px 计时线表示自动消失。
- **无障碍**：成功 `role="status"`、失败 `role="alert"`，容器 `aria-live="polite"`；关闭按钮有可读 label。
- **移动端差异**：两行紧凑形态（标题 + 副文本），不摆按钮行——整条可点进入对应结果页，避免遮挡首屏设备卡。
- 页内原来的「已接收」完成卡已删除，避免与提醒重复；文件位置入口由提醒与历史页承担。

### 3. 平台边界写清楚

| | PC | 手机 |
|---|---|---|
| UI 框架 | WinUI 3（`Microsoft.UI.Xaml`） | ArkUI（ArkTS 声明式） |
| 窗口/页面材质 | `Window.SystemBackdrop = MicaBackdrop / DesktopAcrylicBackdrop` | `backgroundBlurStyle(BlurStyle.COMPONENT_THICK/REGULAR)` + `backdropBlur` + `expandSafeArea` |
| 提醒实现 | 内容区顶部 `Grid` 叠层 + `DispatcherQueue` 计时收起 | 状态栏下 `Stack` 叠层 + `animateTo` 入场，`setTimeout` 收起 |
| 设置存储 | `settings.json`（AppData） | `preferences`（`kuai_settings`） |

两端只共享**令牌与信息架构**，不共享组件代码。材质模糊半径在 PC 由系统给，不要照抄 CSS 的 48px。

---

## 三、统一令牌（关键项）

| 维度 | 值 |
|---|---|
| 品牌 | `#16A34A`（暗色提亮派生 `#3BE49A`） |
| 三级绿 | `accent` 图形 `#16A34A` / `accentFill` 实心按钮 `#15803D`（白字 5.02:1）/ `accentInk` 绿色小字 `#0F7A3C` |
| 状态色 | `--danger` 亮 `#C0392B` / 暗 `#FF6B5A`，配 `--danger-soft` 图标底 |
| 间距 | `0/4/8/12/16/24/32`；语义 Page24 · Section16 · Block12 · Card16 · CardCompact12 · Control8 · Micro4 |
| 圆角 | 卡 12 / 控件 8 / 行 10 / 窗口 8 / 胶囊全圆 |
| 字阶 | 22 / 15 / 13 / 12 / 11（大数字 30） |
| 尺寸 | 控件高 36 · 触控 44 · 图标块 40 · 头像 56 |
| 动效 | 160ms / 300ms，`cubic-bezier(.16,1,.3,1)`，系统关动画时归零 |
| 阴影 | 卡片 `0 1px 1px/.02 + 0 1px 2px/.025`；弹窗与提醒用 `--shadow-dialog` |

硬规则：`accent` 只用于卡片内图形与大色块；**页面底上的绿色文字/图标/在线点一律 `accentInk`**（亮色 `accent` on `bg` 只有 2.95:1，不达 AA）。

材质对比度红线：卡片透明度固定 ≥ 0.90、面板 ≥ 0.58、内容区 0.62–0.72，保证文字仍落在接近 `--surface` 的底色上。

---

## 四、页面与弹窗

双端各 5 页：接收、发送、历史、设备管理、设置。

- **设备管理**：白名单/黑名单统计、从已发现设备加入、粘贴指纹加入、信任列表（已信任标记 + 逐设备自动接收 + 重命名 + 移除）、已阻止列表。「白名单 = 信任设备」，黑名单在 HTTP 层直接 403。
- **设置**：设备身份、连接与安全、系统、网络与防火墙、**外观（仅主题三选）**、关于（手机）。
- **弹窗 8 种**：接收请求、PIN、发送进度、接收进度、发送文字、传输详情、重命名、清空确认。PC 用 ContentDialog（L/S），鸿蒙用半模态 `bindSheet` 与 `AlertDialog`。

---

## 五、落地顺序（建议）

| 阶段 | 内容 | 验证 |
|---|---|---|
| 1 | 合并 `handoff/DesignTokens.xaml`，`App.xaml` 追加字典 | `dotnet build`，浅/深各截一图 |
| 2 | PC 接 `SystemBackdrop`（**不加设置项**，仅跟随系统与省电状态）+ `ExtendsContentIntoTitleBar` | Win11/Win10 各验一次；开高对比度验降级 |
| 3 | PC 加顶部提醒组件（4 态）+ 设备管理页 + PIN/清空弹窗 | 发送成功/失败、接收成功/失败各触发一次 |
| 4 | 替换 `handoff/Theme.ets`，`Index.ets` 硬编码间距/字号收敛到常量 | `hvigorw assembleHap`；grep 剩余字面量 |
| 5 | 鸿蒙加 `backgroundBlurStyle` + 沉浸式，拆 8 个浮层与提醒组件 | Mate 70 真机看模糊与降级，hdc 截图比对 |

## 六、验证记录

- `python design/unified/check.py` → **66 项全绿**：资源引用、token 三端覆盖、XAML 双主题键成对、系统材质 3 档 × 2 主题、双端 5 页语义一致、8 种弹窗双端各一套、提醒 4 态双端各一套且为 absolute 悬浮层、**4 个进度容器各 3 个文件 / 8 条进度条、16 个 aria-valuenow、三态齐备、列表可滚动不隐藏、总进度按字节口径**、设置页无材质/动效开关、样式零颜色/间距字面量、阴影数值未超标、PcDemo Views 间距 0 处违规、WCAG 复算。
- `node --check app.js` 通过。
- Edge 无头渲染并逐张核对：发送进度（浅/双端）、接收进度（深/双端）、PC 弹窗放大图。修掉：手机浮层标题与下方大百分比重复（改「第 N / M 个」）、深色下等待文件 0% 轨道不可辨（改空心描边轨道）。
- 历史修复：PC 提醒遮挡页面标题（改右上角）、手机提醒按钮行压掉设备名（改两行紧凑态）、失败副文本单字换行、设置页长标签折行。

## 七、PC 端源码落地记录（阶段 1–3）

本轮按 v1.3 重构 `PcDemo/PcDemo`，设计稿与工程源码分离的状态结束，工程内以 `Styles/DesignTokens.xaml` 为唯一视觉源。

| 项 | 落地内容 |
|---|---|
| 令牌 | 新建 `Styles/DesignTokens.xaml`（Light/Dark 成对语义色 + 间距/圆角/字阶/尺寸 + keyed 样式），`App.xaml` 只合并 `XamlControlsResources` 与该字典 |
| 材质 | `ThemeApplier` 统一 `MicaBackdrop`；深浅主题不再人工切换 Acrylic；材质与动效跟随系统，**设置页只保留主题三选** |
| 外壳 | `ShellWindow` 导航改为 接收 / 发送 / 历史记录 / 设备管理，设置进 Footer；PaneFooter 显示「后台接收中」 |
| 提醒 | 删 `CenteredToast`（全屏遮罩），新增 `TopToast` 右上角非模态提醒；`TransferResultMessage` 驱动接收/发送 × 成功/失败 4 态，含动作按钮与计时线；`NavigateToPageMessage` 供「查看历史」跳转 |
| 进度 | 新增 `FileProgressRow`；发送/接收进度弹窗重写为「按字节总进度 + 逐文件独立进度条 + 可滚动列表」，等待态用空心轨道，失败态用危险色 |
| 弹窗 | 新增 `ClearHistoryDialog`（危险色主按钮 + 警示条 + 默认焦点在取消），替换原内联 `ContentDialog`；其余 6 个对话框全部 token 化 |
| 页面 | 5 个页面统一标题/副标题、语义文字画刷（不再用 `Opacity` 灰化）、4 倍数刻度 |

加固项（针对无法编译验证的补偿）：
- 统计条原本 `x:Bind ViewModel.Whitelist.Count` —— `ObservableCollection` 的 `INotifyPropertyChanged` 是显式接口实现，WinUI 3 对该路径的刷新不可靠，改为 VM 上 `WhitelistCount` / `BlacklistCount` 强类型属性。
- 「仅白名单模式」未开启时原显示绿色 chip（语义错误），改为开/关两态互斥：已开启用 `BrandSuccessSoftBrush`，未开启用中性 `ChipFillBrush`。
- 新增 `BrandDangerOnBrush` 双主题画刷与 `DangerButtonStyle`，保证破坏性按钮在浅/深主题都达 WCAG AA。

验证：`python design/unified/check_pc.py` → **48 项全绿**（含 x:Class ↔ codebehind 配对、资源键闭合、x:Name/事件契约、刻度、提醒 4 态、逐文件进度、统计条绑定可靠性、破坏性弹窗）。`check.py` 仍为 66 项全绿。

**限制**：本机只有 .NET runtime、无 .NET SDK，未执行 `dotnet build`；XAML 编译期问题（`x:Bind` 路径、资源 `Source` 解析、`ThemeResource` 解析）需在有 Visual Studio 的环境确认，并补真实 WinUI 浅/深主题截图。

**已知设计差异**：评审板的 `pin` 弹窗描述「对端要求配对码 → 输入 → 重试」。PC 端当前 PIN 是发送前在 `SendPage` / `SettingsPage` 内联填写，`SendSessionManager` 的 `prepare-upload` 失败只归为 `Rejected`（「对方拒绝了所有文件」），没有 PIN 错误码识别与重试点，因此该弹窗在 PC 端暂无触发场景；**没有新建无调用点的死控件**。若需落地，应先在协议层区分 PIN 错误并支持重试。另：`SendPage` 的 PIN 上限是 6 位，而设计稿 D4 按 4 位绘制，需一并确认。

鸿蒙端源码本轮未改动（用户要求「先」完成 PC）。

---

## 八、待拍板

| # | 决策 | 建议 |
|---|---|---|
| D1 | PC 暗色强调色是否统一为 `#3BE49A` | 已按建议落地（Light 三级绿 / Dark `#3BE49A`） |
| D2 | 鸿蒙是否放弃 HDS 原生胶囊/24 圆角，严格对齐 12/8/10 | 放弃，仅保留系统模糊与手势 |
| D3 | 提醒自动收起时长 | 已落地：成功 4s、失败 8s，悬停暂停 |
| D4 | PIN 位数：设计稿 4 位，`SendPage` 实为 6 位 | 需确认统一口径后再改评审板格子数或源码上限 |
| D5 | 是否现在拆 `Index.ets`（3338 行） | 放到阶段 4 之后，先做视觉收敛 |
| D6 | PC 是否补 `pin` 弹窗 | 建议先在协议层补 PIN 失败识别与重试，再落弹窗；否则保持内联 PIN 输入 |
