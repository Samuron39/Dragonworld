// Makes the textures of the Tactics board: Dragonworld/Media/Tactics/*.tga.
//
//   node tools/make_tactics_art.js [preview folder]
//
// Everything is drawn here from simple shapes, so the art can be changed and
// made again without an image program. With a preview folder, PNG copies are
// written there too (enlarged, on a background), plus board.png: a rough
// picture of how the pieces look together on a board 720 wide.
//
// The files are 32-bit uncompressed TGA with power-of-two sizes, which is what
// the game reads. White art is coloured by the addon (SetVertexColor).
//
// GLYPHS below must be in the same order as GLYPHS in
// Dragonworld/Modules/TacticsBoard.lua: the script stops if they differ.

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const OUT = path.join(__dirname, "..", "Dragonworld", "Media", "Tactics");
const BOARD_LUA = path.join(__dirname, "..", "Dragonworld", "Modules", "TacticsBoard.lua");
const PREVIEW = process.argv[2];

// Pictures ---------------------------------------------------------------------

// A picture: straight (not premultiplied) RGBA, each 0..1.
function image(w, h) {
  return { w, h, d: new Float32Array(w * h * 4) };
}

// Fills a picture from fn(x, y) -> [r, g, b, a], asked several times per pixel
// so edges come out smooth. Pixels that end up fully transparent keep the
// colour of their samples: the game blends neighbouring pixels when it scales
// a texture, and a black transparent edge would show as a dark fringe.
function render(w, h, fn, samples = 6) {
  const img = image(w, h);
  for (let py = 0; py < h; py++) {
    for (let px = 0; px < w; px++) {
      let a = 0, r = 0, g = 0, b = 0, r0 = 0, g0 = 0, b0 = 0;
      for (let sy = 0; sy < samples; sy++) {
        for (let sx = 0; sx < samples; sx++) {
          const c = fn(px + (sx + 0.5) / samples, py + (sy + 0.5) / samples);
          a += c[3]; r += c[0] * c[3]; g += c[1] * c[3]; b += c[2] * c[3];
          r0 += c[0]; g0 += c[1]; b0 += c[2];
        }
      }
      const n = samples * samples, i = (py * w + px) * 4;
      if (a > 0) { img.d[i] = r / a; img.d[i + 1] = g / a; img.d[i + 2] = b / a; }
      else { img.d[i] = r0 / n; img.d[i + 1] = g0 / n; img.d[i + 2] = b0 / n; }
      img.d[i + 3] = a / n;
    }
  }
  return img;
}

const byte = (v) => Math.max(0, Math.min(255, Math.round(v * 255)));

// 32-bit uncompressed TGA, rows from the bottom up (the same layout as the
// addon's other .tga files).
function writeTga(file, img) {
  const head = Buffer.alloc(18);
  head[2] = 2;
  head.writeUInt16LE(img.w, 12);
  head.writeUInt16LE(img.h, 14);
  head[16] = 32;
  head[17] = 8;
  const body = Buffer.alloc(img.w * img.h * 4);
  for (let y = 0; y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const s = ((img.h - 1 - y) * img.w + x) * 4, t = (y * img.w + x) * 4;
      body[t] = byte(img.d[s + 2]);
      body[t + 1] = byte(img.d[s + 1]);
      body[t + 2] = byte(img.d[s]);
      body[t + 3] = byte(img.d[s + 3]);
    }
  }
  const foot = Buffer.concat([Buffer.alloc(8), Buffer.from("TRUEVISION-XFILE.\0", "latin1")]);
  fs.writeFileSync(file, Buffer.concat([head, body, foot]));
}

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function writePng(file, img) {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(img.w, 0); ihdr.writeUInt32BE(img.h, 4);
  ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc((img.w * 4 + 1) * img.h);
  for (let y = 0; y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const s = (y * img.w + x) * 4, t = y * (img.w * 4 + 1) + 1 + x * 4;
      for (let k = 0; k < 4; k++) raw[t + k] = byte(img.d[s + k]);
    }
  }
  fs.writeFileSync(file, Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]));
}

// Shapes -------------------------------------------------------------------------

// A shape is a function (x, y) -> distance to its edge, negative inside.
// y points down, as in the picture.

