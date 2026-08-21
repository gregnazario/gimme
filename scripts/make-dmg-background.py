#!/usr/bin/env python3
"""Generates the DMG installer background (app/dmg-background[@2x].png).

Renders once at 1x (660x400, the Finder window size set by
scripts/package-mac.sh) and 2x for retina; package-mac.sh combines them into
a .tiff via tiffutil. Edit this script and re-run to restyle; the generated
PNGs are committed so packaging needs no Python.

Layout contract (icon size 96): Gimme.app at (132, 160), Applications at
(432, 160) — slots in the image are centered under those boxes.
"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 660, 400
SCALE = 2  # render at 2x, downsample for 1x

BG_TOP = (248, 249, 252)
BG_BOTTOM = (233, 236, 245)
ACCENT = (79, 70, 229)        # gimme indigo (#4F46E5)
ACCENT_SOFT = (79, 70, 229, 28)
SLOT_FILL = (255, 255, 255, 200)
SLOT_STROKE = (79, 70, 229, 70)
TEXT_PRIMARY = (30, 32, 40)
TEXT_SECONDARY = (100, 105, 120)


def font(size: int, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    candidates = [
        f"/System/Library/Fonts/SFNS{weight}.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def rounded(draw: ImageDraw.ImageDraw, box, radius, **kw):
    draw.rounded_rectangle(box, radius=radius, **kw)


def render(scale: int) -> Image.Image:
    img = Image.new("RGBA", (W * scale, H * scale))
    d = ImageDraw.Draw(img)

    # Vertical gradient background.
    for y in range(H * scale):
        t = y / (H * scale - 1)
        c = tuple(int(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
        d.line([(0, y), (W * scale, y)], fill=c + (255,))

    # Subtle radial glow behind the wordmark area.
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * scale // 2 - 210 * scale, -80 * scale,
                W * scale // 2 + 210 * scale, 200 * scale],
               fill=(79, 70, 229, 22))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(40 * scale)))
    d = ImageDraw.Draw(img)

    # Drop-zone slots (centered under the icon positions set in Finder).
    for cx in (180, 480):
        box = [(cx - 75) * scale, 133 * scale, (cx + 75) * scale, 283 * scale]
        # Shadow, then fill + stroke.
        shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
        sd = ImageDraw.Draw(shadow)
        rounded(sd, [box[0] + 2 * scale, box[1] + 4 * scale,
                     box[2] + 2 * scale, box[3] + 4 * scale],
                30 * scale, fill=(20, 25, 60, 26))
        img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(6 * scale)))
        d = ImageDraw.Draw(img)
        rounded(d, box, 30 * scale, fill=SLOT_FILL, outline=SLOT_STROKE, width=1 * scale)

    # Arrow from the app slot to the Applications slot (drawn on its own
    # layer so the drop shadow stays soft).
    arrow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    cy = 208 * scale
    shaft_y0, shaft_y1 = (cy - 14 * scale), (cy + 14 * scale)
    ad.rectangle([285 * scale, shaft_y0, 355 * scale, shaft_y1], fill=ACCENT)
    ad.polygon([(350 * scale, (cy - 34) * scale),
                (415 * scale, cy),
                (350 * scale, (cy + 34) * scale)], fill=ACCENT)
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rectangle([285 * scale + 2 * scale, shaft_y0 + 4 * scale,
                  355 * scale + 2 * scale, shaft_y1 + 4 * scale], fill=(20, 25, 60, 40))
    sd.polygon([(352 * scale, (cy - 30) * scale),
                (418 * scale, cy + 4 * scale),
                (352 * scale, (cy + 38) * scale)], fill=(20, 25, 60, 40))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(4 * scale)))
    img = Image.alpha_composite(img, arrow)
    d = ImageDraw.Draw(img)

    # Wordmark + hint. (Drawn after slots so the glow doesn't wash them.)
    title = "gimme"
    tf = font(46 * scale)
    tw = d.textlength(title, font=tf)
    d.text(((W * scale - tw) / 2, 36 * scale), title, font=tf, fill=TEXT_PRIMARY)
    hint = "Drag the app to Applications to install"
    hf = font(15 * scale)
    hw = d.textlength(hint, font=hf)
    d.text(((W * scale - hw) / 2, 96 * scale), hint, font=hf, fill=TEXT_SECONDARY)

    return img


if __name__ == "__main__":
    img2x = render(SCALE)
    img2x.save("app/dmg-background@2x.png")
    img1x = img2x.resize((W, H), Image.LANCZOS)
    img1x.save("app/dmg-background.png")
    print("wrote app/dmg-background.png (660x400) and app/dmg-background@2x.png (1320x800)")
