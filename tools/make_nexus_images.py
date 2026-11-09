"""Nexus page images from the user's photo mode screenshots (art\\): the header banner (1400x400) and the primary
image (1920x1080), with the title in the setup video's style. Output: art\\nexus\\.

Usage (system Python with Pillow and numpy), from Apis-K0:  python tools\\make_nexus_images.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "art"
OUT = ART / "nexus"
FONT = "C:/Windows/Fonts/bahnschrift.ttf"
YELLOW = (243, 230, 0)
CYAN = (0, 229, 255)
WHITE = (236, 240, 244)

BANNER_SHOT = "photomode_09112026_160308.png"   # the drone close up
PRIMARY_SHOT = "photomode_09112026_144224.png"  # V with the drone on its hand


def font(size, variation="Bold"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(variation)
    return f


def shade(img, x_from, x_to, strength, side="right"):
    """Darkens the image towards one side (a horizontal gradient), so the text reads over the photo."""
    w, h = img.size
    ramp = np.clip((np.arange(w) - x_from) / max(1, x_to - x_from), 0, 1)
    if side == "left":
        ramp = 1 - np.clip((np.arange(w) - x_to) / max(1, x_from - x_to), 0, 1)
    ramp = ramp * ramp * (3 - 2 * ramp) * strength
    a = np.asarray(img.convert("RGB")).astype(np.float32)
    a *= (1 - ramp)[None, :, None]
    a += (np.array([6, 9, 14]) * ramp[:, None])[None, :, :]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def vignette(img, amount):
    w, h = img.size
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.sqrt(((xx - w / 2) / (w / 2)) ** 2 + ((yy - h / 2) / (h / 2)) ** 2)
    k = np.clip(1.08 - amount * r ** 2, 0.3, 1.0)[..., None]
    return Image.fromarray((np.asarray(img).astype(np.float32) * k).astype(np.uint8))


def scanlines(img, alpha=10):
    over = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    for y in range(0, img.size[1], 3):
        d.line([(0, y), (img.size[0], y)], fill=(0, 0, 0, alpha))
    out = img.convert("RGBA")
    out.alpha_composite(over)
    return out.convert("RGB")


def glow_text(img, xy, text, f, fill, anchor="la", glow=10):
    """Text with a soft glow of its own color behind it."""
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).text(xy, text, font=f, fill=fill + (150,), anchor=anchor)
    layer = layer.filter(ImageFilter.GaussianBlur(glow))
    out = img.convert("RGBA")
    out.alpha_composite(layer)
    ImageDraw.Draw(out).text(xy, text, font=f, fill=fill, anchor=anchor)
    return out.convert("RGB")


def title_block(img, x, y, scale, tagline, anchor_right=False):
    """APIKO / AI DRONE COMPANION / cyan rule / tagline, left- or right-aligned at x."""
    big, sub, small = font(int(170 * scale)), font(int(40 * scale), "SemiBold"), font(int(34 * scale), "Regular")
    a = "ra" if anchor_right else "la"
    img = glow_text(img, (x, y), "APIKO", big, YELLOW, a, glow=int(14 * scale))
    d = ImageDraw.Draw(img)
    y2 = y + int(178 * scale)
    d.text((x, y2), "AI  DRONE  COMPANION", font=sub, fill=CYAN, anchor=a)
    rule_w = sub.getlength("AI  DRONE  COMPANION")
    y3 = y2 + int(58 * scale)
    x0, x1 = (x - rule_w, x) if anchor_right else (x, x + rule_w)
    d.line([(x0, y3), (x1, y3)], fill=CYAN, width=max(2, int(3 * scale)))
    if tagline:
        d.text((x, y3 + int(22 * scale)), tagline, font=small, fill=WHITE, anchor=a)
    return img


def banner():
    src = Image.open(ART / BANNER_SHOT).convert("RGB")  # 2560x1440, drone near (1300, 760)
    crop = src.crop((620, 440, 2520, 983))  # 1900x543 = 3.5:1, drone at the left third
    img = crop.resize((1400, 400), Image.LANCZOS)
    img = shade(img, 520, 1050, 0.62)
    img = vignette(img, 0.25)
    img = title_block(img, 1360, 58, 0.62, "It sees. It remembers. It talks back.", anchor_right=True)
    return scanlines(img, 8)


def primary():
    src = Image.open(ART / PRIMARY_SHOT).convert("RGB")
    img = src.resize((1920, 1080), Image.LANCZOS)
    img = shade(img, 1160, 1700, 0.7)
    img = vignette(img, 0.22)
    img = title_block(img, 1860, 300, 1.0, "It sees. It remembers. It talks back.", anchor_right=True)
    d = ImageDraw.Draw(img)
    d.text((1860, 1030), "ALPHA 0.1  //  VOICE  //  MEMORY  //  LORE", font=font(26, "SemiBold"),
           fill=(170, 182, 194), anchor="rs")
    return scanlines(img, 8)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    banner().save(OUT / "banner_1400x400.png")
    primary().save(OUT / "primary_1920x1080.png")
    print(f"images: {OUT}")


if __name__ == "__main__":
    main()