function distSeg(x, y, x0, y0, x1, y1) {
  const dx = x1 - x0, dy = y1 - y0, len = dx * dx + dy * dy;
  let t = len > 0 ? ((x - x0) * dx + (y - y0) * dy) / len : 0;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(x - x0 - t * dx, y - y0 - t * dy);
}
const circle = (cx, cy, r) => (x, y) => Math.hypot(x - cx, y - cy) - r;
const box = (cx, cy, hx, hy, rad = 0) => (x, y) => {
  const dx = Math.abs(x - cx) - (hx - rad), dy = Math.abs(y - cy) - (hy - rad);
  return Math.hypot(Math.max(dx, 0), Math.max(dy, 0)) + Math.min(Math.max(dx, dy), 0) - rad;
};
const poly = (pts) => (x, y) => {
  let d = Infinity, inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j];
    d = Math.min(d, distSeg(x, y, xi, yi, xj, yj));
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside ? -d : d;
};
// A line through points, w wide, with round ends and joints.
const stroke = (pts, w, closed = false) => (x, y) => {
  let d = Infinity;
  const n = closed ? pts.length : pts.length - 1;
  for (let i = 0; i < n; i++) {
    const a = pts[i], b = pts[(i + 1) % pts.length];
    d = Math.min(d, distSeg(x, y, a[0], a[1], b[0], b[1]));
  }
  return d - w / 2;
};
const seg = (x0, y0, x1, y1, w) => stroke([[x0, y0], [x1, y1]], w);
const union = (...s) => (x, y) => Math.min(...s.map((f) => f(x, y)));
const cut = (a, ...b) => (x, y) => Math.max(a(x, y), ...b.map((f) => -f(x, y)));
const both = (a, b) => (x, y) => Math.max(a(x, y), b(x, y));
const grow = (a, r) => (x, y) => a(x, y) - r;
const move = (a, dx, dy) => (x, y) => a(x - dx, y - dy);
const scale = (a, k) => (x, y) => a(x / k, y / k) * k;
// Turns a shape clockwise (as seen in the picture) around 0,0.
const turn = (a, deg) => {
  const c = Math.cos((deg * Math.PI) / 180), s = Math.sin((deg * Math.PI) / 180);
  return (x, y) => a(x * c + y * s, -x * s + y * c);
};
const turnPoint = ([x, y], deg) => {
  const c = Math.cos((deg * Math.PI) / 180), s = Math.sin((deg * Math.PI) / 180);
  return [x * c - y * s, x * s + y * c];
};
// Points along a circle from a0 to a1 degrees (0 = right, 90 = down).
function arcPoints(cx, cy, r, a0, a1, n = 24) {
  const pts = [];
  for (let i = 0; i <= n; i++) {
    const a = ((a0 + ((a1 - a0) * i) / n) * Math.PI) / 180;
    pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
  }
  return pts;
}
// Points along a cubic Bezier curve (the end point is left out, so curves chain).
function curve(p0, p1, p2, p3, n = 12) {
  const pts = [];
  for (let i = 0; i < n; i++) {
    const t = i / n, u = 1 - t;
    pts.push([
      u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
      u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    ]);
  }
  return pts;
}

// Glyphs -------------------------------------------------------------------------

// The icons of the markers: white, drawn in a square from -1 to 1. The addon
// colours them. They are shown about 20 to 30 pixels big, so they are bold
// and simple.

const sword = union(
  poly([[-0.155, 0.26], [-0.155, -0.58], [0, -0.97], [0.155, -0.58], [0.155, 0.26]]),
  box(0, 0.33, 0.42, 0.1, 0.05),
  box(0, 0.6, 0.095, 0.24),
  circle(0, 0.86, 0.15)
);

const shieldPoints = [
  [-0.66, -0.62], [0, -0.78], [0.66, -0.62],
  ...curve([0.66, -0.62], [0.68, 0.1], [0.52, 0.56], [0, 0.9]),
  ...curve([0, 0.9], [-0.52, 0.56], [-0.68, 0.1], [-0.66, -0.62]),
];
const shield = poly(shieldPoints);

const star4 = poly([[0, -1], [0.2, -0.2], [1, 0], [0.2, 0.2], [0, 1], [-0.2, 0.2], [-1, 0], [-0.2, -0.2]]);

const person = union(circle(0, -0.42, 0.32), both(circle(0, 0.95, 0.82), box(0, 0.3, 1, 0.42)));

// An arrow along the y axis from y = tail to its tip at y = tip (up or down).
const arrowY = (tail, tip, head = 0.32, w = 0.2) => {
  const back = tip + (tail < tip ? -1 : 1) * head * 1.25;
  return union(seg(0, tail, 0, back, w), poly([[0, tip], [-head, back], [head, back]]));
};

const flame = (() => {
  const outer = poly([
    ...curve([0, 0.9], [-0.42, 0.9], [-0.68, 0.6], [-0.66, 0.24]),
    ...curve([-0.66, 0.24], [-0.64, -0.06], [-0.46, -0.2], [-0.4, -0.44]),
    ...curve([-0.4, -0.44], [-0.3, -0.26], [-0.26, -0.2], [-0.16, -0.14]),
    ...curve([-0.16, -0.14], [-0.2, -0.5], [-0.04, -0.76], [0.2, -0.95]),
    ...curve([0.2, -0.95], [0.14, -0.6], [0.36, -0.44], [0.5, -0.2]),
    ...curve([0.5, -0.2], [0.64, 0.02], [0.7, 0.2], [0.66, 0.36]),
    ...curve([0.66, 0.36], [0.6, 0.7], [0.36, 0.9], [0, 0.9]),
  ]);
  const inner = poly([
    ...curve([0.02, 0.9], [-0.24, 0.88], [-0.34, 0.64], [-0.26, 0.44]),
    ...curve([-0.26, 0.44], [-0.2, 0.28], [-0.04, 0.22], [0.04, 0.02]),
    ...curve([0.04, 0.02], [0.12, 0.24], [0.3, 0.34], [0.32, 0.56]),
    ...curve([0.32, 0.56], [0.34, 0.76], [0.2, 0.9], [0.02, 0.9]),
  ]);
  return cut(outer, inner);
})();

