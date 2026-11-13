"""快传 PC（WinUI 3）实现自检 —— 无需 .NET SDK 的静态校验。

用法：python design/unified/check_pc.py

检查项：
  1. 所有 XAML 可被 XML 解析
  2. ThemeResource / StaticResource 引用的键都能在 DesignTokens.xaml 或 WinUI 内置键中找到
  3. DesignTokens.xaml 的 Light / Dark 主题字典键成对
  4. 页面/弹窗的 x:Name 与事件处理器契约完整（重构不得丢绑定）
  5. 间距/圆角/字号全部来自令牌，无越出 0/4/8/12/16/24/32 刻度的字面量
  6. 顶部提醒 4 态、进度弹窗逐文件进度的实现要素齐全
  7. 设计稿要求的页面/对话框文件齐备

注意：这**不能替代** `dotnet build` 与真机截图；本机若无 .NET SDK，
      XAML 编译期错误（x:Bind 路径、类型不匹配、资源 Source 解析）仍需 VS 验证。
"""
from __future__ import annotations

import collections
import glob
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
PC = ROOT / "PcDemo" / "PcDemo"
VIEWS = PC / "Views"

PASS = 0
FAIL = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print("PASS ", name)
    else:
        FAIL += 1
        print("FAIL ", name, ("· " + detail) if detail else "")


def xaml_files() -> list[pathlib.Path]:
    return sorted(PC.rglob("*.xaml"))


# ---------------------------------------------------------------- 1 XML
parse_errors = []
for p in xaml_files():
    try:
        ET.parse(p)
    except Exception as ex:  # noqa: BLE001
        parse_errors.append(f"{p.name}: {ex}")
check("XAML 全部可解析", not parse_errors, "; ".join(parse_errors[:3]))

# ------------------------------------------------------- 2 资源键闭合 / 3 成对
tokens_path = PC / "Styles" / "DesignTokens.xaml"
tokens = tokens_path.read_text(encoding="utf-8") if tokens_path.exists() else ""
check("DesignTokens.xaml 已合入工程", bool(tokens))
app_xaml = (PC / "App.xaml").read_text(encoding="utf-8")
check("App.xaml 合并了 DesignTokens.xaml", "Styles/DesignTokens.xaml" in app_xaml)
check("App.xaml 不再内联重复覆盖", "SystemAccentColorLight2" not in app_xaml)


def theme_keys(key: str) -> set[str]:
    m = re.search(r'<ResourceDictionary x:Key="%s">(.*?)</ResourceDictionary>' % key, tokens, re.S)
    return set(re.findall(r'x:Key="([^"]+)"', m.group(1))) if m else set()


light, dark = theme_keys("Light"), theme_keys("Dark")
check("Light/Dark 主题键成对", light == dark and len(light) >= 40,
      f"light={len(light)} dark={len(dark)} 差异={sorted(light ^ dark)[:5]}")

root_part = re.sub(r"<ResourceDictionary.ThemeDictionaries>.*?</ResourceDictionary.ThemeDictionaries>",
                   "", tokens, flags=re.S)
root_keys = set(re.findall(r'x:Key="([^"]+)"', root_part))

# WinUI 内置键 + 各页面局部声明的转换器键
builtin = set("""
AccentButtonStyle DefaultContentDialogStyle DefaultButtonStyle
TextFillColorPrimaryBrush TextFillColorSecondaryBrush TextOnAccentFillColorPrimaryBrush
TextOnAccentFillColorDefaultBrush CardBackgroundFillColorDefaultBrush
CardBackgroundFillColorSecondaryBrush CardStrokeColorDefaultBrush ChipFillBrush ChipStrokeBrush
SolidBackgroundFillColorBaseBrush SubtleFillColorTransparentBrush ControlStrokeColorSecondaryBrush
SystemFillColorSuccessBrush SystemFillColorCriticalBrush SystemFillColorSuccessBackgroundBrush
SystemFillColorCriticalBackgroundBrush SystemFillColorCautionBrush SystemFillColorAttentionBrush
LayerFillColorDefaultBrush LayerFillColorDefault LayerOnMicaBaseAltFillColorTransparentBrush
NavigationViewDefaultPaneBackground AccentFillColorDefaultBrush AccentFillColorSecondaryBrush
AccentFillColorTertiaryBrush
""".split())
local = set()
for p in xaml_files():
    local |= set(re.findall(r'x:Key="([^"]+)"', p.read_text(encoding="utf-8")))
