"""生成发布用品牌物料：横幅、宣传卡、GitHub social preview、exe 图标。
运行：python tools/make_art.py
素材：branding/icon-256.png + 生成的背景图 + docs/screenshots/
"""
from __future__ import annotations

import glob
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "branding")
SHOTS = os.path.join(ROOT, "docs", "screenshots")

INK = (8, 11, 17)
TEXT = (233, 238, 247)
MUTED = (150, 163, 184)
VIOLET = (140, 107, 255)
CYAN = (47, 230, 200)
FONT_BD = "C:/Windows/Fonts/msyhbd.ttc"
FONT_RG = "C:/Windows/Fonts/msyh.ttc"


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_BD if bold else FONT_RG, size)


def fit_cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    """等比裁切填满目标尺寸。"""
    tw, th = size
    scale = max(tw / image.width, th / image.height)
    resized = image.resize((int(image.width * scale + 1), int(image.height * scale + 1)),
                           Image.LANCZOS)
    left = (resized.width - tw) // 2
    top = (resized.height - th) // 2
    return resized.crop((left, top, left + tw, top + th))


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int, int],
                      bottom: tuple[int, int, int, int]) -> Image.Image:
    grad = Image.new("RGBA", (1, size[1]))
    for y in range(size[1]):
        k = y / max(size[1] - 1, 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(4)))
    return grad.resize(size)


def horizontal_fade(size: tuple[int, int], color: tuple[int, int, int, int],
                    start: float, end: float) -> Image.Image:
    """从 x=start 处不透明渐变到 x=end 处全透明（用于压暗文字区）。"""
    width, height = size
    grad = Image.new("RGBA", (width, 1))
    for x in range(width):
        k = (x / max(width - 1, 1) - start) / max(end - start, 1e-3)
        alpha = int(color[3] * (1.0 - max(0.0, min(1.0, k))))
        grad.putpixel((x, 0), (color[0], color[1], color[2], alpha))
    return grad.resize(size)


def spaced_text(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str,
                fnt: ImageFont.FreeTypeFont, fill, spacing: int = 0) -> int:
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += draw.textlength(ch, font=fnt) + spacing
    return x


def rounded_shot(path: str, size: tuple[int, int], radius: int = 18) -> Image.Image:
    shot = fit_cover(Image.open(path).convert("RGB"), size)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, 255)
    out = Image.new("RGBA", size)
    out.paste(shot, (0, 0), mask)
    return out