const snowflake = (() => {
  const parts = [];
  for (let i = 0; i < 6; i++) {
    const a = i * 60;
    const p = (r, da = 0) => turnPoint([0, -r], a + da);
    parts.push(stroke([[0, 0], p(0.92)], 0.15));
    const base = p(0.5);
    for (const side of [-1, 1]) {
      const tip = turnPoint([0, -0.3], a + side * 52);
      parts.push(stroke([base, [base[0] + tip[0], base[1] + tip[1]]], 0.13));
    }
  }
  return union(...parts);
})();

const spiral = (() => {
  const pts = [];
  for (let i = 0; i <= 60; i++) {
    const t = i / 60, a = t * Math.PI * 2 * 1.6 - 0.6, r = 0.1 + 0.72 * t;
    pts.push([r * Math.cos(a), r * Math.sin(a)]);
  }
  return union(stroke(pts, 0.2), circle(0, 0, 0.17));
})();

const swap = (() => {
  // Two bent arrows chasing each other round a circle.
  const half = (deg) => {
    const pts = arcPoints(0, 0, 0.6, 200, 325, 16);
    const end = pts[pts.length - 1];
    const head = poly([[0.3, 0], [-0.16, -0.33], [-0.16, 0.33]]);
    return turn(union(stroke(pts, 0.19), move(turn(head, 325 + 90), end[0], end[1])), deg);
  };
  return union(half(0), half(180));
})();

const GLYPHS = [
  // enemies
  ["boss", cut(
    union(circle(0, -0.18, 0.66), box(0, 0.46, 0.38, 0.34, 0.12)),
    circle(-0.28, -0.14, 0.2), circle(0.28, -0.14, 0.2),
    poly([[0, 0.12], [-0.11, 0.34], [0.11, 0.34]]),
    box(-0.15, 0.68, 0.035, 0.16), box(0.15, 0.68, 0.035, 0.16)
  )],
  ["add", cut(
    union(
      circle(0, 0.2, 0.56),
      poly([[-0.5, 0.0], [-0.86, -0.86], [-0.1, -0.3]]),
      poly([[0.5, 0.0], [0.86, -0.86], [0.1, -0.3]])
    ),
    seg(-0.36, 0.06, -0.12, 0.2, 0.15), seg(0.36, 0.06, 0.12, 0.2, 0.15),
    stroke([[-0.24, 0.5], [-0.08, 0.42], [0.08, 0.5], [0.24, 0.42]], 0.09)
  )],
  // roles
  ["tank", union(cut(shield, scale(shield, 0.72)), move(scale(shield, 0.46), 0, 0.01))],
  ["heal", union(box(0, 0, 0.28, 0.8, 0.08), box(0, 0, 0.8, 0.28, 0.08))],
  ["dps", turn(sword, 45)],
  ["melee", union(turn(sword, 45), turn(sword, -45))],
  ["ranged", turn(union(
    stroke(arcPoints(-0.6, 0, 1.0, -56, 56), 0.2),
    seg(-0.04, -0.83, -0.04, 0.83, 0.09),
    seg(-0.8, 0, 0.6, 0, 0.14),
    poly([[1.0, 0], [0.5, -0.26], [0.5, 0.26]]),
    poly([[-0.98, -0.24], [-0.62, 0], [-0.98, 0.24], [-0.78, 0]])
  ), -45)],
  // spots
  ["stack", union(...[0, 90, 180, 270].map((a) => turn(arrowY(-0.94, -0.1), a)))],
  ["spread", union(circle(0, 0, 0.15), ...[45, 135, 225, 315].map((a) => turn(arrowY(-0.3, -1.0), a)))],
  ["safe", stroke([[-0.66, 0.06], [-0.22, 0.52], [0.7, -0.5]], 0.3)],
  ["danger", union(
    stroke([[0, -0.76], [0.82, 0.64], [-0.82, 0.64]], 0.2, true),
    seg(0, -0.26, 0, 0.14, 0.19), circle(0, 0.4, 0.11)
  )],
  ["fire", flame],
  ["frost", snowflake],
  ["poison", union(
    cut(
      union(circle(-0.08, 0.34, 0.5), poly([[-0.08, -0.86], [-0.5346, 0.1317], [0.3746, 0.1317]])),
      stroke(arcPoints(-0.08, 0.34, 0.3, 100, 165, 8), 0.1)
    ),
    circle(0.62, -0.5, 0.15), circle(0.72, 0.02, 0.1)
  )],
  ["void", spiral],
  ["bolt", poly([[-0.06, -0.94], [0.46, -0.94], [0.14, -0.2], [0.5, -0.2], [-0.3, 0.96], [-0.04, 0.1], [-0.46, 0.1]])],
  ["interrupt", union(cut(circle(0, 0, 0.9), circle(0, 0, 0.68)), seg(-0.54, -0.54, 0.54, 0.54, 0.22))],
  ["dispel", union(move(scale(star4, 0.8), -0.16, 0.14), move(scale(star4, 0.36), 0.6, -0.6))],
  ["move", union(
    stroke([[-0.72, -0.62], [-0.14, 0], [-0.72, 0.62]], 0.28),
    stroke([[-0.02, -0.62], [0.56, 0], [-0.02, 0.62]], 0.28)
  )],
  ["swap", swap],
  ["bomb", union(
    cut(circle(-0.12, 0.26, 0.6), stroke(arcPoints(-0.12, 0.26, 0.38, 185, 245, 8), 0.1)),
    seg(0.26, -0.2, 0.42, -0.4, 0.3),
    stroke([[0.44, -0.44], [0.56, -0.66], [0.72, -0.72]], 0.1),
    move(scale(star4, 0.24), 0.78, -0.76)
  )],
  ["eye", union(
    cut(both(circle(0, 0.62, 1.06), circle(0, -0.62, 1.06)), circle(0, 0, 0.34)),
    circle(0, 0, 0.17)
  )],
  ["flag", union(
    seg(-0.5, -0.88, -0.5, 0.9, 0.15),
    poly([[-0.46, -0.86], [0.78, -0.44], [-0.46, -0.02]])
  )],
  // not in the palette: an unknown marker, a player of unknown class, a raid group
  ["plain", union(circle(0, 0, 0.3), cut(circle(0, 0, 0.74), circle(0, 0, 0.56)))],
  ["person", person],
  ["group", union(
    cut(
      union(move(scale(person, 0.62), -0.5, -0.14), move(scale(person, 0.62), 0.5, -0.14)),
      grow(move(scale(person, 0.8), 0, 0.16), 0.1)
    ),
    move(scale(person, 0.8), 0, 0.16)
  )],
];