all_keys = root_keys | light | dark | builtin | local

missing: collections.Counter = collections.Counter()
for p in xaml_files():
    text = p.read_text(encoding="utf-8")
    for kind, pattern in (("ThemeResource", r"ThemeResource ([A-Za-z0-9_]+)"),
                          ("StaticResource", r"StaticResource ([A-Za-z0-9_]+)")):
        for key in re.findall(pattern, text):
            if key not in all_keys:
                missing[(p.name, kind, key)] += 1
check("资源引用全部闭合", not missing,
      "; ".join(f"{a}/{b}/{c}" for (a, b, c) in list(missing)[:5]))

# ------------------------------------------------------------- 4 命名/事件契约
EXPECTED_NAMES = {
    "ClearHistoryDialog.xaml": {"SubtitleText"},
    "HistoryDetailDialog.xaml": {"FileList", "HeaderText", "ListCaption", "NoDetailsText", "SubText"},
    "HistoryPage.xaml": {"EmptyPulseIcon", "EmptyPulseStoryboard", "FilterAllBtn", "FilterReceiveBtn", "FilterSendBtn", "SearchBox"},
    "NameInputDialog.xaml": {"InputBox"},
    "ReceivePage.xaml": {"EmptyPulseIcon", "EmptyPulseStoryboard"},
    "ReceiveProgressDialog.xaml": {"FilesTextBlock", "PhaseTextBlock", "ProgressRingControl", "RingPercentTextBlock", "SenderTextBlock", "StatTextBlock"},
    "SendPage.xaml": {"DeviceScroll", "DropHighlightBorder", "EmptyPulseStoryboard", "ImportingIndicator", "PinPasswordBox", "PinToggleBtn", "PinVisibleBox", "SendEmptyPulseIcon"},
    "SendProgressDialog.xaml": {"BatchListPanel", "BatchListScroll", "BatchPanel", "BatchSummaryTextBlock", "FilesTextBlock", "ProgressRingControl", "RingPercentTextBlock", "SinglePanel", "StatTextBlock", "StateTextBlock", "TargetTextBlock"},
    "SettingsPage.xaml": {"PinPasswordBox", "PinToggleBtn", "PinVisibleBox"},
    "ShellWindow.xaml": {"AppTitleBar", "ContentFrame", "NavView", "PaneToggleButton", "RootGrid"},
    "TextInputDialog.xaml": {"InputTextBox"},
}
EXPECTED_EVENTS = {
    "DeviceListPage.xaml": {"OnAddBlacklistFromDiscoveredClick", "OnAddBlacklistManualClick", "OnAddWhitelistFromDiscoveredClick", "OnAddWhitelistManualClick", "OnRefreshDiscoveredClick", "OnRemoveBlacklistClick", "OnRemoveWhitelistClick", "OnRenameBlacklistClick", "OnRenameWhitelistClick", "OnWhitelistAutoAcceptToggled"},
    "HistoryDetailDialog.xaml": {"OnOpenDetailFileClick"},
    "HistoryPage.xaml": {"OnClearClick", "OnCopyPathClick", "OnDeleteHistoryClick", "OnFilterAllClick", "OnFilterReceiveClick", "OnFilterSendClick", "OnOpenFolderClick", "OnShowDetailsClick", "OnItemPointerEntered", "OnItemPointerExited"},
    "ReceivePage.xaml": {"OnAddToBlacklistClick", "OnAddToWhitelistClick", "OnDeviceCardDoubleTapped", "OnDeviceCardPointerEntered", "OnDeviceCardPointerExited"},
    "ReceiveProgressDialog.xaml": {"OnCancelClick", "OnContinueClick"},
    "ReceiveRequestDialog.xaml": {"OnPrimaryClick", "OnSecondaryClick", "OnSelectAllClick", "OnSelectNoneClick"},
    "SendPage.xaml": {"OnAddClipboardClick", "OnAddToBlacklistClick", "OnAddToWhitelistClick", "OnDeselectTargetClick", "OnPickFilesClick", "OnPickFolderClick", "OnPinToggleClick", "OnRemoveFileClick", "OnRemoveTargetChipClick", "OnSendTextClick", "OnPinPasswordChanged", "OnDeviceTilePointerEntered", "OnDeviceTilePointerExited", "OnPinTextChanged", "OnDragOver", "OnDragLeave", "OnDrop"},
    "SendProgressDialog.xaml": {"OnCancelClick", "OnContinueClick"},
    "SettingsPage.xaml": {"OnBrowseDestinationClick", "OnPinToggleClick", "OnPinPasswordChanged", "OnPinTextChanged"},
    "ShellWindow.xaml": {"OnPaneToggleClick", "OnSelectionChanged"},
    "TextInputDialog.xaml": {"OnSecondaryClick"},
}
EVENT_ATTR = re.compile(
    r'(?:Click|DoubleTapped|PointerEntered|PointerExited|Toggled|SelectionChanged|'
    r'TextChanged|PasswordChanged|DragOver|DragLeave|Drop|Loaded|Unloaded)="([^"]+)"')
