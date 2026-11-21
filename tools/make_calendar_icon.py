"""Draw the small calendar icon used next to the date field in Guild Events.

usage: python make_calendar_icon.py <output folder> [preview png]

Writes calendar.tga (64x64, 32-bit, transparent background), the format and
power-of-two size the game needs.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

out_dir = Path(sys.argv[1])
preview = sys.argv[2] if len(sys.argv) > 2 else None

S = 8                      # draw 8x too large, then shrink for smooth edges
size = 64 * S
img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

outline = (35, 25, 15, 255)
paper = (242, 236, 222, 255)
red = (190, 45, 40, 255)
ink = (70, 60, 55, 255)

# The page, with a dark outline.
d.rounded_rectangle((5 * S, 9 * S, 59 * S, 60 * S), radius=7 * S, fill=outline)
d.rounded_rectangle((8 * S, 12 * S, 56 * S, 57 * S), radius=5 * S, fill=paper)

# The red band across the top.
d.rounded_rectangle((8 * S, 12 * S, 56 * S, 28 * S), radius=5 * S, fill=red)
d.rectangle((8 * S, 21 * S, 56 * S, 26 * S), fill=red)

# Two binder rings.
for x in (20, 44):
    d.rounded_rectangle(((x - 4) * S, 3 * S, (x + 4) * S, 19 * S), radius=4 * S, fill=outline)
    d.rounded_rectangle(((x - 2) * S, 5 * S, (x + 2) * S, 17 * S), radius=2 * S, fill=(215, 215, 220, 255))

# Days: three rows of four squares.
for row in range(3):
    for col in range(4):
        x0 = (13 + col * 10) * S
        y0 = (31 + row * 8) * S
        d.rounded_rectangle((x0, y0, x0 + 7 * S, y0 + 5 * S), radius=1 * S, fill=ink)

icon = img.convert("RGBa").resize((64, 64), Image.LANCZOS).convert("RGBA")
out_dir.mkdir(parents=True, exist_ok=True)
path = out_dir / "calendar.tga"
icon.save(path, format="TGA", compression=None)

raw = path.read_bytes()
width, height = int.from_bytes(raw[12:14], "little"), int.from_bytes(raw[14:16], "little")
ok = raw[2] == 2 and raw[16] == 32 and width == 64 and height == 64 and len(raw) >= 18 + 64 * 64 * 4
print(f"calendar.tga: {width}x{height}, {raw[16]}-bit, type {raw[2]}, {len(raw)} bytes, header ok: {ok}")
if not ok:
    sys.exit("FAIL: calendar.tga was not written correctly")

if preview:
    sheet = Image.new("RGBA", (64 * 4 + 24 * 6 + 60, 64 * 4 + 20), (30, 30, 34, 255))
    sheet.alpha_composite(icon.resize((256, 256), Image.NEAREST), (10, 10))
    small = icon.resize((24, 24), Image.LANCZOS)
    sheet.alpha_composite(small.resize((144, 144), Image.NEAREST), (286, 10))
    sheet.alpha_composite(small, (286, 180))
    sheet.convert("RGB").save(preview)
    print("preview:", preview)