const CELL = 32;        // pixels per glyph
const COLUMNS = 8;
const GLYPH_SCALE = 13.5; // pixels per glyph unit: leaves a clear edge around each one

function glyphAtlas() {
  const w = 256, h = 128;
  if (GLYPHS.length > COLUMNS * (h / CELL)) throw new Error("too many glyphs for the atlas");
  return render(w, h, (x, y) => {
    const col = Math.floor(x / CELL), row = Math.floor(y / CELL);
    const glyph = GLYPHS[row * COLUMNS + col];
    if (!glyph) return [1, 1, 1, 0];
    const gx = (x - (col + 0.5) * CELL) / GLYPH_SCALE, gy = (y - (row + 0.5) * CELL) / GLYPH_SCALE;
    // Nothing may reach the cell's edge, or it would bleed into its neighbour.
    if (Math.abs(gx) > 1.1 || Math.abs(gy) > 1.1) return [1, 1, 1, 0];
    return [1, 1, 1, glyph[1](gx, gy) < 0 ? 1 : 0];
  });
}

// The same list must be in TacticsBoard.lua, since the addon finds a glyph by
// its place in the atlas.
function checkGlyphOrder() {
  const lua = fs.readFileSync(BOARD_LUA, "utf8");
  const block = lua.match(/local GLYPHS = \{([\s\S]*?)\n\}/);
  if (!block) {
    console.log("note: no GLYPHS list in TacticsBoard.lua yet; it must be:\n  " + GLYPHS.map((g) => `"${g[0]}"`).join(", "));
    return;
  }
  const names = [...block[1].matchAll(/"([a-z0-9]+)"/g)].map((m) => m[1]);
  const mine = GLYPHS.map((g) => g[0]);
  if (names.join(",") !== mine.join(",")) {
    throw new Error("GLYPHS differ.\n  TacticsBoard.lua: " + names.join(", ") + "\n  this script:      " + mine.join(", "));
  }
}

// Pieces -------------------------------------------------------------------------

const CLEAR = [1, 1, 1, 0];
const white = (shape) => (x, y) => (shape(x, y) < 0 ? [1, 1, 1, 1] : CLEAR);

// The round token under a marker: a black outline, a white rim that takes the
// marker's colour, and a dark middle that stays dark when coloured.
function token() {
  return render(64, 64, (x, y) => {
    const d = Math.hypot(x - 32, y - 32);
    if (d < 24.5) {
      let g = 0.2 - 0.07 * ((y - 32) / 24.5);
      if (d > 22.5) g *= 0.6;
      return [g, g, g * 1.08, 1];
    }
    if (d < 29.5) return d < 27.5 ? [1, 1, 1, 1] : [0.8, 0.8, 0.8, 1];
    if (d < 31) return [0, 0, 0, 0.9];
    return [0, 0, 0, 0];
  });
}

