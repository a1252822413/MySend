#!/usr/bin/env python3
"""生成 LocalSend PC 应用标志的全部位图资源。

设计：绿色圆角方块 + 两个错轴的对向箭头（上箭头向右、下箭头向左），
表达"数据双向穿过这条通道"。

关键约束：托盘/任务栏图标只有 16px。所以按尺寸切换字形粗细——
<= 32px 用 bold 变体（箭头 20 单位、间隙 20），否则用 normal 变体。
所有位图先在 4 倍尺寸绘制再降采样，获得干净的抗锯齿边缘。

用法：python tools/gen_logo.py
"""
from PIL import Image, ImageDraw
import os

GREEN = (22, 163, 74, 255)      # #16A34A
WHITE = (255, 255, 255, 255)
SS = 4                           # 超采样倍率

ASSETS = os.path.join(os.path.dirname(__file__), "..", "PcDemo", "PcDemo", "Assets")
ASSETS = os.path.abspath(ASSETS)


def _scaled(pts, k):
    return [(x * k, y * k) for x, y in pts]


def draw_tile(img_size, glyph="normal", tile=True, tile_scale=1.0):
    """在 128 单位坐标系里画标志，返回 img_size 见方的 RGBA 图。"""
    W = img_size * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = W / 128.0

    if tile:
        t = 128 * tile_scale
        off = (128 - t) / 2.0
        d.rounded_rectangle([off * k, off * k, (off + t) * k - 1, (off + t) * k - 1],
                            radius=28 * tile_scale * k, fill=GREEN)

    if glyph == "bold":
        # 箭头更粗、间隙更大：16/24px 下不会粘成一团
        # 箭杆塞进三角内部（x 到 92 / 从 40 起），避免圆角在三角底边露出小凸起
        d.rounded_rectangle([20 * k, 28 * k, 92 * k, 48 * k], radius=10 * k, fill=WHITE)
        d.polygon(_scaled([(80, 16), (116, 38), (80, 60)], k), fill=WHITE)
        d.rounded_rectangle([36 * k, 80 * k, 108 * k, 100 * k], radius=10 * k, fill=WHITE)
        d.polygon(_scaled([(48, 68), (12, 90), (48, 112)], k), fill=WHITE)
    else:
        d.rounded_rectangle([24 * k, 30 * k, 94 * k, 46 * k], radius=8 * k, fill=WHITE)
        d.polygon(_scaled([(80, 20), (114, 38), (80, 56)], k), fill=WHITE)
        d.rounded_rectangle([34 * k, 82 * k, 104 * k, 98 * k], radius=8 * k, fill=WHITE)
        d.polygon(_scaled([(48, 72), (14, 90), (48, 108)], k), fill=WHITE)

    return img.resize((img_size, img_size), Image.LANCZOS)


def glyph_only(size, color=GREEN):
    """无底板字形（unplated / 锁屏用）：裁到字形包围盒，铺满画布。"""
    src = draw_tile(size * 4, glyph="bold" if size <= 32 else "normal", tile=False)
    bbox = src.getbbox()
    src = src.crop(bbox)
    # 字形本身是白色，重新着色为目标色
    solid = Image.new("RGBA", src.size, color)
    solid.putalpha(src.getchannel("A"))
    # 留 1px 视觉边距
    pad = max(1, int(size * 0.06))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    side = size - pad * 2
    canvas.paste(solid.resize((side, side), Image.LANCZOS), (pad, pad), solid.resize((side, side), Image.LANCZOS))
    return canvas


def wide(w, h, logo_px):
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    logo = draw_tile(logo_px, glyph="normal")
    canvas.paste(logo, ((w - logo_px) // 2, (h - logo_px) // 2), logo)
    return canvas


def main():
    os.makedirs(ASSETS, exist_ok=True)
    jobs = [
        ("Square44x44Logo.scale-200.png", draw_tile(88, "bold")),
        ("Square150x150Logo.scale-200.png", draw_tile(300, "normal")),
        ("StoreLogo.png", draw_tile(50, "bold")),
        ("LockScreenLogo.scale-200.png", glyph_only(48)),
        ("Square44x44Logo.targetsize-24_altform-unplated.png", glyph_only(24)),
        ("Wide310x150Logo.scale-200.png", wide(620, 300, 180)),
        ("SplashScreen.scale-200.png", wide(1240, 600, 240)),
    ]
    for name, im in jobs:
        path = os.path.join(ASSETS, name)
        im.save(path)
        print("  %-54s %s" % (name, im.size))

    ico = os.path.join(ASSETS, "app.ico")
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [draw_tile(s, "bold" if s <= 32 else "normal") for s in sizes]
    frames[-1].save(ico, format="ICO", sizes=[(s, s) for s in sizes],
                    append_images=frames[:-1])
    print("  %-54s %s" % ("app.ico", sizes))

    print("\n资源目录: %s" % ASSETS)


if __name__ == "__main__":
    main()
