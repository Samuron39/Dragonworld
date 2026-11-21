"""Make the action bar icon from the guild logo.

usage: python make_button_icon.py <source image> <output folder> <preview png>

Writes button.tga (64x64, 32-bit, fully opaque): the dragon head cropped to a
square, the same head and centre as minimap.tga (make_icons.py) but filling the
whole square, the way a spell icon fills an action button. The addon lays it
over the macro's own icon on the action bar.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

src_path, out_dir, preview_path = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
out_dir.mkdir(parents=True, exist_ok=True)

src = Image.open(src_path).convert("RGB")
W, H = src.size
rgb = np.asarray(src).astype(np.int32)

# Background = dark pixels reachable from the border (same rule as make_icons.py).
DARK = 70
bright = (rgb.max(axis=2) >= DARK).astype(np.uint8) * 255
flood = Image.fromarray(bright, "L").copy()
for seed in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1), (W // 2, 0), (W // 2, H - 1), (0, H // 2), (W - 1, H // 2)]:
    if flood.getpixel(seed) == 0:
        ImageDraw.floodfill(flood, seed, 128)
background = np.asarray(flood) == 128

# The dragon head: the red part, not the gold frame.
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
red = (r > 100) & (r > 2.2 * g) & (r > 2.2 * b) & ~background
ys, xs = np.nonzero(red)
rx0, rx1, ry0, ry1 = xs.min(), xs.max(), ys.min(), ys.max()
hcx, hcy = (rx0 + rx1) / 2, (ry0 + ry1) / 2
half = 0.56 * (rx1 - rx0)                 # same size as the minimap circle
print(f"head centre ({hcx:.0f}, {hcy:.0f}), square side {2 * half:.0f}")

box = (int(hcx - half), int(hcy - half), int(hcx + half), int(hcy + half))
head = src.crop(box).convert("RGBA").resize((64, 64), Image.LANCZOS)

path = out_dir / "button.tga"
head.save(path, format="TGA", compression=None)
raw = path.read_bytes()
width, height = int.from_bytes(raw[12:14], "little"), int.from_bytes(raw[14:16], "little")
ok = raw[2] == 2 and raw[16] == 32 and width == 64 and height == 64 and len(raw) >= 18 + 64 * 64 * 4
same = np.array_equal(np.asarray(Image.open(path).convert("RGBA")), np.asarray(head))
print(f"button.tga: {width}x{height}, {raw[16]}-bit, header ok: {ok}, reads back identical: {same}")
if not (ok and same):
    sys.exit("FAIL: button.tga was not written correctly")

# Preview: large, and at action button size (36 px) blown up without smoothing.
sheet = Image.new("RGB", (256 + 36 * 6 + 30, 266), (60, 50, 40))
sheet.paste(head.resize((256, 256), Image.LANCZOS).convert("RGB"), (5, 5))
small = head.resize((36, 36), Image.LANCZOS).resize((36 * 6, 36 * 6), Image.NEAREST)
sheet.paste(small.convert("RGB"), (256 + 20, 25))
sheet.save(preview_path)
print("preview:", preview_path)