// A ring with a faint halo: the selection ring and the ping.
function ring() {
  return render(64, 64, (x, y) => {
    const d = Math.hypot(x - 32, y - 32);
    const halo = 0.45 * Math.exp(-(((d - 27.5) / 3.2) ** 2));
    return [1, 1, 1, d > 25.5 && d < 29.5 ? 1 : d < 31.5 ? halo : 0];
  });
}

// A soft glow, brightest in the middle: lies under an item that is "mine".
function glow() {
  return render(32, 32, (x, y) => {
    const t = Math.max(0, Math.min(1, (Math.hypot(x - 16, y - 16) - 7.5) / 8));
    return [1, 1, 1, (1 - t) ** 1.5];
  }, 4);
}

// An arrowhead pointing right. It stays inside the circle that fits the
// square, so it is whole whichever way the game turns it.
function arrow() {
  return render(64, 64, white(poly([[61, 32], [15, 8], [25, 32], [15, 56]])));
}

const dot = () => render(32, 32, white(circle(16, 16, 14)));

// The large disc is also the mask that cuts a floor round. A mask may be read
// from the colour or from the transparency, so here the two say the same:
// white and solid inside, black and clear outside.
function disc() {
  const img = render(128, 128, white(circle(64, 64, 62)));
  for (let i = 0; i < img.d.length; i += 4) img.d[i] = img.d[i + 1] = img.d[i + 2] = img.d[i + 3];
  return img;
}

// What a line is drawn with: even along the line, fading out across it, so
// lines at any angle get smooth edges. The larger one has a narrower fade,
// for thick lines.
function lineTexture(size) {
  const img = image(size, size);
  for (let y = 0; y < size; y++) {
    const a = y === 0 || y === size - 1 ? 0 : y === 1 || y === size - 2 ? 0.5 : 1;
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      img.d[i] = img.d[i + 1] = img.d[i + 2] = 1;
      img.d[i + 3] = a;
    }
  }
  return img;
}

// Repeatable random numbers, so the art is the same every time it is made.
function hash(a, b, seed) {
  let h = (a * 374761393 + b * 668265263 + seed * 2147483647) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967295;
}
// Smooth noise that repeats every `period` cells, so the texture tiles.
function noise(x, y, cell, period, seed) {
  const gx = x / cell, gy = y / cell, x0 = Math.floor(gx), y0 = Math.floor(gy);
  const fx = gx - x0, fy = gy - y0;
  const sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
  const at = (ix, iy) => hash(((ix % period) + period) % period, ((iy % period) + period) % period, seed);
  const top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx;
  const bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx;
  return top + (bottom - top) * sy;
}

// A stone floor: slabs in four rows, light, so the addon can colour it. The
// pattern is kept faint: the markers on top are what must be read.
const SLAB_ROWS = [
  [0, 48, 96],
  [20, 62, 108],
  [0, 40, 74],
  [30, 86],
];
function floorTile() {
  const size = 128, rowH = 32;
  return render(size, size, (x, y) => {
    const row = Math.floor(y / rowH) % SLAB_ROWS.length;
    const starts = SLAB_ROWS[row];
    let index = starts.length - 1, left = starts[index] - size;
    for (let i = 0; i < starts.length; i++) {
      if (x >= starts[i]) { index = i; left = starts[i]; }
    }
    const right = starts[(index + 1) % starts.length] + (index + 1 === starts.length ? size : 0) - (left < 0 ? size : 0);
    const top = row * rowH;
    // how far inside the slab this point is
    const edge = Math.min(x - left, right - x, y - top, top + rowH - y);
    let v = 0.84 + 0.1 * hash(index, row, 7);
    v += 0.05 * (noise(x, y, 16, 8, 3) - 0.5) + 0.035 * (noise(x, y, 4, 32, 5) - 0.5);
    if (edge < 0.9) v = 0.6;
    else if (edge < 2.2) v -= (y - top < 2.2 || x - left < 2.2) ? -0.04 : 0.07;
    const warm = 0.012 * (hash(index, row, 11) - 0.5);
    return [v + warm, v, v - warm, 1];
  }, 3);
}

// Rough rock and bare ground: soft blotches, light, coloured by the addon.
function rockTile() {
  const size = 64;
  return render(size, size, (x, y) => {
    const v = 0.74 + 0.22 * (noise(x, y, 16, 4, 21) - 0.5) + 0.16 * (noise(x, y, 8, 8, 22) - 0.5)
      + 0.1 * (noise(x, y, 4, 16, 23) - 0.5) + 0.06 * (hash(Math.floor(x), Math.floor(y), 24) - 0.5);
    return [v, v, v, 1];
  }, 2);
}

