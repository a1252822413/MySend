#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""快传统一设计交付自检。
用法：python design/unified/check.py
检查：资源引用、token 三端映射覆盖、配色字面量、间距刻度、双端页面/弹窗完整、
      系统材质三档、顶部提醒 4 态、进度弹窗多文件逐条进度、阴影减重、WCAG 对比度。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
FILES = [
    "README.md", "tokens.css", "tokens.json", "index.html",
    "styles.css", "app.js", "handoff/DesignTokens.xaml", "handoff/Theme.ets",
]
MATERIALS = ["mica", "acrylic", "solid"]
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))


def read(p):
    return p.read_text(encoding="utf-8")


# 1 文件齐备
for f in FILES:
    check("文件存在 " + f, (ROOT / f).is_file())

# 2 HTML 引用的本地资源存在
html = read(ROOT / "index.html")
refs = re.findall(r'(?:href|src)="([^"#]+\.(?:css|js))"', html)
check("HTML 本地资源引用", len(refs) >= 3 and all((ROOT / r).is_file() for r in refs),
      ", ".join(refs))

# 3 视觉值只来自 token：styles.css / index.html 不得出现颜色字面量
css = read(ROOT / "styles.css")
color_literal = re.compile(r'#[0-9a-fA-F]{3,8}\b|\brgba?\(')
css_bad = color_literal.findall(css)
html_bad = [m for m in color_literal.findall(html) if not m.startswith('#i-')]
check("styles.css 无颜色字面量", not css_bad, str(css_bad[:3]))
check("index.html 无颜色字面量", not html_bad, str(html_bad[:3]))

# 4 间距刻度：样式中的 padding/margin/gap 只允许 var()/calc()/0/auto
space_bad = []
for m in re.finditer(r'\b(?:padding|margin|gap)(?:-[a-z]+)?\s*:\s*([^;]+)', css):
    for token in m.group(1).split():
        if re.fullmatch(r'\d+(?:\.\d+)?px', token):
            space_bad.append(token)
check("styles.css 间距全部 token 化", not space_bad, ", ".join(sorted(set(space_bad))[:8]))

# 5 tokens.css 间距刻度只允许 0/4/8/12/16/24/32/48
tokens_css = read(ROOT / "tokens.css")
allowed = {0, 4, 8, 12, 16, 24, 32, 48}
scale_bad = [m.group(1) for m in re.finditer(r'--sp-\d+:\s*(\d+)px', tokens_css)
             if int(m.group(1)) not in allowed]
check("间距刻度符合 4 倍数", not scale_bad, ", ".join(scale_bad))

# 6 系统材质三档 × 双主题必须齐备（材质由系统状态驱动，不是用户设置项）
missing_material = []
for theme in ("light", "dark"):
    for material in MATERIALS:
        sel = '[data-theme="%s"][data-material="%s"]' % (theme, material)
        if sel not in tokens_css:
            missing_material.append(sel)
check("系统材质 3 档 × 2 主题齐备", not missing_material, "; ".join(missing_material[:3]))

# 7 阴影已减重：亮色卡影模糊 ≤3px、暗色 ≤2px，透明度和 ≤0.06
def shadow_layers(block, name):
    m = re.search(r'--%s:\s*([^;]+);' % name, block)
    if not m:
        return []
    # 直接对整段取值做 findall，避免按逗号切分时打断 rgba(...) 内部的逗号
    found = re.findall(
        r'(-?[\d.]+)(?:px)?\s+(-?[\d.]+)(?:px)?\s+(\d+)px\s+rgba\(([^)]+)\)',
        m.group(1))
    return [(int(blur), float(alpha.split(",")[-1].strip())) for _, _, blur, alpha in found]

light_block = re.search(r':root,\s*\n\[data-theme="light"\]\s*\{(.*?)\n\}', tokens_css, re.S)
dark_block = re.search(r'\[data-theme="dark"\]\s*\{(.*?)\n\}', tokens_css, re.S)
heavy = []
for label, block, max_blur, max_alpha in (
    ("light card-shadow", light_block, 3, 0.04),
    ("light card-shadow-hover", light_block, 8, 0.05),
    ("dark card-shadow", dark_block, 2, 0.20),
    ("dark card-shadow-hover", dark_block, 8, 0.22),
):
    layers = shadow_layers(block.group(1), label.split()[-1]) if block else []
    if not layers:
        heavy.append(label + " 未解析")
        continue
    for blur, alpha in layers:
        if blur > max_blur or alpha > max_alpha:
            heavy.append("%s blur=%dpx alpha=%.2f" % (label, blur, alpha))
check("阴影已减重（近距 + 低透明）", not heavy, "; ".join(heavy[:4]))

# 8 tokens.json 的 CSS 变量必须在 tokens.css 定义
data = json.loads(read(ROOT / "tokens.json"))
missing_css = [t["css"] for t in data["tokens"] if (t["css"] + ":") not in tokens_css]
check("tokens.json → tokens.css 覆盖", not missing_css, ", ".join(missing_css))

