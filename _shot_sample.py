from PIL import Image

f1 = r'D:\Onedrive\图片\Screenshots\屏幕截图 2026-10-16 184906.png'
f2 = r'D:\Onedrive\图片\Screenshots\屏幕截图 2026-10-16 184857.png'

def sample(path, pts, scale):
    im = Image.open(path).convert('RGB')
    print(f"--- {path.split(chr(92))[-1]}  size={im.size} ---")
    out = {}
    for name, (px, py) in pts.items():
        x, y = int(px * scale), int(py * scale)
        c = im.getpixel((x, y))
        out[name] = c
        print(f"  {name:<22} 预览({px:>4},{py:>4}) -> 实际({x:>4},{y:>4})  RGB{c}  #{c[0]:02X}{c[1]:02X}{c[2]:02X}")
    return out

s1 = 1970 / 1082.0
a = sample(f1, {
    '页面背景(右下空白)': (900, 470),
    'Hero卡背景': (900, 100),
    '设备瓦片背景': (400, 320),
    '设备瓦片背景(左)': (210, 350),
    'Hero头像(绿圆)': (250, 140),
    '导航栏背景': (75, 300),
    '内容区背景(卡外)': (900, 260),
    '标题栏': (600, 15),
}, s1)

s2 = 1964 / 1082.0
b = sample(f2, {
    '页面背景': (900, 700),
    '弹窗内容区背景': (540, 180),
    '进度环内部': (540, 300),
    '进度环轨道(下)': (540, 350),
    '进度弧(上)': (540, 220),
    '弹窗底部按钮条': (540, 545),
    '设备瓦片(弹窗后)': (210, 350),
}, s2)

print()
print("=== 反推 alpha（假设是 白/黑 按 alpha 叠加在页面背景上）===")
for label, (card, bg) in {
    '亮/暗 卡片 vs 页面背景': (a['Hero卡背景'], a['页面背景(右下空白)']),
    '设备瓦片 vs 页面背景': (a['设备瓦片背景'], a['页面背景(右下空白)']),
    '弹窗内容区 vs 页面背景': (b['弹窗内容区背景'], b['页面背景']),
    '弹窗按钮条 vs 页面背景': (b['弹窗底部按钮条'], b['页面背景']),
}.items():
    for ch, nm in zip(range(3), 'RGB'):
        d = 255 - bg[ch]
        if d > 0:
            alpha = (card[ch] - bg[ch]) / d
            print(f"  {label:<24} {nm}: alpha≈{alpha:.3f}  (card={card[ch]} bg={bg[ch]})")
            break
