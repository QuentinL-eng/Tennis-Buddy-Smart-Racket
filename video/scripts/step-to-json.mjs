// Converts an Onshape STEP export into a compact mesh file the video can load
// (public/models/<preset>.json). Parts are grouped by what they are so scenes
// can move, hide and label each group.
//
//   node scripts/step-to-json.mjs handle cad/handle.step
//   node scripts/step-to-json.mjs robot  cad/robot-arm.step
//
// Re-run whenever the CAD changes. Group rules live in PRESETS below.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import occtFactory from 'occt-import-js';

// First matching rule wins; matched against "<assembly path>/<mesh name>".
const PRESETS = {
  handle: [
    ['shell1', /Insert Side 1/i],
    ['shell2', /Insert Side 2/i],
    ['screws', /screw/i],
    ['button', /Power button/i],
    ['imu', /STEVAL|MKI251/i],
    ['mic', /INMP441/i],
    ['mcu', /XIAO|esp32/i],
    ['board', /.*/],
  ],
  // Everything above the base turns about J1 in the RobotLab scene.
  robot: [
    ['base', /_base$/i],
    ['shoulder', /_arm_1$/i], // missing from the current export; RobotLab draws a stand-in
    ['racket', /\/Body1$/i],
    ['swing', /_arm_\d|Racket Mount|Part 2/i],
    ['uno', /UNO Q/i],
    ['rig', /.*/],
  ],
};

const [preset, src] = process.argv.slice(2);
if (!PRESETS[preset] || !src) { console.error('usage: node scripts/step-to-json.mjs <handle|robot> <file.step>'); process.exit(1); }
const GROUPS = PRESETS[preset];
const out = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'models', `${preset}.json`);

const occt = await occtFactory();
const result = occt.ReadStepFile(new Uint8Array(readFileSync(src)), {
  linearUnit: 'millimeter', linearDeflectionType: 'bounding_box_ratio', linearDeflection: 0.0008, angularDeflection: 0.3,
});
if (!result.success) throw new Error('STEP import failed');

const groupOf = new Map();
(function walk(node, path) {
  const p = `${path}/${node.name}`;
  // The control board arrives flattened, so match on each mesh's own name too.
  for (const i of node.meshes) {
    const full = `${p}/${result.meshes[i].name}`;
    groupOf.set(i, GROUPS.find(([, re]) => re.test(full))[0]);
  }
  for (const c of node.children) walk(c, p);
})(result.root, '');

// Merge meshes per group and CAD colour: few draw calls, colours stay as designed.
// Shape: groups[name] = [{ color: [r,g,b], position: [...], index: [...] }, ...]
const merged = {};
result.meshes.forEach((m, i) => {
  const color = (m.color ?? [0.5, 0.5, 0.5]).map((c) => +c.toFixed(3));
  const parts = (merged[groupOf.get(i) ?? 'board'] ??= []);
  let part = parts.find((x) => x.color.join() === color.join());
  if (!part) parts.push((part = { color, position: [], index: [] }));
  const base = part.position.length / 3;
  for (const v of m.attributes.position.array) part.position.push(+v.toFixed(3));
  for (const ix of m.index.array) part.index.push(ix + base);
});

const bounds = { min: [Infinity, Infinity, Infinity], max: [-Infinity, -Infinity, -Infinity] };
for (const parts of Object.values(merged)) for (const g of parts) for (let i = 0; i < g.position.length; i++) {
  bounds.min[i % 3] = Math.min(bounds.min[i % 3], g.position[i]);
  bounds.max[i % 3] = Math.max(bounds.max[i % 3], g.position[i]);
}

mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify({ units: 'mm', bounds, groups: merged }));
for (const [k, parts] of Object.entries(merged)) {
  const tris = parts.reduce((n, g) => n + g.index.length / 3, 0);
  const center = [0, 1, 2].map((a) => {
    let lo = Infinity, hi = -Infinity;
    for (const g of parts) for (let i = a; i < g.position.length; i += 3) { lo = Math.min(lo, g.position[i]); hi = Math.max(hi, g.position[i]); }
    return +((lo + hi) / 2).toFixed(1);
  });
  console.log(k.padEnd(8), String(tris).padStart(8), 'tris', String(parts.length).padStart(3), 'colours  centre', center);
}
console.log('bounds', bounds, '->', out);
