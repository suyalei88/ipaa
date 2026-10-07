#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_icon.py —— 生成 App 图标 + Assets.xcassets

产物（iOS 17 单尺寸 1024，Xcode 会自动切其他尺寸）：
    LeapmotorLite/Assets.xcassets/Contents.json
    LeapmotorLite/Assets.xcassets/AppIcon.appiconset/Contents.json
    LeapmotorLite/Assets.xcassets/AppIcon.appiconset/icon-1024.png

依赖：Pillow（pip install pillow）
    python ios/tools/make_icon.py
"""
from __future__ import annotations

import json
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(HERE, "..", "LeapmotorLite", "LeapmotorLite"))
ASSETS = os.path.join(APP, "Assets.xcassets")
ICONSET = os.path.join(ASSETS, "AppIcon.appiconset")

S = 1024


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def build() -> Image.Image:
    img = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(img)

    # ---- 背景：深板岩 → 深青 对角渐变 ----
    top = (10, 16, 28)      # #0A101C
    bot = (13, 74, 92)      # #0D4A5C
    for y in range(S):
        t = y / (S - 1)
        # 加一点对角感
        row = lerp(top, bot, t ** 0.85)
        d.line([(0, y), (S, y)], fill=row)

    # ---- 中心柔光 ----
    glow = Image.new("L", (S, S), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([S * 0.10, S * 0.02, S * 0.90, S * 0.82], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.18))
    img = Image.composite(Image.new("RGB", (S, S), (34, 211, 238)), img, glow)

    d = ImageDraw.Draw(img)

    # ---- 车身（圆角矩形）----
    body = [150, 470, 874, 726]
    d.rounded_rectangle(body, radius=92, fill=(255, 255, 255))

    # ---- 车顶 / 座舱 ----
    cabin = [286, 336, 738, 546]
    d.rounded_rectangle(cabin, radius=96, fill=(255, 255, 255))

    # ---- 座舱玻璃（挖空感，用背景色近似）----
    glass = [330, 380, 694, 508]
    d.rounded_rectangle(glass, radius=54, fill=(16, 42, 58))

    # ---- 车灯 ----
    d.rounded_rectangle([196, 556, 316, 606], radius=25, fill=(34, 211, 238))
    d.rounded_rectangle([708, 556, 828, 606], radius=25, fill=(34, 211, 238))

    # ---- 轮胎 ----
    for cx in (322, 702):
        d.ellipse([cx - 86, 640, cx + 86, 812], fill=(255, 255, 255))
        d.ellipse([cx - 44, 682, cx + 44, 770], fill=(16, 42, 58))

    # ---- 地面阴影 ----
    sh = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(sh)
    sd.ellipse([180, 742, 844, 826], fill=110)
    sh = sh.filter(ImageFilter.GaussianBlur(28))
    img = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), img, sh)

    return img


def write_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main() -> int:
    os.makedirs(ICONSET, exist_ok=True)

    icon = build()
    icon_path = os.path.join(ICONSET, "icon-1024.png")
    icon.save(icon_path, "PNG")
    print("icon  ->", icon_path)

    write_json(os.path.join(ASSETS, "Contents.json"), {
        "info": {"author": "xcode", "version": 1},
    })

    write_json(os.path.join(ICONSET, "Contents.json"), {
        "images": [
            {
                "filename": "icon-1024.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    })
    print("catal ->", ASSETS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
