// Copies shared assets from the app/website into public/ so the video always
// uses the same icon and photos as the product. Runs before studio/render.
// (The racket itself is procedural: src/components/Racket.tsx.)
import { copyFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const pub = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'public');

const assets = {
  'img/icon.png': 'website/img/icon.png',
  'img/court.jpg': 'marketing/glasses-sim/court-hires.jpg',
};

for (const [dest, src] of Object.entries(assets)) {
  const from = join(root, src);
  const to = join(pub, dest);
  if (!existsSync(from)) { console.warn(`missing ${src}`); continue; }
  if (existsSync(to) && statSync(to).mtimeMs >= statSync(from).mtimeMs) continue;
  mkdirSync(dirname(to), { recursive: true });
  copyFileSync(from, to);
  console.log(`copied ${src} -> public/${dest}`);
}

