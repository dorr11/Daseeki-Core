// gen-ledger-grain.js — regenerate Daseeki "Field Ledger" grain substrate.
//
// Produces textures/ledger-grain.tga: a 128x128 (power-of-two) 32-bit BGRA,
// top-left-origin, uncompressed truecolor TGA. Pure grayscale (R=G=B); the WoW
// painter tints it per-token via SetVertexColor and veils it via SetAlpha.
//
// DESIGN (BRAND_SPEC §4 — material, amplitude <= +/-6%):
//   * Mean ~= 235/255 (0.922) = "parchment white". Tinted by the (dark) panel token
//     the tinted mean lands NEAR the panel color, so raising the veil alpha toward 1.0
//     lightens the ground gutters toward parchment instead of muddying them dark. The
//     R0 grain was mean 128 (0.5): tinted by panel at alpha 0.5 it DARKENED the gutters
//     below the ground color (the "flat brown/black" owner report) while its tooth was
//     imperceptible.
//   * Peak deviation from mean = +/-14/255 => relative-to-mean amplitude ~= 6.0%
//     (== the on-screen luminance modulation of the surface at veil alpha 1.0, since a
//     grayscale tint multiply preserves relative amplitude). Effective modulation scales
//     ~linearly with the veil alpha, so the presets (subtle/standard/strong) ride it
//     from ~2.7% up to the ~6% ceiling without ever exceeding it.
//   * TWO octaves: a COARSE value-noise octave (8px cells, bilinear, tileable) gives
//     mottling that stays visible as "tooth" at 100% UI scale; a FINE per-pixel octave
//     adds paper-fibre sparkle. Both wrap so REPEAT tiling is seamless.
//
// Deterministic (fixed seed) so re-runs reproduce the committed asset byte-for-byte.

const fs = require('fs');
const path = require('path');

const SIZE = 128;              // power-of-two
const MEAN = 235;              // 0.922 * 255 (parchment white)
const PEAK_DEV = 14;           // +/-14 => relative amplitude 14/235 = 5.96% (<= 6%)
const CELL = 8;                // coarse octave cell size in px (SIZE/CELL = 16 grid)
const W_COARSE = 0.66;         // coarse octave weight (dominant -> visible tooth)
const W_FINE = 0.34;           // fine per-pixel octave weight
const OUT = path.join(__dirname, '..', 'textures', 'ledger-grain.tga');

// --- deterministic PRNG (mulberry32) ---
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = mulberry32(0x1ED6E401);

// --- coarse octave: value noise on a wrapped GRID, bilinear interpolation ---
const G = SIZE / CELL;                       // grid dimension (16)
const grid = new Float64Array(G * G);
for (let i = 0; i < G * G; i++) grid[i] = rand() * 2 - 1;   // [-1,1]
const gAt = (gx, gy) => grid[((gy % G) + G) % G * G + (((gx % G) + G) % G)];
function coarseAt(x, y) {
  const fx = x / CELL, fy = y / CELL;
  const x0 = Math.floor(fx), y0 = Math.floor(fy);
  const tx = fx - x0, ty = fy - y0;
  // smoothstep for softer mottling
  const sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty);
  const v00 = gAt(x0, y0), v10 = gAt(x0 + 1, y0);
  const v01 = gAt(x0, y0 + 1), v11 = gAt(x0 + 1, y0 + 1);
  const a = v00 + (v10 - v00) * sx;
  const b = v01 + (v11 - v01) * sx;
  return a + (b - a) * sy;                   // ~[-1,1]
}

// --- compose raw noise field, then normalize peak to exactly PEAK_DEV ---
const raw = new Float64Array(SIZE * SIZE);
let rawPeak = 0;
for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const c = coarseAt(x, y);
    const f = rand() * 2 - 1;                 // fine per-pixel (inherently tileable)
    const n = W_COARSE * c + W_FINE * f;
    raw[y * SIZE + x] = n;
    if (Math.abs(n) > rawPeak) rawPeak = Math.abs(n);
  }
}
const scale = PEAK_DEV / rawPeak;

// --- write TGA (18-byte header + BGRA, top-left origin) ---
const header = Buffer.from([
  0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  SIZE & 0xFF, (SIZE >> 8) & 0xFF,   // width  = 128
  SIZE & 0xFF, (SIZE >> 8) & 0xFF,   // height = 128
  0x20,                              // 32 bpp
  0x28,                              // desc: 8 alpha bits, top-left origin
]);
const body = Buffer.alloc(SIZE * SIZE * 4);
let sum = 0, sumSq = 0, mn = 255, mx = 0;
for (let i = 0; i < SIZE * SIZE; i++) {
  let v = Math.round(MEAN + raw[i] * scale);
  if (v < 0) v = 0; else if (v > 255) v = 255;
  body[i * 4 + 0] = v; // B
  body[i * 4 + 1] = v; // G
  body[i * 4 + 2] = v; // R
  body[i * 4 + 3] = 255; // A
  sum += v; if (v < mn) mn = v; if (v > mx) mx = v;
}
const mean = sum / (SIZE * SIZE);
for (let i = 0; i < SIZE * SIZE; i++) { const d = body[i * 4] - mean; sumSq += d * d; }
const rms = Math.sqrt(sumSq / (SIZE * SIZE));
const peakDev = Math.max(mx - mean, mean - mn);

fs.writeFileSync(OUT, Buffer.concat([header, body]));
console.log(`wrote ${OUT} (${header.length + body.length} bytes, ${SIZE}x${SIZE} BGRA)`);
console.log(`  mean=${mean.toFixed(2)} (${(mean / 255 * 100).toFixed(1)}% white)  min=${mn} max=${mx}`);
console.log(`  peak dev = +/-${peakDev.toFixed(2)}/255`);
console.log(`  PEAK amplitude, full-scale (peakDev/255)   = +/-${(peakDev / 255 * 100).toFixed(2)}%`);
console.log(`  PEAK amplitude, relative-to-mean           = +/-${(peakDev / mean * 100).toFixed(2)}%`);
console.log(`  RMS  amplitude, relative-to-mean           = +/-${(rms / mean * 100).toFixed(2)}%`);