// Previews -----------------------------------------------------------------------

// The picture enlarged on a chequered background, to see the transparent parts.
function onBackground(img, zoom, dark) {
  return render(img.w * zoom, img.h * zoom, (x, y) => {
    const sx = Math.floor(x / zoom), sy = Math.floor(y / zoom), i = (sy * img.w + sx) * 4;
    const check = (Math.floor(x / 8) + Math.floor(y / 8)) % 2 ? 0.34 : 0.42;
    const bg = dark ? 0.13 : check;
    const a = img.d[i + 3];
    return [img.d[i] * a + bg * (1 - a), img.d[i + 1] * a + bg * (1 - a), img.d[i + 2] * a + bg * (1 - a), 1];
  }, 1);
}

// A small painter that works the way the game draws: textures stretched,
// turned and coloured, one on top of the other.
function canvas(w, h) {
  const img = image(w, h);
  for (let i = 3; i < img.d.length; i += 4) img.d[i] = 1;
  const sample = (tex, u, v, repeat) => {
    let x = u * tex.w - 0.5, y = v * tex.h - 0.5;
    const x0 = Math.floor(x), y0 = Math.floor(y), fx = x - x0, fy = y - y0;
    const at = (ix, iy) => {
      if (repeat) { ix = ((ix % tex.w) + tex.w) % tex.w; iy = ((iy % tex.h) + tex.h) % tex.h; }
      else { ix = Math.max(0, Math.min(tex.w - 1, ix)); iy = Math.max(0, Math.min(tex.h - 1, iy)); }
      return (iy * tex.w + ix) * 4;
    };
    const out = [0, 0, 0, 0], i00 = at(x0, y0), i10 = at(x0 + 1, y0), i01 = at(x0, y0 + 1), i11 = at(x0 + 1, y0 + 1);
    for (let k = 0; k < 4; k++) {
      out[k] = (tex.d[i00 + k] * (1 - fx) + tex.d[i10 + k] * fx) * (1 - fy) + (tex.d[i01 + k] * (1 - fx) + tex.d[i11 + k] * fx) * fy;
    }
    return out;
  };
  const put = (px, py, c, a) => {
    if (px < 0 || py < 0 || px >= w || py >= h || a <= 0) return;
    const i = (py * w + px) * 4;
    for (let k = 0; k < 3; k++) img.d[i + k] = c[k] * a + img.d[i + k] * (1 - a);
  };
  const api = {
    img,
    // tex centred on cx, cy, size by size, turned `rot` radians anticlockwise
    tex(tex, cx, cy, size, tint = [1, 1, 1], alpha = 1, rot = 0, cell) {
      const half = size / 2 + 1, c = Math.cos(rot), s = Math.sin(rot);
      for (let py = Math.floor(cy - half * 1.5); py <= cy + half * 1.5; py++) {
        for (let px = Math.floor(cx - half * 1.5); px <= cx + half * 1.5; px++) {
          const dx = px + 0.5 - cx, dy = py + 0.5 - cy;
          let u = (dx * c - dy * s) / size + 0.5, v = (dx * s + dy * c) / size + 0.5;
          if (u < 0 || u > 1 || v < 0 || v > 1) continue;
          if (cell) { u = cell[0] + u * (cell[1] - cell[0]); v = cell[2] + v * (cell[3] - cell[2]); }
          const t = sample(tex, u, v, false);
          put(px, py, [t[0] * tint[0], t[1] * tint[1], t[2] * tint[2]], t[3] * alpha);
        }
      }
    },
    // a repeating texture inside a shape (the shape's edge blurred as a 128 px mask would be)
    tiled(tex, shape, tilePixels, tint, blur = 0.5) {
      for (let py = 0; py < h; py++) {
        for (let px = 0; px < w; px++) {
          const d = shape(px + 0.5, py + 0.5);
          if (d > blur) continue;
          const t = sample(tex, (px + 0.5) / tilePixels, (py + 0.5) / tilePixels, true);
          put(px, py, [t[0] * tint[0], t[1] * tint[1], t[2] * tint[2]], Math.min(1, (blur - d) / (2 * blur)));
        }
      }
    },
    fill(shape, tint, alpha = 1) {
      for (let py = 0; py < h; py++) {
        for (let px = 0; px < w; px++) {
          const d = shape(px + 0.5, py + 0.5);
          if (d < 0.5) put(px, py, tint, alpha * Math.min(1, 0.5 - d));
        }
      }
    },
    // a line as the game draws it with the soft line texture
    line(x0, y0, x1, y1, thick, tint, alpha = 1) {
      const nominal = thick / 0.72, len = Math.hypot(x1 - x0, y1 - y0);
      if (len < 0.01) return;
      const ux = (x1 - x0) / len, uy = (y1 - y0) / len;
      const lo = [Math.min(x0, x1) - nominal, Math.min(y0, y1) - nominal], hi = [Math.max(x0, x1) + nominal, Math.max(y0, y1) + nominal];
      for (let py = Math.floor(lo[1]); py <= hi[1]; py++) {
        for (let px = Math.floor(lo[0]); px <= hi[0]; px++) {
          const dx = px + 0.5 - x0, dy = py + 0.5 - y0;
          const along = dx * ux + dy * uy, across = Math.abs(-dx * uy + dy * ux);
          if (along < 0 || along > len) continue;
          const a = Math.max(0, Math.min(1, (nominal / 2 - across) / (nominal * 0.14)));
          put(px, py, tint, a * alpha);
        }
      }
    },
  };
  return api;
}

