// What's left before the Demo can ship. Exits non-zero while anything blocks it.
//   npm run check
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { copy } from '../src/config/copy.ts';
import { cuts } from '../src/config/timeline.ts';
import { voSeconds } from '../src/config/voiceover.ts';

const LIMIT = 180;
const BANNED = /\b(coach\w*|analy[sz]er\w*)\b/i;
const blockers = [], notes = [];

const cut = cuts.Demo;
const id = (e) => e.scene ?? e.footage;

// Length
let t = 0;
const starts = new Map();
for (const e of cut.entries) { starts.set(id(e), t); t += e.seconds - cut.transition; }
const total = t + cut.transition;
if (total > LIMIT) blockers.push(`Too long: ${total.toFixed(1)} s, limit ${LIMIT} s`);

// Footage
const has = (e) => existsSync(`public/footage/${e.file ?? `${e.footage}.mp4`}`);
for (const e of cut.entries.filter((x) => x.footage)) {
  if (has(e)) continue;
  if (e.standIn) blockers.push(`Stand-in still playing: film public/footage/${e.footage}.mp4`);
  else if (e.fallback) notes.push(`${e.footage}: CGI fallback "${e.fallback}" plays until public/footage/${e.footage}.mp4 exists`);
  else if (!e.clips) blockers.push(`Placeholder still showing: film public/footage/${e.footage}.mp4`);
  for (const [name] of e.clips ?? []) if (!existsSync(`public/footage/${name}.mp4`)) blockers.push(`Missing clip ${name}.mp4 (npm run footage)`);
}
if (!existsSync('public/footage/sam-clip.mp4')) blockers.push('Missing public/footage/sam-clip.mp4 (npm run sam)');

// Sample numbers and blank names
if (copy.coldOpenShot.sample && cut.entries.some((e) => e.overlays?.some((o) => o.type === 'shotCard'))) blockers.push('copy.coldOpenShot is still SAMPLE: put your real serve\'s numbers in, then set sample: false');
for (const e of cut.entries) for (const o of e.overlays ?? []) {
  if (o.type === 'lowerThird' && copy.overlays[o.text].name === 'Name') blockers.push(`${id(e)}: fill in copy.overlays.${o.text}`);
}

// Spoken lines: timing and recordings
const lines = cut.voiceover.filter((l) => {
  if (starts.has(l.at)) return true;
  notes.push(`Voiceover "${l.id}" skipped: no entry "${l.at}" in the timeline`);
  return false;
}).map((l) => ({ ...l, from: starts.get(l.at) + (l.lead ?? 0.3), len: voSeconds(l) })).sort((a, b) => a.from - b.from);
lines.forEach((l, i) => {
  const next = lines[i + 1];
  if (next && l.from + l.len > next.from) notes.push(`Voiceover "${l.id}" runs ${(l.from + l.len - next.from).toFixed(1)} s into "${next.id}": shorten it, or lengthen the entry`);
});
const recorded = existsSync('public/audio/vo') ? readdirSync('public/audio/vo').map((f) => f.replace(/\.\w+$/, '')) : [];
const missing = lines.filter((l) => !l.captionOnly && !recorded.includes(l.id)).map((l) => l.id);
if (missing.length) blockers.push(`Voiceover not recorded (public/audio/vo/<id>.wav): ${missing.join(', ')}`);

// Words the hackathon's anti-project list rules out, in anything that reaches the screen
for (const f of ['src/config/copy.ts', 'src/config/voiceover.ts', 'src/config/generated/facts.json']) {
  readFileSync(f, 'utf8').split(/\r?\n/).forEach((line, i) => {
    const text = line.replace(/\/\/.*$/, ''); // comments never reach the screen
    if (/^\s*testimonial\d:/.test(text)) return; // a person's job title, not a description of the product
    if (BANNED.test(text)) blockers.push(`${f}:${i + 1}: banned word: ${text.trim().slice(0, 70)}`);
  });
}

// Muse's tools: the scene's groups must match hackathon.json
const facts = JSON.parse(readFileSync('src/config/generated/facts.json', 'utf8'));
const drawn = copy.museAgent.groups.flatMap((g) => g.tools);
const diff = [...facts.agentTools.filter((x) => !drawn.includes(x)), ...drawn.filter((x) => !facts.agentTools.includes(x))];
if (diff.length) blockers.push(`copy.museAgent.groups and hackathon.json disagree on: ${diff.join(', ')}`);

console.log(`Demo: ${Math.floor(total / 60)}:${(total % 60).toFixed(1).padStart(4, '0')} of 3:00`);
for (const n of notes) console.log(`  note     ${n}`);
for (const b of blockers) console.log(`  BLOCKS   ${b}`);
console.log(blockers.length ? `\n${blockers.length} left before the final render.` : '\nReady: npm run render:demo');
process.exit(blockers.length ? 1 : 0);