# 9 三端 handoff 覆盖所有映射 key
xaml = read(ROOT / "handoff/DesignTokens.xaml")
ets = read(ROOT / "handoff/Theme.ets")
missing_xaml = [t["xaml"] for t in data["tokens"] if t["xaml"] not in xaml]
missing_ets = [t["arkts"] for t in data["tokens"] if not re.search(r'\b' + re.escape(t["arkts"]) + r'\b', ets)]
check("tokens.json → XAML 键覆盖", not missing_xaml, ", ".join(missing_xaml))
check("tokens.json → ArkTS 字段覆盖", not missing_ets, ", ".join(missing_ets))

# 10 XAML 的 Light / Dark 字典必须成对含同名键
def theme_keys(block):
    return set(re.findall(r'x:Key="([^"]+)"', block))
light = re.search(r'<ResourceDictionary x:Key="Light">(.*?)</ResourceDictionary>', xaml, re.S)
dark = re.search(r'<ResourceDictionary x:Key="Dark">(.*?)</ResourceDictionary>', xaml, re.S)
check("XAML 含 Light/Dark 双主题字典", bool(light and dark))
if light and dark:
    only_light = sorted(theme_keys(light.group(1)) - theme_keys(dark.group(1)))
    only_dark = sorted(theme_keys(dark.group(1)) - theme_keys(light.group(1)))
    check("XAML 双主题键成对", not only_light and not only_dark,
          "Light-only: %s | Dark-only: %s" % (only_light[:4], only_dark[:4]))

# 11 双端页面集一致（各 5 页，data-page 集合相同）
pc_pages = sorted(set(re.findall(r'data-device="pc"\s+data-page="([^"]+)"', html)))
ph_pages = sorted(set(re.findall(r'data-device="phone"\s+data-page="([^"]+)"', html)))
expect_pages = ["devices", "history", "receive", "send", "settings"]
check("PC 五个页面", pc_pages == expect_pages, ", ".join(pc_pages))
check("鸿蒙五个页面", ph_pages == expect_pages, ", ".join(ph_pages))
check("双端页面语义一致", pc_pages == ph_pages)

# 12 双端功能齐备：按端切分 HTML，逐端核对功能词
pc_html = html.split('device device-phone')[0]
phone_html = html.split('device device-phone')[-1]
features = {
    "白名单": "白名单",
    "黑名单": "黑名单",
    "信任标记": "已信任",
    "自动接收": "自动接收",
    "仅白名单模式": "仅白名单模式",
    "PIN": "PIN",
    "设备管理": "设备管理",
}
missing_feature = []
for label, word in features.items():
    if word not in pc_html:
        missing_feature.append("PC/" + label)
    if word not in phone_html:
        missing_feature.append("手机/" + label)
check("关键功能在两端均有呈现", not missing_feature, ", ".join(missing_feature))
check("PC 有防火墙放行入口", "防火墙" in pc_html)
check("手机有后台保活与分享入口", "后台保活" in phone_html and "分享入口" in phone_html)
check("双端都有设备管理页", 'data-page="devices"' in html and html.count('data-page="devices"') >= 2)

# 13 弹窗：双端各一套、8 种、ID 对齐选择器
dialog_ids = re.findall(r'data-dialog="([^"]+)"', html)
unique_dialogs = sorted(set(dialog_ids))
expect_dialogs = ["clear", "detail", "pin", "receive-progress", "receive-request",
                  "rename", "send-progress", "text"]
check("弹窗 8 种齐全", unique_dialogs == expect_dialogs, ", ".join(unique_dialogs))
duplicated = [d for d in unique_dialogs if dialog_ids.count(d) < 2]
check("弹窗双端各一套", not duplicated, ", ".join(duplicated))
seg_values = sorted(set(re.findall(r'data-dialog-value="([^"]+)"', html)))
check("弹窗选择器与弹窗一一对应", seg_values == unique_dialogs, ", ".join(seg_values))
for kind in ("dlg", "sheet", "alert"):
    check("弹窗形态 " + kind, ('class="%s' % kind) in html)

# 13.5 顶部悬浮提醒：4 态 × 双端，且必须是悬浮层
toast_ids = re.findall(r'data-toast-id="([^"]+)"', html)
expect_toasts = ["receive-fail", "receive-ok", "send-fail", "send-ok"]
check("提醒 4 态齐全（接收/发送 × 成功/失败）", sorted(set(toast_ids)) == expect_toasts,
      ", ".join(sorted(set(toast_ids))))
check("提醒双端各一套", all(toast_ids.count(t) >= 2 for t in expect_toasts),
      ", ".join(t for t in expect_toasts if toast_ids.count(t) < 2))
