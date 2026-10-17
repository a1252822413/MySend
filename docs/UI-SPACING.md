# UI 间距规范

> 适用：`PcDemo/PcDemo/Views/*.xaml`
> 目标：整页的纵向节奏、左右对齐、内外边距只有一套数值，不再出现 14 / 18 / 22 这类"随手值"。

## 1. 刻度

**只允许 4 的倍数**：`0 / 4 / 8 / 12 / 16 / 24 / 32`。

没有 6、10、14、18、20、22 —— 这些值一律视为错误。

## 2. 语义令牌

| 令牌 | 值 | 用在哪 |
|---|---|---|
| **Page** | 24 | 页面四边内边距（`Grid Padding="24"` / `ScrollViewer Padding="24"`） |
| **Section** | 16 | 页面大区块之间：标题区 → 内容区 → 底部动作条 |
| **Block** | 12 | 同一区块内的元素之间：标签 → 卡片、工具条 → 列表、卡片 → 卡片 |
| **Card** | 16 | 常规卡片内边距（设置分区卡、摘要卡） |
| **CardCompact** | 12 或 12,8 | 紧凑卡片：列表行、状态条、设备磁贴 |
| **Control** | 8 | 控件之间：按钮并排、chip 之间、图标与文字 |
| **Micro** | 4 | 徽标内部、进度条与文字、标题与副标题 |

## 3. 控件尺寸与内边距

| 控件 | 尺寸 | Padding |
|---|---|---|
| 主/次按钮（工具条、动作条） | `Height="36"` | `12,0`（主 CTA 可 `24,0`） |
| 小按钮（行内操作） | 不设高度 | `12,4` 或 `8,4` |
| Chip / 徽标 | 不设高度 | `8,2` |
| 输入框 | `Height="36"` | `12,8` |
| 圆形图标按钮 | `Width/Height=36~40` | `0` |

圆角沿用现有约定：卡片 12、chip 8~10、按钮 8、行 10。

## 4. 各页面落地情况

| 页面 | Page | Section 间距 | 卡片内边距 |
|---|---|---|---|
| SendPage | 24 | 标题→设备区 16、设备区→文件区 16 | 列表容器 8（行 12,8）、动作条 16,12 |
| ReceivePage | 24 | 身份卡→设备区 16、设备区→底部提示 12 | 身份卡 16、设备磁贴 12 |
| HistoryPage | 24 | 标题→筛选 16、筛选→列表 16 | 列表项 16,12 |
| SettingsPage | 24 | 卡片之间 16（`StackPanel Spacing`） | 16 |
| DeviceListPage | 24 | 卡片之间 16 | 16（空态卡 24,16） |

**关于 SendPage 的列表容器**：外层 `Margin="0,12,0,0"`（Block）+ 内边距 8，所以它到工具条、到动作条的**视觉间距都是 20**，且和窗口高度无关——多出来的高度全部给列表本身。

## 5. 反面案例（都踩过）

| 写法 | 后果 |
|---|---|
| `MaxHeight="320"` + 默认 Stretch | 元素被限高后在大槽位里居中 → 上下各一条死空白 |
| `VerticalAlignment="Top"` | 空白全堆到一侧 → 上小下大 |
| 同一屏混用 12 / 16 / 18 | 视觉上"每个间距都不一样"，看不出规律 |

**判据**：页面级元素出现"上下对称的空白"，先查祖先是否有 `MaxHeight`/`Height`，再查对齐方式，最后才看 margin 数值。

## 6. 校验脚本（改完 XAML 后跑一遍）

```bash
cd PcDemo/PcDemo/Views
python - <<'PY'
import re, pathlib, collections
scale = {0, 4, 8, 12, 16, 24, 32}
bad = collections.Counter()
for p in sorted(pathlib.Path(".").glob("*.xaml")):
    t = p.read_text(encoding="utf-8")
    for m in re.finditer(r'\b(Padding|Margin|Spacing)="([^"]+)"', t):
        for c in m.group(2).split(","):
            c = c.strip()
            if c.isdigit() and int(c) not in scale:
                bad[(p.name, m.group(1), m.group(2))] += 1
print("非规范值: %d 处" % sum(bad.values()))
for (f, a, v), n in bad.items():
    print("  %-26s %s=\"%s\" x%d" % (f, a, v, n))
PY
```

期望输出 `非规范值: 0 处`。
