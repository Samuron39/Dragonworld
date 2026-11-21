"""Turn the guild logo into WoW textures.

usage: python make_icons.py <source image> <output folder> <preview png>

Writes two 32-bit TGA files (power-of-two sizes, as the game requires):
  icon.tga     128x128  whole shield, background made transparent  (addon list)
  minimap.tga   64x64   round crop of the dragon head              (minimap button)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

src_path, out_dir, preview_path = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
out_dir.mkdir(parents=True, exist_ok=True)

src = Image.open(src_path).convert("RGB")
W, H = src.size
rgb = np.asarray(src).astype(np.int32)
print(f"source: {W}x{H}")

# --- 1. Find the background: dark pixels reachable from the image border. -------
DARK = 70
bright = (rgb.max(axis=2) >= DARK).astype(np.uint8) * 255      # 255 = not background-coloured
flood = Image.fromarray(bright, "L").copy()   # copy: fromarray images are read-only, and floodfill then silently does nothing
filled = 0
for seed in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1), (W // 2, 0), (W // 2, H - 1), (0, H // 2), (W - 1, H // 2)]:
    if flood.getpixel(seed) == 0:
        ImageDraw.floodfill(flood, seed, 128)
        filled += 1
background = np.asarray(flood) == 128
if filled == 0 or background.mean() < 0.15:
    sys.exit(f"FAIL: background not found (seeds filled: {filled}, coverage {background.mean():.1%})")

# Leak check: the flood must not have got inside the shield.
core = background[H // 2 - 120:H // 2 + 120, W // 2 - 100:W // 2 + 100]
print(f"background covers {background.mean():.1%} of the image; leaked into the centre: {int(core.sum())} px")
if core.sum() > 0:
    sys.exit("FAIL: background flood leaked into the shield")

# The shield's black outline is as dark as the background, so the flood ate it.
# Grow the shield mask by the outline's width to take it back, then soften the edge.
shield = Image.fromarray((~background).astype(np.uint8) * 255, "L")
shield = shield.filter(ImageFilter.MaxFilter(11)).filter(ImageFilter.GaussianBlur(1.2))
bbox = shield.point(lambda v: 255 if v > 128 else 0).getbbox()
print(f"shield bounding box: {bbox}")

# --- 2. icon.tga: whole shield, square, small margin. ---------------------------
x0, y0, x1, y1 = bbox
side = int(max(x1 - x0, y1 - y0) * 1.04)
cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
box = (cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side)

rgba = src.convert("RGBA")
rgba.putalpha(shield)
# Crop may reach outside the image; paste onto a transparent square.
square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
square.paste(rgba, (-box[0], -box[1]))
# Resize with premultiplied alpha so the edge does not pick up a halo.
icon = square.convert("RGBa").resize((128, 128), Image.LANCZOS).convert("RGBA")

# --- 3. minimap.tga: the dragon head in a circle. -------------------------------
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
red = (r > 100) & (r > 2.2 * g) & (r > 2.2 * b) & ~background      # dragon red, not the gold frame
ys, xs = np.nonzero(red)
rx0, rx1, ry0, ry1 = xs.min(), xs.max(), ys.min(), ys.max()
print(f"dragon (red) bounding box: x {rx0}-{rx1}, y {ry0}-{ry1}")
hcx = (rx0 + rx1) / 2
hcy = (ry0 + ry1) / 2                    # the red part is the head; the neck below is brown
radius = 0.56 * (rx1 - rx0)              # just clears the head, stays inside the blue field
print(f"head circle: centre ({hcx:.0f}, {hcy:.0f}), radius {radius:.0f}")

SS = 4                                   # supersample the circle edge
d = int(round(radius * 2))
head = src.crop((int(hcx - radius), int(hcy - radius), int(hcx - radius) + d, int(hcy - radius) + d)).convert("RGBA")
circle = Image.new("L", (d * SS, d * SS), 0)
ImageDraw.Draw(circle).ellipse((0, 0, d * SS - 1, d * SS - 1), fill=255)
head.putalpha(circle.resize((d, d), Image.LANCZOS))
minimap = head.convert("RGBa").resize((64, 64), Image.LANCZOS).convert("RGBA")

# --- 4. Save as TGA and read back to confirm what was written. -------------------
for name, im in (("icon.tga", icon), ("minimap.tga", minimap)):
    path = out_dir / name
    im.save(path, format="TGA", compression=None)
    raw = path.read_bytes()
    width, height = int.from_bytes(raw[12:14], "little"), int.from_bytes(raw[14:16], "little")
    ok = (raw[2] == 2 and raw[16] == 32 and width == im.width and height == im.height
          and (width & (width - 1)) == 0 and (height & (height - 1)) == 0
          and len(raw) >= 18 + width * height * 4)
    again = Image.open(path).convert("RGBA")
    same = np.array_equal(np.asarray(again), np.asarray(im))
    alpha = np.asarray(im)[..., 3]
    print(f"{name}: {width}x{height}, {raw[16]}-bit, type {raw[2]}, {len(raw)} bytes, "
          f"transparent {np.mean(alpha < 8):.0%}, opaque {np.mean(alpha > 247):.0%}, "
          f"header ok: {ok}, reads back identical: {same}")
    if not (ok and same):
        sys.exit(f"FAIL: {name} was not written correctly")

# --- 5. Preview sheet: both textures on light and dark, large and at game size. --
def on(bg, im, size, resample=Image.LANCZOS):
    tile = Image.new("RGBA", (size, size), bg)
    scaled = im.convert("RGBa").resize((size, size), resample).convert("RGBA")
    tile.alpha_composite(scaled)
    return tile

sheet = Image.new("RGBA", (4 * 266 + 10, 2 * 266 + 10), (90, 90, 90, 255))
cells = [
    (icon, (235, 235, 235, 255), 256), (icon, (25, 25, 30, 255), 256),
    (minimap, (235, 235, 235, 255), 256), (minimap, (25, 25, 30, 255), 256),
]
for i, (im, bg, size) in enumerate(cells):
    sheet.paste(on(bg, im, size), (10 + i * 266, 10))
# Bottom row: actual in-game sizes, blown up 8x without smoothing to see the pixels.
small = [(icon, 32), (icon, 20), (minimap, 18), (minimap, 18)]
for i, (im, size) in enumerate(small):
    bg = (60, 50, 40, 255) if i < 3 else (235, 235, 235, 255)
    tiny = on(bg, im, size)
    big = tiny.resize((size * 8, size * 8), Image.NEAREST)
    sheet.paste(big, (10 + i * 266, 276))
sheet.convert("RGB").save(preview_path)
print("preview:", preview_path)