toast_seg = sorted(set(re.findall(r'data-toast-value="([^"]+)"', html)))
check("提醒选择器与提醒一一对应", toast_seg == expect_toasts, ", ".join(toast_seg))
toast_host_rule = re.search(r'\.toast-host \{(.*?)\}', css, re.S)
toast_rule = toast_host_rule.group(1) if toast_host_rule else ''
check("提醒为顶部悬浮层（absolute）", 'position: absolute' in toast_rule)
check("提醒层级低于弹窗", 'z-index: 15' in toast_rule and 'z-index: 20' in css)
check("提醒含发送失败与接收失败文案",
      html.count("发送失败") >= 2 and html.count("接收失败") >= 2)

# 13.6 材质与动效跟随系统，不是设置项；设置页只保留主题
forbidden = ["窗口材质", "界面材质", "减少动效"]
left = [w for w in forbidden if (">%s<" % w) in html]
check("设置页无材质/动效开关", not left, ", ".join(left))

# 13.7 进度弹窗：4 个容器（PC/手机 × 发送/接收）都要看得见「每个文件自己的进度条」
split_mark = "==================== HarmonyOS ===================="
pc_html_full, phone_html_full = html.split(split_mark)[0], html.split(split_mark)[1]
for part_name, part in (("PC", pc_html_full), ("手机", phone_html_full)):
    rows = len(re.findall(r'class="fp-row ', part))
    bars = len(re.findall(r'role="progressbar"', part))
    check("%s 发送/接收进度各含 3 个文件" % part_name, rows == 6, "fp-row=%d" % rows)
    check("%s 每个文件都有独立进度条 + 总进度条" % part_name, bars == 8, "progressbar=%d" % bars)
    check("%s 进度弹窗均为「总进度 + 文件进度」两层" % part_name,
          part.count('class="prog-summary"') == 2 and part.count('class="fp-list"') == 2)
check("进度条全部带 aria-valuenow（不只靠颜色）",
      len(re.findall(r'role="progressbar"[^>]*aria-valuenow="\d+"', html)) == 16)
check("三种文件状态齐备：已完成 / 传输中 / 等待中",
      all(html.count("is-%s" % s) >= 2 for s in ("done", "active", "wait")))
check("文件列表支持多文件滚动且不被隐藏",
      'max-height: calc(var(--sp-7) * 5)' in css and '.fp-row' in css
      and not re.search(r'\.fp-row[^{]*\{[^}]*display:\s*none', css))
check("总进度按字节口径标注，与逐文件百分比区分",
      html.count('aria-label="总进度（按字节）"') == 4 and html.count("文件进度") == 4)
check("设置页保留主题选择", "跟随系统" in pc_html and "跟随系统" in phone_html)

# 14 PC 端工程间距自检（沿用 docs/UI-SPACING.md 规则）
views = REPO / "PcDemo" / "PcDemo" / "Views"
view_bad = []
if views.is_dir():
    for p in sorted(views.glob("*.xaml")):
        text = read(p)
        for m in re.finditer(r'\b(?:Padding|Margin|Spacing)="([^"]+)"', text):
            for part in m.group(1).split(","):
                part = part.strip()
                if part.isdigit() and int(part) not in {0, 4, 8, 12, 16, 24, 32}:
                    view_bad.append("%s %s=%s" % (p.name, m.group(0).split("=")[0], m.group(1)))
check("PcDemo Views 间距规范", not view_bad, "%d 处违规 %s" % (len(view_bad), view_bad[:3]))

# 15 WCAG 对比度复算
def lum(h):
    h = h.lstrip("#")
    def ch(c):
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = [int(h[i:i + 2], 16) for i in (0, 2, 4)]
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)

def contrast(a, b):
    x, y = sorted([lum(a), lum(b)], reverse=True)
    return (x + 0.05) / (y + 0.05)

by_name = {t["name"]: t for t in data["tokens"]}
pairs = [
    ("文字/卡片", "text", "surface", 4.5),
    ("次要文字/卡片", "textDim", "surface", 4.5),
    ("微型标签/卡片", "textMute", "surface", 4.5),
    ("强调底文字/实心按钮", "onAccent", "accentFill", 4.5),
    ("绿色小字/卡片", "accentInk", "surface", 4.5),
    ("卡片内品牌图形", "accent", "surface", 3.0),
    ("页面底绿色文字或图形须用 accentInk", "accentInk", "bg", 4.5),
]
for theme in ("light", "dark"):
    for label, fg, bg, minimum in pairs:
        a, b = by_name[fg][theme], by_name[bg][theme]
        if not (a.startswith("#") and b.startswith("#")):
            continue
        ratio = contrast(a, b)
        check("WCAG %s %s" % (theme, label), ratio >= minimum, "%.2f:1 (需 %.1f)" % (ratio, minimum))

# 汇总
width = max(len(n) for n, _, _ in results)
failed = 0
for name, ok, detail in results:
    if not ok:
        failed += 1
    print("%s  %-*s  %s" % ("PASS" if ok else "FAIL", width, name, detail if detail else ""))
print("-" * (width + 12))
print("共 %d 项，失败 %d 项" % (len(results), failed))
sys.exit(1 if failed else 0)
