// Prints a cut with real timecodes (crossfades included), straight from src/config/timeline.ts.
//   npm run timeline                 the Demo
//   npm run timeline -- RevealSong   any cut by name (Reveal, RevealSong, Demo)
import { cuts, song } from '../src/config/timeline.ts';

const name = process.argv[2] ?? 'Demo';
const cut = cuts[name];
if (!cut) { console.error(`no cut "${name}"; try ${Object.keys(cuts).join(', ')}`); process.exit(1); }
const bar = (4 * 60) / song.bpm;
const tc = (s) => `${Math.floor(s / 60)}:${(s % 60).toFixed(1).padStart(4, '0')}`;
let t = 0, cgi = 0, real = 0;
for (const e of cut.entries) {
  const kind = 'scene' in e ? 'CGI ' : 'REAL';
  'scene' in e ? (cgi += e.seconds) : (real += e.seconds);
  const bars = cut.music === song ? `  bar ${(t / bar + 1).toFixed(1)}` : '';
  console.log(`${tc(t)}  ${kind}  ${e.seconds.toFixed(2).padStart(6)}s${bars}  ${e.scene ?? e.footage}${e.file ? `  (${e.file})` : ''}`);
  t += e.seconds - cut.transition;
}
const total = t + cut.transition;
console.log(`\n${name}: ${tc(total)} (${total.toFixed(1)} s)  ·  CGI ${cgi.toFixed(0)}s  ·  real footage ${real}s`);