lost_names, lost_events = [], []
for name, expected in EXPECTED_NAMES.items():
    got = set(re.findall(r'x:Name="([^"]+)"', (VIEWS / name).read_text(encoding="utf-8")))
    if expected - got:
        lost_names.append(f"{name}:{sorted(expected - got)}")
for name, expected in EXPECTED_EVENTS.items():
    got = set(EVENT_ATTR.findall((VIEWS / name).read_text(encoding="utf-8")))
    if expected - got:
        lost_events.append(f"{name}:{sorted(expected - got)}")
check("x:Name 契约未丢失", not lost_names, "; ".join(lost_names[:3]))
check("事件处理器契约未丢失", not lost_events, "; ".join(lost_events[:3]))

# ------------------------------------------------------------------ 5 刻度
SCALE = {0, 1, 4, 8, 12, 16, 24, 32}
off_scale = collections.Counter()
for p in xaml_files():
    text = p.read_text(encoding="utf-8")
    for attr in ("CornerRadius", "Padding", "Margin", "Spacing", "FontSize", "ColumnSpacing", "RowSpacing"):
        for m in re.finditer(r'\b%s="([^"{][^"]*)"' % attr, text):
            for n in re.findall(r"-?\d+(?:\.\d+)?", m.group(1)):
                if float(n) not in SCALE:
                    off_scale[(p.name, attr, m.group(1))] += 1
check("视觉值全部在 4 倍数刻度内（1px 描边除外）", sum(off_scale.values()) == 0,
      "; ".join(f"{a}/{b}={c}" for (a, b, c) in list(off_scale)[:5]))

# 文本灰化不使用 Opacity（对比度不可控），改用语义文字画刷
textblock_opacity = 0
tag_re = re.compile(r"<TextBlock((?:\"[^\"]*\"|[^>\"])*?)/?>", re.S)
for p in xaml_files():
    for m in tag_re.finditer(p.read_text(encoding="utf-8")):
        if re.search(r'Opacity="(?:0\.[0-9]+)"', m.group(1)) and "Foreground=" not in m.group(1):
            textblock_opacity += 1
check("文本不用 Opacity 灰化", textblock_opacity == 0, f"残留 {textblock_opacity} 处")

# ------------------------------------------------- 6 顶部提醒 / 逐文件进度
toast_xaml = (PC / "Controls" / "TopToast.xaml").read_text(encoding="utf-8")
toast_cs = (PC / "Controls" / "TopToast.xaml.cs").read_text(encoding="utf-8")
msg = (PC / "Messages" / "TransferResultMessage.cs").read_text(encoding="utf-8")
for kind in ("ReceiveSuccess", "ReceiveFailure", "SendSuccess", "SendFailure"):
    check("提醒 4 态 " + kind, kind in msg and kind in toast_cs)
check("提醒为顶部右上角悬浮", "HorizontalAlignment=\"Right\"" in toast_xaml
      and "VerticalAlignment=\"Top\"" in toast_xaml)
check("提醒有动作按钮与自动收起计时线",
      "PrimaryActionClick" in toast_cs and "TimerBar" in toast_xaml)

row_xaml = (PC / "Controls" / "FileProgressRow.xaml").read_text(encoding="utf-8")
check("逐文件进度行含独立进度条", 'x:Name="Bar"' in row_xaml and 'x:Name="WaitTrack"' in row_xaml)
check("等待态用空心轨道表达 0%", "BrandLineStrongBrush" in row_xaml)
for name in ("SendProgressDialog", "ReceiveProgressDialog"):
    x = (VIEWS / (name + ".xaml")).read_text(encoding="utf-8")
    cs = (VIEWS / (name + ".xaml.cs")).read_text(encoding="utf-8")
    check(name + " 总进度条按字节", 'x:Name="TotalProgressBar"' in x and "TotalProgressBar.Value" in cs)
    check(name + " 文件列表独立滚动", "FileListMaxHeight" in x)
    check(name + " 逐文件刷新", "BuildFileRows" in cs and "RefreshFileRows" in cs)