def with_shadow(card: Image.Image, blur: int = 26, offset: tuple[int, int] = (0, 16),
                alpha: int = 170) -> Image.Image:
    pad = blur * 2
    canvas = Image.new("RGBA", (card.width + pad * 2, card.height + pad * 2), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    mask = Image.new("L", card.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, card.width - 1, card.height - 1), 18, 255)
    shadow.paste((0, 0, 0, alpha), (pad + offset[0], pad + offset[1]), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(card, (pad, pad))
    return canvas


def pill(img: Image.Image, xy: tuple[int, int], text: str, fnt, color) -> int:
    """半透明药丸标签。必须画在独立图层上再合成，否则 RGB 转换会把 alpha 抹掉、变成实心色块。"""
    x, y = xy
    probe = ImageDraw.Draw(img)
    w = probe.textlength(text, font=fnt)
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle((x, y, x + w + 28, y + 34), 17, fill=(*color[:3], 38),
                         outline=(*color[:3], 120), width=1)
    img.alpha_composite(layer)
    ImageDraw.Draw(img).text((x + 14, y + 5), text, font=fnt, fill=(238, 243, 252))
    return int(x + w + 28)


def translucent_box(img: Image.Image, box: tuple[int, int, int, int], radius: int,
                    fill=(255, 255, 255, 10), outline=(255, 255, 255, 26)) -> None:
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(box, radius, fill=fill, outline=outline, width=1)
    img.alpha_composite(layer)


def hero_background() -> Image.Image:
    art = glob.glob(os.path.join(BRAND, "Abstract_dark_technology_backg*"))[0]
    img = Image.open(art).convert("RGB")
    # 裁掉底部水印区：只取上 60%。
    img = img.crop((0, 0, img.width, int(img.height * 0.60)))
    return fit_cover(img, (1600, 640))


def make_banner() -> None:
    img = hero_background().convert("RGBA")
    img.alpha_composite(horizontal_fade((1600, 640), (6, 9, 14, 236), 0.0, 0.66))
    img.alpha_composite(vertical_gradient((1600, 640), (0, 0, 0, 90), (0, 0, 0, 120)))

    icon = Image.open(os.path.join(BRAND, "icon-256.png")).convert("RGBA").resize((104, 104), Image.LANCZOS)
    img.alpha_composite(icon, (86, 84))

    draw = ImageDraw.Draw(img)
    draw.text((208, 84), "幻像工坊", font=font(64), fill=TEXT)
    spaced_text(draw, (212, 156), "PHANTOM  WORKSHOP", font(18), (128, 143, 168), 3)

    draw.text((88, 232), "微内核 · 插件化 · 时空可组合", font=font(32), fill=(220, 229, 243))
    draw.text((88, 280), "的节点式实时特效工坊", font=font(32), fill=(220, 229, 243))
    draw.text((88, 352), "39 个插件构成的工作台：节点即算子，帧即缓存，播放只读缓存。",
              font=font(19, False), fill=MUTED)

    x = 88
    for label, color in (("39 插件", VIOLET), ("77 节点", CYAN), ("播放 0 跳帧", (255, 190, 92))):
        x = pill(img, (x, 404), label, font(16, False), color) + 12

    draw = ImageDraw.Draw(img)
    draw.line((88, 486, 470, 486), fill=(255, 255, 255, 28), width=1)
    draw.text((88, 502), "Godot 4.7  ·  MIT License  ·  arXiv 2608.25512",
              font=font(15, False), fill=(120, 134, 158))
    img.convert("RGB").save(os.path.join(BRAND, "banner.jpg"), quality=90, optimize=True)
    print("ART banner.jpg 1600x640")


def make_social() -> None:
    img = hero_background().convert("RGBA")
    img.alpha_composite(horizontal_fade((1600, 640), (6, 9, 14, 240), 0.0, 0.70))
    icon = Image.open(os.path.join(BRAND, "icon-256.png")).convert("RGBA").resize((150, 150), Image.LANCZOS)
    img.alpha_composite(icon, (96, 96))
    draw = ImageDraw.Draw(img)
    draw.text((96, 286), "幻像工坊", font=font(88), fill=TEXT)
    spaced_text(draw, (102, 400), "PHANTOM  WORKSHOP", font(24), (130, 145, 172), 3)
    draw.text((96, 462), "可插拔的节点式实时特效工坊 · Godot 4.7", font=font(24, False), fill=MUTED)
    img.convert("RGB").resize((1280, 512), Image.LANCZOS).save(
        os.path.join(BRAND, "social-preview.jpg"), quality=90, optimize=True)
    print("ART social-preview.jpg 1280x512")


def make_plugins_card() -> None:
    img = hero_background().convert("RGBA")
    img.alpha_composite(horizontal_fade((1200, 675), (7, 10, 16, 242), 0.0, 0.78))
    # 右半边的亮节点会压住卡片文字，整体再压一层薄暗。
    img.alpha_composite(Image.new("RGBA", (1200, 675), (5, 8, 13, 64)))
    draw = ImageDraw.Draw(img)

    draw.text((76, 92), "一切能力都是插件", font=font(46), fill=TEXT)
    draw.text((78, 158), "基座只留 8.9k 行骨架；图语义、渲染、皮肤、面板、导出全在 plugins/ 里。",
              font=font(18, False), fill=MUTED)
    draw.text((78, 190), "停用一个插件，软件照常启动 —— 因为基座根本不认识它的类名。",
              font=font(18, False), fill=(126, 140, 165))

    items = [
        ("core.graph", "图语义 / 目录 / 端口", VIOLET),
        ("core.render", "渲染编排 / 帧缓存", CYAN),
        ("render.gpu", "compute 算子覆盖", (120, 180, 255)),
        ("editor.graph", "蓝图编辑器", (255, 170, 110)),
        ("editor.timeline", "时间轴与关键帧", (255, 210, 120)),
        ("editor.skin", "皮肤与布局", (190, 160, 255)),
    ]
    for i, (pid, desc, color) in enumerate(items):
        col, row = i % 2, i // 2
        x = 78 + col * 520
        y = 262 + row * 96
        translucent_box(img, (x, y, x + 486, y + 76), 16)
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse((x + 20, y + 30, x + 36, y + 46), fill=(*color, 235))
        img.alpha_composite(layer)
        draw = ImageDraw.Draw(img)
        draw.text((x + 50, y + 14), pid, font=font(21), fill=TEXT)
        draw.text((x + 50, y + 44), desc, font=font(15, False), fill=MUTED)
    img.convert("RGB").save(os.path.join(BRAND, "promo-plugins.jpg"), quality=90, optimize=True)
    print("ART promo-plugins.jpg 1200x675")


def make_gpu_card() -> None:
    art = glob.glob(os.path.join(BRAND, "Abstract_dark_technology_art*"))[0]
    base = fit_cover(Image.open(art).convert("RGB"), (1200, 675))
    img = base.convert("RGBA")
    img.alpha_composite(horizontal_fade((1200, 675), (6, 9, 15, 246), 0.0, 0.55))
    img.alpha_composite(Image.new("RGBA", (1200, 675), (5, 8, 13, 40)))
    draw = ImageDraw.Draw(img)

    draw.text((76, 104), "GPU 渲染服务器", font=font(48), fill=TEXT)
    draw.text((78, 176), "逐像素算子用 compute shader 覆盖，结果与 CPU 逐字节一致。",
              font=font(18, False), fill=MUTED)

    for i, (name, value, note) in enumerate((
        ("可分离模糊 r8", "6.4×", "43.6 → 6.8 ms"),
        ("六种混合 α.35", "14.6×", "54.0 → 3.7 ms"),
    )):
        y = 246 + i * 128
        draw.text((78, y), name, font=font(19, False), fill=MUTED)
        draw.text((78, y + 26), value, font=font(44), fill=CYAN)
        draw.text((238, y + 44), note, font=font(17, False), fill=(150, 200, 220))
    draw.text((78, 520), "RTX 3060 · 256×256 · 与 CPU 像素差 ≤ 0.0027", font=font(15, False),
              fill=(120, 140, 165))
    img.convert("RGB").save(os.path.join(BRAND, "promo-gpu.jpg"), quality=90, optimize=True)
    print("ART promo-gpu.jpg 1200x675")


def make_cache_card() -> None:
    img = Image.new("RGBA", (1200, 675), (7, 10, 16, 255))
    img.alpha_composite(vertical_gradient((1200, 675), (26, 22, 48, 255), (7, 10, 16, 255)))
    draw = ImageDraw.Draw(img)
    draw.text((72, 84), "帧级缓存 · 播放不跳帧", font=font(44), fill=TEXT)
    draw.text((74, 148), "紧密单文件 frames.fxc（64B 头 + 位图 + 定长 RGBA8），一次 seek 取一帧。",
              font=font(17, False), fill=MUTED)

    # 只取时间轴那一条：整窗缩略图看不清标尺上的帧刻度与色带。
    raw = Image.open(os.path.join(SHOTS, "03-timeline.png")).convert("RGB")
    strip = raw.crop((0, int(raw.height * 0.72), raw.width, int(raw.height * 0.995)))
    strip = strip.resize((1056, int(strip.height * 1056 / strip.width)), Image.LANCZOS)
    shot = strip
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width - 1, shot.height - 1), 16, 255)
    card = Image.new("RGBA", shot.size)
    card.paste(shot, (0, 0), mask)
    img.alpha_composite(with_shadow(card, 18, (0, 10), 150), (48, 196))

    draw = ImageDraw.Draw(img)
    draw.text((72, 430), "红 = 未算 · 黄 = 只有播放档垫图 · 绿 = 与导出一致的精确帧",
              font=font(17, False), fill=(160, 175, 198))
    draw.text((72, 466), "标尺上的颜色只反映事实：低质量预览永远不会冒充绿格。",
              font=font(17, False), fill=(120, 140, 165))
    x = 72
    for label, color in (("整段 60 帧 1.79 s", CYAN), ("读一帧 0.1 ms", VIOLET),
                         ("512 MB LRU 上限", (255, 190, 92))):
        x = pill(img, (x, 522), label, font(15, False), color) + 12
    img.convert("RGB").save(os.path.join(BRAND, "promo-cache.jpg"), quality=90, optimize=True)
    print("ART promo-cache.jpg 1200x675")


def make_ico() -> None:
    src = Image.open(os.path.join(BRAND, "icon-256.png")).convert("RGBA")
    src.save(os.path.join(ROOT, "icon.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("ART icon.ico")


if __name__ == "__main__":
    make_banner()
    make_social()
    make_plugins_card()
    make_gpu_card()
    make_cache_card()
    make_ico()
