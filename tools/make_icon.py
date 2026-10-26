#!/usr/bin/env python3
"""Draws the Tennis Buddy app icon and writes it into the iOS/Mac and Watch asset catalogs.

    python3 tools/make_icon.py

Artwork: an optic-yellow racket on a court-green gradient, with a glowing "sensor ping" at the sweet spot.
"""
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 4                      # supersampling factor
N = 1024 * SS

YELLOW = (214, 242, 63)
DEEP = (11, 46, 34)
COURT = (27, 104, 70)
WHITE = (255, 255, 255)


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = min(1, max(0, (0.65 * y + 0.35 * x) / size))
            px[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return img


def racket_layer():
    """Racket drawn upright (tip up) on a transparent layer, rotated afterwards."""
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = N * 0.5, N * 0.37
    a, b = N * 0.215, N * 0.27              # head semi-axes (x, y)
    rim = N * 0.034

    # Strings, clipped to the head.
    strings = Image.new("L", (N, N), 0)
    sd = ImageDraw.Draw(strings)
    step = N * 0.036
    k = -6
    while k <= 6:
        x = cx + k * step
        sd.line([(x, cy - b), (x, cy + b)], fill=255, width=int(N * 0.006))
        y = cy + k * step
        sd.line([(cx - a, y), (cx + a, y)], fill=255, width=int(N * 0.006))
        k += 1
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).ellipse([cx - a, cy - b, cx + a, cy + b], fill=255)
    strings = Image.composite(strings, Image.new("L", (N, N), 0), mask)
    layer.paste(Image.new("RGBA", (N, N), WHITE + (120,)), (0, 0), strings.point(lambda v: v * 120 // 255))

    # Rim.
    d.ellipse([cx - a, cy - b, cx + a, cy + b], outline=YELLOW + (255,), width=int(rim))
    # Throat: two arms from the lower rim meeting the shaft.
    neck = cy + b + N * 0.075
    w = int(rim * 0.85)
    for side in (-1, 1):
        th = math.radians(28)
        start = (cx + side * (a - rim / 2) * math.sin(th), cy + (b - rim / 2) * math.cos(th))   # on the rim's centerline
        d.line([start, (cx, neck)], fill=YELLOW + (255,), width=w)
        d.ellipse([start[0] - w / 2, start[1] - w / 2, start[0] + w / 2, start[1] + w / 2], fill=YELLOW + (255,))
    # Handle, with a darker grip band and butt cap.
    hw = N * 0.052
    end = N * 0.985
    d.rounded_rectangle([cx - hw / 2, neck - N * 0.02, cx + hw / 2, end], radius=N * 0.016, fill=YELLOW + (255,))
    grip_top = neck + N * 0.06
    d.rounded_rectangle([cx - hw / 2 - N * 0.004, grip_top, cx + hw / 2 + N * 0.004, end - N * 0.012],
                        radius=N * 0.018, fill=(28, 36, 30, 255))
    y = grip_top + N * 0.02
    while y + N * 0.02 < end - N * 0.02:
        d.line([(cx - hw / 2 + N * 0.004, y), (cx + hw / 2 - N * 0.004, y + N * 0.018)],
               fill=(60, 74, 62, 255), width=int(N * 0.006))
        y += N * 0.04
    return layer, (cx, cy)


def ping_layer(center):
    """Glowing impact dot with pulse rings at the sweet spot."""
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = center
    for r, alpha, width in [(0.150, 70, 0.008), (0.105, 120, 0.010), (0.062, 190, 0.012)]:
        rr = N * r
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=WHITE + (alpha,), width=int(N * width))
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gr = N * 0.05
    ImageDraw.Draw(glow).ellipse([cx - gr, cy - gr, cx + gr, cy + gr], fill=YELLOW + (230,))
    glow = glow.filter(ImageFilter.GaussianBlur(N * 0.02))
    layer = Image.alpha_composite(layer, glow)
    d = ImageDraw.Draw(layer)
    r = N * 0.026
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE + (255,))
    return layer


def artwork():
    bg = gradient(N // 8, COURT, DEEP).resize((N, N), Image.BICUBIC).convert("RGBA")
    racket, center = racket_layer()
    angle = -32
    racket = racket.rotate(angle, resample=Image.BICUBIC, center=(N / 2, N / 2),
                           translate=(N * 0.035, -N * 0.035))
    # Where the sweet spot ended up after rotation.
    th = math.radians(-angle)
    dx, dy = center[0] - N / 2, center[1] - N / 2
    rc = (N / 2 + dx * math.cos(th) - dy * math.sin(th) + N * 0.035,
          N / 2 + dx * math.sin(th) + dy * math.cos(th) - N * 0.035)
    # Soft shadow under the racket.
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (0, 0), racket.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(N * 0.012))
    out = Image.alpha_composite(bg, shadow.transform((N, N), Image.AFFINE, (1, 0, -N * 0.01, 0, 1, -N * 0.016)))
    out = Image.alpha_composite(out, racket)
    out = Image.alpha_composite(out, ping_layer(rc))
    return out


def mac_icon(art):
    """macOS icons aren't masked by the system: rounded square with margin and shadow."""
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    inset = int(N * 0.098)
    size = N - 2 * inset
    tile = art.resize((size, size), Image.LANCZOS)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size, size], radius=int(size * 0.225), fill=255)
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + N * 0.012, inset + size, inset + size + N * 0.012],
                                             radius=int(size * 0.225), fill=(0, 0, 0, 90))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(N * 0.012)))
    canvas.paste(tile, (inset, inset), mask)
    return canvas


def main():
    art = artwork()
    final = art.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    mac = mac_icon(art).resize((1024, 1024), Image.LANCZOS)

    shared = os.path.join(ROOT, "apple/Shared/Assets.xcassets/AppIcon.appiconset")
    watch = os.path.join(ROOT, "apple/Watch/Assets.xcassets/AppIcon.appiconset")
    final.save(os.path.join(shared, "icon-1024.png"))
    final.save(os.path.join(watch, "icon-1024.png"))
    images = [{"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-1024.png"}]
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"mac-{pt}@{scale}x.png"
            mac.resize((pt * scale, pt * scale), Image.LANCZOS).save(os.path.join(shared, name))
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}", "filename": name})
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
              open(os.path.join(shared, "Contents.json"), "w"), indent=2)
    json.dump({"images": [{"idiom": "universal", "platform": "watchos", "size": "1024x1024", "filename": "icon-1024.png"}],
               "info": {"author": "xcode", "version": 1}}, open(os.path.join(watch, "Contents.json"), "w"), indent=2)
    final.save(os.path.join(ROOT, "docs/icon.png"))
    print("icons written")


if __name__ == "__main__":
    main()
