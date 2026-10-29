// Finds a song's tempo, beat grid, downbeats and loudness per bar, to cut video on the beat.
//   npx remotion ffmpeg -i public/audio/song.mp3 -ac 1 -ar 22050 out/song.wav
//   node scripts/analyze-song.mjs out/song.wav
import { readFileSync } from 'node:fs';

const file = readFileSync(process.argv[2]);
let p = 12, sr = 22050, pcm;
while (p < file.length) {
  const id = file.toString('ascii', p, p + 4), size = file.readUInt32LE(p + 4);
  if (id === 'fmt ') sr = file.readUInt32LE(p + 12);
  if (id === 'data') { pcm = new Int16Array(file.buffer, file.byteOffset + p + 8, size / 2); break; }
  p += 8 + size;
}
const x = Float32Array.from(pcm, (v) => v / 32768);
const dur = x.length / sr;

// Onset envelope: positive change in short-time energy, full band and low band (kick).
const HOP = 256, fr = sr / HOP, n = Math.floor(x.length / HOP);
const env = new Float32Array(n), low = new Float32Array(n), rms = new Float32Array(n);
let lp = 0, prevE = 0, prevL = 0;
for (let i = 0; i < n; i++) {
  let e = 0, l = 0;
  for (let k = 0; k < HOP; k++) {
    const v = x[i * HOP + k];
    lp += 0.03 * (v - lp); // ~100 Hz low-pass
    e += v * v; l += lp * lp;
  }
  e = Math.log1p(1000 * e); l = Math.log1p(4000 * l);
  env[i] = Math.max(0, e - prevE); low[i] = Math.max(0, l - prevL);
  rms[i] = e; prevE = e; prevL = l;
}

// Tempo: autocorrelation of the onset envelope over 70–180 BPM.
let best = 0, bestLag = 0;
for (let bpm = 70; bpm <= 180; bpm += 0.1) {
  const lag = (60 / bpm) * fr;
  let s = 0;
  for (let i = 0; i + 2 * lag < n; i++) s += env[i] * (env[Math.round(i + lag)] + 0.5 * env[Math.round(i + 2 * lag)]);
  if (s > best) { best = s; bestLag = lag; }
}
let bpm = 60 * fr / bestLag;
if (bpm < 85) bpm *= 2;
const beat = 60 / bpm;

// Beat phase: offset whose grid collects the most onset energy.
let bestPh = 0, bestSum = -1;
for (let ph = 0; ph < beat; ph += 0.005) {
  let s = 0;
  for (let t = ph; t < dur; t += beat) s += env[Math.round(t * fr)] ?? 0;
  if (s > bestSum) { bestSum = s; bestPh = ph; }
}
// Downbeat: which of the 4 beats carries the most kick energy.
const kickBy = [0, 0, 0, 0];
for (let t = bestPh, b = 0; t < dur; t += beat, b++) for (let d = -2; d <= 2; d++) kickBy[b % 4] += low[Math.round(t * fr) + d] ?? 0;
const down = kickBy.indexOf(Math.max(...kickBy));
const first = bestPh + down * beat;
const bar = beat * 4;

console.log(`duration ${dur.toFixed(2)} s · ${bpm.toFixed(2)} BPM · beat ${beat.toFixed(4)} s · bar ${bar.toFixed(3)} s · first downbeat ${first.toFixed(3)} s`);
console.log('\nbar   time    loudness  (█ = louder; jumps mark section changes)');
const bars = [];
for (let t = first, k = 0; t + bar <= dur; t += bar, k++) {
  let s = 0, c = 0;
  for (let i = Math.round(t * fr); i < Math.round((t + bar) * fr); i++) { s += rms[i]; c++; }
  bars.push(s / c);
}
const lo = Math.min(...bars), hi = Math.max(...bars);
bars.forEach((v, k) => {
  const t = first + k * bar, jump = k && v - bars[k - 1] > (hi - lo) * 0.18 ? '  ◀ lift' : k && bars[k - 1] - v > (hi - lo) * 0.18 ? '  ◀ drop-out' : '';
  console.log(`${String(k + 1).padStart(3)}  ${t.toFixed(2).padStart(6)}s  ${'█'.repeat(Math.round(((v - lo) / (hi - lo)) * 30))}${jump}`);
});
