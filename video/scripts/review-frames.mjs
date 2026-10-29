// Renders a few key frames of every scene to out/review/ for a quick visual check.
//   npm run frames              all scenes
//   npm run frames -- impact    one scene
import { execSync } from 'node:child_process';

const FRAMES = {
  hook: [70],
  racketReveal: [30, 140],
  insideHandle: [20, 120, 230],
  impact: [58, 150],
  robotLab: [60, 85, 200],
  devices: [150],
  score: [130],
  whatIf: [120, 300],
  together: [120],
  endcard: [90],
};

const only = process.argv[2];
for (const [id, frames] of Object.entries(FRAMES)) {
  if (only && id !== only) continue;
  for (const f of frames) {
    execSync(`npx remotion still scene-${id} out/review/${id}-${f}.png --frame=${f} --log=error`, { stdio: 'inherit' });
    console.log(`out/review/${id}-${f}.png`);
  }
}
