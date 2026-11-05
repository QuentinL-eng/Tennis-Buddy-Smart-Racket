#!/usr/bin/env python3
"""Turns a run of scripts/capture-emulator.mjs into the Demo's two simulator clips.

    FFMPEG=path/to/ffmpeg python scripts/cut-emulator.py <capture dir>

Chrome only sends a frame when the page changes, so each frame is held until the next one. Waits for Muse are cut:
the phone screen shows what the live site returned. SPANS are seconds on the capture's clock; check them against
log.json after a new run, because Muse's answers and timing change from run to run.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')
cap = Path(sys.argv[1]).resolve()
FOOTAGE = Path(__file__).resolve().parents[1] / 'public/footage'
CROP = 'crop=590:1100:1268:100,scale=1072:2000:flags=lanczos'  # the phone's screen, sized for its frame
VIDEO = ['-c:v', 'libx264', '-preset', 'medium', '-crf', '17', '-pix_fmt', 'yuv420p', '-r', '30']

HERO = [(26.5, 29.0), (35.7, 39.2), (39.2, 45.2), (61.0, 64.5), (77.5, 82.5)]  # Find it, the result, What if, the drill, an answer
LIVE = [(4.5, 12.5)]


def run(*args):
    subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', *map(str, args)], check=True)


frames = json.loads((cap / 'frames.json').read_text())
t0 = frames[0]['t']
with tempfile.TemporaryDirectory() as tmp:
    lst = Path(tmp) / 'list.txt'
    rows = []
    for a, b in zip(frames, frames[1:] + [{'t': frames[-1]['t'] + 8000}]):
        rows.append(f"file '{(cap / 'frames' / (a['name'] + '.jpg')).as_posix()}'\nduration {(b['t'] - a['t']) / 1000:.4f}")
    lst.write_text('\n'.join(rows))
    whole = FOOTAGE / 'emu-whole.mp4'  # scripts/cut-viral.py cuts from it too
    run('-f', 'concat', '-safe', 0, '-i', lst, '-vf', 'fps=30,' + CROP, *VIDEO, whole)

    def spans(items, out):
        parts = ''.join(f'[0:v]trim={a}:{b},setpts=PTS-STARTPTS[v{i}];' for i, (a, b) in enumerate(items))
        joined = ''.join(f'[v{i}]' for i in range(len(items)))
        run('-i', whole, '-filter_complex', f'{parts}{joined}concat=n={len(items)}:v=1[v]', '-map', '[v]', *VIDEO, FOOTAGE / out)
        print(out, sum(b - a for a, b in items))

    spans(HERO, 'muse-screen-recording.mp4')
    spans(LIVE, 'simulator.mp4')