// A rough picture of a board 720 wide: a round room with a pit, markers,
// an arrow, a drawn line and an area. Not what the addon draws line for line,
// but the same textures, sizes and colours.
function boardPreview(art, room) {
  const W = 720, H = 450, s = W / 1000;
  const c = canvas(W, H);
  const GOLD = [0.86, 0.69, 0.27], EDGE = [0.04, 0.035, 0.03];
  c.tiled(art.rock, () => -10, 64 * 2, [0.2, 0.19, 0.23]);
  const wall = 8 * s;
  const shapes = room === "bridge"
    ? [circle(215 * s, 312 * s, 185 * s), circle(785 * s, 312 * s, 185 * s), box(500 * s, 312 * s, 125 * s, 46 * s)]
    : room === "cross"
      ? [box(500 * s, 312 * s, 440 * s, 92 * s), box(500 * s, 312 * s, 92 * s, 292 * s)]
      : [circle(500 * s, 312 * s, 290 * s)];
  for (const shape of shapes) c.fill(grow(shape, wall + 1.5), EDGE);
  for (const shape of shapes) c.fill(grow(shape, wall), GOLD);
  for (const shape of shapes) c.tiled(art.floor, shape, 128 * (250 * s) / 128, [0.7, 0.66, 0.58], room === "cross" ? 0.5 : 1.6);
  if (room === "ring") {
    const pit = circle(500 * s, 312 * s, 105 * s);
    c.fill(grow(pit, wall + 1.5), EDGE);
    c.fill(grow(pit, wall), GOLD);
    c.tiled(art.rock, pit, 128, [0.09, 0.09, 0.11], 1.2);
  }

  const cellOf = (name) => {
    const i = GLYPHS.findIndex((g) => g[0] === name);
    const col = i % COLUMNS, row = Math.floor(i / COLUMNS);
    return [col * CELL / 256, (col + 1) * CELL / 256, row * CELL / 128, (row + 1) * CELL / 128];
  };
  const marker = (x, y, size, name, rim, tint, mine) => {
    const r = [17, 23, 30][size - 1] * s;
    if (mine) c.tex(art.glow, x * s, y * s, r * 2 * 2.4, [1, 0.82, 0.1], 0.95);
    c.tex(art.token, x * s, y * s, r * 2 * 32 / 31, rim);
    c.tex(art.glyphs, x * s, y * s, r * 2 * 0.66, tint, 1, 0, cellOf(name));
  };
  const strokeLine = (pts, size, tint) => {
    const t = [4, 7, 10][size - 1] * s;
    for (const pass of [0, 1]) {
      const col = pass ? tint : [0, 0, 0], th = pass ? t : t + 3;
      for (let i = 0; i + 1 < pts.length; i++) c.line(pts[i][0] * s, pts[i][1] * s, pts[i + 1][0] * s, pts[i + 1][1] * s, th, col, pass ? 1 : 0.85);
      for (const p of pts) c.tex(art.dot, p[0] * s, p[1] * s, th * 32 / 28, col, pass ? 1 : 0.85);
    }
  };
  const arrowTo = (x0, y0, x1, y1, size, tint) => {
    const t = Math.max(2, [4, 7, 10][size - 1] * s), head = t * 3 + 9;
    const len = Math.hypot(x1 - x0, y1 - y0) * s, ux = (x1 - x0) * s / len, uy = (y1 - y0) * s / len;
    const cx = x1 * s - ux * head * 29 / 64, cy = y1 * s - uy * head * 29 / 64;
    const rot = Math.atan2(-uy, ux);
    for (const pass of [0, 1]) {
      const col = pass ? tint : [0, 0, 0], grow2 = pass ? 0 : 3;
      c.line(x0 * s, y0 * s, cx - ux * head * 4 / 64, cy - uy * head * 4 / 64, t + grow2, col, pass ? 1 : 0.85);
      c.tex(art.dot, x0 * s, y0 * s, (t + grow2) * 32 / 28, col, pass ? 1 : 0.85);
      c.tex(art.arrow, cx + (pass ? 0 : ux * 1.5), cy + (pass ? 0 : uy * 1.5), head + grow2 * 2, col, pass ? 1 : 0.85, rot);
    }
  };

  // an area with its rim
  const zone = (x, y, r, tint) => {
    c.tex(art.disc, x * s, y * s, r * s * 2 * 128 / 124, tint, 0.22);
    const pts = arcPoints(x * s, y * s, r * s, 0, 360, 64);
    for (let i = 0; i + 1 < pts.length; i++) c.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], 2.6, tint, 0.95);
  };
  zone(640, 190, 95, [1, 0.25, 0.2]);
  zone(330, 430, 70, [0.3, 0.9, 0.3]);
  strokeLine([[300, 150], [330, 190], [345, 240], [330, 290], [290, 320], [250, 330]], 2, [1, 0.85, 0.15]);
  arrowTo(520, 420, 660, 330, 2, [0.3, 0.7, 1]);
  arrowTo(420, 120, 560, 120, 3, [1, 1, 1]);
  arrowTo(700, 420, 760, 470, 1, [1, 0.55, 0.1]);

  marker(500, 312, 3, "boss", [1, 0.25, 0.2], [1, 0.93, 0.82]);
  marker(500, 240, 2, "tank", [0.3, 0.7, 1], [0.5, 0.74, 1], true);
  marker(420, 395, 2, "heal", [0.3, 0.9, 0.3], [0.45, 0.95, 0.5]);
  marker(330, 100, 2, "dps", [1, 0.25, 0.2], [1, 0.5, 0.45], true);
  marker(585, 395, 2, "melee", [1, 0.55, 0.1], [1, 0.62, 0.4]);
  marker(330, 430, 2, "ranged", [1, 0.85, 0.15], [1, 0.86, 0.4]);
  marker(640, 190, 2, "fire", [1, 0.55, 0.1], [1, 0.6, 0.2]);
  marker(250, 250, 1, "add", [1, 0.25, 0.2], [1, 0.6, 0.5]);
  marker(215, 312, 2, "stack", [1, 0.85, 0.15], [1, 0.9, 0.55]);
  marker(785, 312, 2, "spread", [1, 1, 1], [1, 1, 1]);
  marker(760, 230, 1, "poison", [0.3, 0.9, 0.3], [0.6, 1, 0.35]);
  marker(700, 500, 3, "void", [0.75, 0.4, 1], [0.82, 0.55, 1]);
  marker(120, 120, 2, "plain", [0.1, 0.1, 0.1], [1, 1, 1]);
  // the selection ring
  c.tex(art.ring, 420 * s, 395 * s, 23 * s * 2 * 1.5, [1, 0.82, 0]);
  return c.img;
}

