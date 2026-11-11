#!/usr/bin/env python3
"""生成 TempBar 的应用图标（AppIcon.icns）。

为什么自己画一张：这个 app 之前完全没带图标，Finder 里就是一个白底默认占位，
看着像半成品。等设计出图之前先用一张"和小组件同一套配色"的临时图标顶上，
至少和界面是一致的。

画法说明：
- 先按 4 倍尺寸画（4096），最后降采样到 1024，边缘才够干净；
  直接在 1024 上画，圆角和细笔画会有锯齿。
- 形状按 macOS Big Sur 之后的规范：满幅正方形 + 圆角半径 = 0.2237 × 边长。
  图标本身不再额外缩进（系统会自己留白），否则在 Dock 里会比别人小一圈。
- 配色直接复用小组件仿苹果主题的渐变端点，
  这样图标、卡片、菜单栏是同一套视觉。
"""
from PIL import Image, ImageDraw
import numpy as np
import os
import subprocess

SS = 4                     # 超采样倍数
S = 1024                   # 最终边长
W = S * SS

TOP = (20, 0, 149)         # 与 WidgetPanel 里仿苹果渐变一致
BOTTOM = (58, 13, 195)
WHITE = (255, 255, 255)


def gradient(w, h):
    """竖直渐变。用 numpy 逐行插值，比画 1024 条线快且无接缝。"""
    t = np.linspace(0.0, 1.0, h).reshape(h, 1)
    arr = np.zeros((h, w, 3), dtype=np.uint8)
    for i in range(3):
        arr[:, :, i] = (TOP[i] + (BOTTOM[i] - TOP[i]) * t).astype(np.uint8)
    return Image.fromarray(arr)


def squircle_mask(size, radius):
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def build_icon():
    bg = gradient(W, W).convert('RGBA')

    # 左上角一层很淡的高光，纯渐变会显得太"平"，加一点光感就有金属味
    glow = Image.new('L', (W, W), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-W * 0.35, -W * 0.55, W * 0.75, W * 0.45], fill=48)
    glow = glow.filter(__import__('PIL.ImageFilter', fromlist=['ImageFilter']).GaussianBlur(W // 12))
    bg = Image.composite(Image.new('RGBA', (W, W), (255, 255, 255, 255)), bg, glow.point(lambda v: v // 2))

    d = ImageDraw.Draw(bg)

    # ---- 温度计：管身 + 球泡，全部用白色描边、内部留空
    # 右边还有刻度，几何中心在 W/2 时视觉上会偏左，所以整体左移一点点
    cx = int(W / 2 - W * 0.035)
    stem_w = int(W * 0.135)
    stem_top = int(W * 0.235)
    bulb_r = int(W * 0.125)
    bulb_cy = int(W * 0.705)
    stroke = int(W * 0.032)

    stem = [cx - stem_w // 2, stem_top, cx + stem_w // 2, bulb_cy]
    d.rounded_rectangle(stem, radius=stem_w // 2, fill=WHITE)
    d.ellipse([cx - bulb_r, bulb_cy - bulb_r, cx + bulb_r, bulb_cy + bulb_r], fill=WHITE)

    # 挖空：管身内壁 + 球泡内壁，做出"玻璃管"的观感
    inner = [stem[0] + stroke, stem[1] + stroke, stem[2] - stroke, stem[3] - stroke]
    d.rounded_rectangle(inner, radius=(stem_w - stroke * 2) // 2, fill=(0, 0, 0, 0))
    ir = bulb_r - stroke
    d.ellipse([cx - ir, bulb_cy - ir, cx + ir, bulb_cy + ir], fill=(0, 0, 0, 0))

    # 水银柱：球泡实心 + 一段管子，只到 62%，留出"还没满"的感觉
    d.ellipse([cx - ir, bulb_cy - ir, cx + ir, bulb_cy + ir], fill=WHITE)
    merc_top = int(stem_top + (bulb_cy - stem_top) * 0.38)
    mw = (stem_w - stroke * 2) // 2
    d.rounded_rectangle([cx - mw, merc_top, cx + mw, bulb_cy], radius=mw, fill=WHITE)

    # ---- 右侧三档刻度，越往上越短
    tick_x0 = cx + stem_w // 2 + int(W * 0.045)
    for i, (ty, ln) in enumerate([(0.34, 0.085), (0.45, 0.062), (0.56, 0.085)]):
        y = int(W * ty)
        d.rounded_rectangle([tick_x0, y, tick_x0 + int(W * ln), y + int(W * 0.022)],
                            radius=int(W * 0.011), fill=(255, 255, 255, 190))

    out = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    out.paste(bg, (0, 0), squircle_mask(W, int(W * 0.2237)))
    return out.resize((S, S), Image.LANCZOS)


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(os.path.join(root, 'build'), exist_ok=True)

    # 有正式稿就用正式稿（assets/AppIcon-1024.png，1024×1024 带透明圆角），
    # 没有才回落到上面那套脚本画的临时图标。
    provided = os.path.join(root, 'assets', 'AppIcon-1024.png')
    if os.path.exists(provided):
        icon = Image.open(provided).convert('RGBA')
        if icon.size != (S, S):
            icon = icon.resize((S, S), Image.LANCZOS)
    else:
        icon = build_icon()

    png = os.path.join(root, 'build', 'icon-1024.png')
    icon.save(png)

    iconset = os.path.join(root, 'build', 'AppIcon.iconset')
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ''), (2, '@2x')):
            px = base * scale
            icon.resize((px, px), Image.LANCZOS).save(
                os.path.join(iconset, f'icon_{base}x{base}{suffix}.png'))
    icns = os.path.join(root, 'build', 'AppIcon.icns')
    subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', icns], check=True)
    print(icns)


if __name__ == '__main__':
    main()
