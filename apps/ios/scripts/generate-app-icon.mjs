#!/usr/bin/env node
/**
 * Rasterizes docs/phren-icon-128.svg (a background circle + axis-aligned
 * pixel-art rects) into the 1024x1024 iOS app icon PNG — no native image
 * tooling required. iOS masks icons itself, so the background fills the
 * full square with the brand navy.
 *
 *   node apps/ios/scripts/generate-app-icon.mjs
 */
import * as fs from "node:fs";
import * as path from "node:path";
import * as zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const svgPath = path.resolve(here, "../../../docs/phren-icon-128.svg");
const outPath = path.resolve(here, "../Phren/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png");

const svg = fs.readFileSync(svgPath, "utf8");
const viewBox = svg.match(/viewBox="0 0 (\d+) (\d+)"/);
const svgSize = viewBox ? Number(viewBox[1]) : 128;

// Parse `<g fill="rgb(r,g,b)"> <rect .../> ... </g>` groups (also handles hex fills).
const rects = [];
const groupRe = /<g fill="([^"]+)">([\s\S]*?)<\/g>/g;
const rectRe = /<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"/g;
function parseFill(fill) {
  const rgb = fill.match(/rgb\((\d+),\s*(\d+),\s*(\d+)\)/);
  if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])];
  const hex = fill.match(/#([0-9a-fA-F]{6})/);
  if (hex) {
    const n = parseInt(hex[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  return null;
}
let group;
while ((group = groupRe.exec(svg)) !== null) {
  const fill = parseFill(group[1]);
  if (!fill) continue;
  let rect;
  while ((rect = rectRe.exec(group[2])) !== null) {
    rects.push({
      x: Number(rect[1]), y: Number(rect[2]),
      w: Number(rect[3]), h: Number(rect[4]),
      fill,
    });
  }
}
if (rects.length === 0) throw new Error("no rects parsed from icon SVG");
console.log(`parsed ${rects.length} rects from ${path.basename(svgPath)}`);

const SIZE = 1024;
const background = [0x12, 0x12, 0x2a]; // --bg from docs/style.css
const pixels = Buffer.alloc(SIZE * SIZE * 3);

for (let py = 0; py < SIZE; py++) {
  const sy = ((py + 0.5) * svgSize) / SIZE;
  for (let px = 0; px < SIZE; px++) {
    const sx = ((px + 0.5) * svgSize) / SIZE;
    let color = background;
    // Painter's order: later rects win.
    for (const r of rects) {
      if (sx >= r.x && sx < r.x + r.w && sy >= r.y && sy < r.y + r.h) {
        color = r.fill;
      }
    }
    const o = (py * SIZE + px) * 3;
    pixels[o] = color[0];
    pixels[o + 1] = color[1];
    pixels[o + 2] = color[2];
  }
}

// Minimal PNG encoder: 8-bit RGB, filter 0 per scanline.
function crc32(buf) {
  let c, table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  c = -1;
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8;  // bit depth
ihdr[9] = 2;  // color type: truecolor RGB
const raw = Buffer.alloc(SIZE * (SIZE * 3 + 1));
for (let y = 0; y < SIZE; y++) {
  raw[y * (SIZE * 3 + 1)] = 0; // filter: none
  pixels.copy(raw, y * (SIZE * 3 + 1) + 1, y * SIZE * 3, (y + 1) * SIZE * 3);
}
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
  chunk("IEND", Buffer.alloc(0)),
]);

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, png);
console.log(`wrote ${outPath} (${(png.length / 1024).toFixed(0)} KB)`);