# ------------------------------------------------------------- 7 文件齐备
for rel in ("Styles/DesignTokens.xaml", "Controls/TopToast.xaml", "Controls/TopToast.xaml.cs",
            "Controls/FileProgressRow.xaml", "Controls/FileProgressRow.xaml.cs",
            "Messages/TransferResultMessage.cs", "Messages/NavigateToPageMessage.cs",
            "Views/ReceivePage.xaml", "Views/SendPage.xaml", "Views/HistoryPage.xaml",
            "Views/DeviceListPage.xaml", "Views/SettingsPage.xaml",
            "Views/ClearHistoryDialog.xaml", "Views/ClearHistoryDialog.xaml.cs"):
    check("文件存在 " + rel, (PC / rel).exists())

# --------------------------------------------- 8 codebehind 配对（编译期风险）
pair_errors = []
for p in xaml_files():
    m = re.search(r'x:Class="([^"]+)"', p.read_text(encoding="utf-8"))
    if not m:
        continue
    cls = m.group(1).split(".")[-1]
    cs = p.with_name(p.name + ".cs")
    if not cs.exists():
        pair_errors.append(f"{p.name} 缺 codebehind")
    elif not re.search(r"class\s+%s\b" % re.escape(cls), cs.read_text(encoding="utf-8")):
        pair_errors.append(f"{p.name} x:Class={cls} 与 codebehind 类名不符")
check("所有 x:Class 都有对应 codebehind 且类名一致", not pair_errors,
      "; ".join(pair_errors[:3]))

# ------------------------------- 9 统计条绑定可靠性 / 破坏性弹窗 / 状态色语义
dev_xaml = (VIEWS / "DeviceListPage.xaml").read_text(encoding="utf-8")
dev_vm = (PC / "ViewModels" / "DeviceListViewModel.cs").read_text(encoding="utf-8")
check("统计条不直接 x:Bind 集合 Count（显式接口通知不可靠）",
      not re.search(r"x:Bind\s+ViewModel\.(Whitelist|Blacklist)\.Count", dev_xaml))
check("统计条计数来自 VM 强类型属性 + PropertyChanged",
      "WhitelistCount" in dev_xaml and "BlacklistCount" in dev_xaml
      and "_whitelistCount" in dev_vm and "_blacklistCount" in dev_vm
      and "WhitelistCount = Whitelist.Count" in dev_vm)
conv = (PC / "Converters" / "RefreshConverters.cs").read_text(encoding="utf-8")
check("InvertedBoolToVisibility 转换器存在", "class InvertedBoolToVisibility" in conv)
check("统计条开/关两态互斥且语义色正确",
      "BoolToVisibility" in dev_xaml and "InvertedBoolToVisibility" in dev_xaml
      and "BrandSuccessSoftBrush" in dev_xaml and "ChipFillBrush" in dev_xaml)

hist_cs = (VIEWS / "HistoryPage.xaml.cs").read_text(encoding="utf-8")
clear_xaml = (VIEWS / "ClearHistoryDialog.xaml").read_text(encoding="utf-8")
clear_cs = (VIEWS / "ClearHistoryDialog.xaml.cs").read_text(encoding="utf-8")
check("clear 弹窗为独立 XAML 控件且被 HistoryPage 调用",
      "new ClearHistoryDialog" in hist_cs
      and 'x:Class="PcDemo.Views.ClearHistoryDialog"' in clear_xaml)
check("clear 弹窗危险色主按钮 + 警示条 + 默认焦点在取消",
      "DangerButtonStyle" in clear_xaml and "BrandDangerSoftBrush" in clear_xaml
      and 'DefaultButton="Close"' in clear_xaml)
check("clear 弹窗记录数取全部历史（非筛选结果）",
      "ViewModel.Items.Count" in hist_cs and "recordCount" in clear_cs)
check("不再有内联 ContentDialog",
      not any("new ContentDialog" in p.read_text(encoding="utf-8")
              for p in VIEWS.glob("*.xaml.cs")))
check("危险按钮文字色双主题成对",
      "BrandDangerOnBrush" in light and "BrandDangerOnBrush" in dark)

print("-" * 58)
print(f"共 {PASS + FAIL} 项，失败 {FAIL} 项")
sys.exit(1 if FAIL else 0)