// Every glyph on a token, enlarged: how the palette and the markers look.
function tokenSheet(art) {
  const per = 8, size = 44, pad = 10, rows = Math.ceil(GLYPHS.length / per);
  const c = canvas(per * (size + pad) + pad, rows * (size + pad) + pad);
  c.fill(() => -10, [0.5, 0.47, 0.42]);
  GLYPHS.forEach((g, i) => {
    const col = i % per, row = Math.floor(i / per);
    const x = pad + col * (size + pad) + size / 2, y = pad + row * (size + pad) + size / 2;
    const ac = i % COLUMNS, ar = Math.floor(i / COLUMNS);
    c.tex(art.token, x, y, size, [1, 0.85, 0.15]);
    c.tex(art.glyphs, x, y, size * 0.66, [1, 1, 1], 1, 0, [ac * CELL / 256, (ac + 1) * CELL / 256, ar * CELL / 128, (ar + 1) * CELL / 128]);
  });
  return c.img;
}

// Main ---------------------------------------------------------------------------

checkGlyphOrder();
fs.mkdirSync(OUT, { recursive: true });

const art = {
  glyphs: glyphAtlas(),
  token: token(),
  ring: ring(),
  glow: glow(),
  arrow: arrow(),
  dot: dot(),
  disc: disc(),
  line: lineTexture(8),
  band: lineTexture(16),
  floor: floorTile(),
  rock: rockTile(),
};

let total = 0;
for (const [name, img] of Object.entries(art)) {
  const file = path.join(OUT, name + ".tga");
  writeTga(file, img);
  const bytes = fs.statSync(file).size;
  total += bytes;
  console.log(`${name}.tga  ${img.w}x${img.h}  ${bytes} bytes`);
}
console.log(`total ${total} bytes (${(total / 1024).toFixed(0)} KB)`);

if (PREVIEW) {
  fs.mkdirSync(PREVIEW, { recursive: true });
  for (const [name, img] of Object.entries(art)) {
    const zoom = img.w >= 128 ? 2 : img.w >= 64 ? 4 : 8;
    writePng(path.join(PREVIEW, name + ".png"), onBackground(img, zoom, name === "glyphs"));
  }
  writePng(path.join(PREVIEW, "tokens.png"), tokenSheet(art));
  for (const room of ["ring", "bridge", "cross"]) {
    writePng(path.join(PREVIEW, "board-" + room + ".png"), boardPreview(art, room));
  }
  console.log("previews in " + PREVIEW);
}
