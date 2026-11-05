#!/usr/bin/env python3
"""Cuts the clips for the X version (src/hype/Viral.tsx), each to land on the song's bars.

    FFMPEG=path/to/ffmpeg python scripts/cut-viral.py

Run scripts/cut-selects.py and scripts/cut-emulator.py first: the interviews and the simulator come from their output.
"""
import json
import os
import subprocess
import tempfile
from pathlib import Path

FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')
SELECTS = Path(os.environ.get('SELECTS', 'E:/Tennis selects'))
ROOT = Path(__file__).resolve().parents[1]
FOOTAGE = ROOT / 'public/footage'
VIDEO = ['-c:v', 'libx264', '-preset', 'medium', '-crf', '17', '-pix_fmt', 'yuv420p', '-r', '30']
FIT = 'scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080'
BEAT = 60 / 95
BAR = 4 * BEAT


def run(*args):
    subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', *map(str, args)], check=True)


# The hook. Select 01 is 120 fps, so it's 1/4 speed already. Its contact is timed onto the song's drop, two bars in.
CONTACT = float(os.environ.get('HOOK_CONTACT', 4.85))
stretch = 2 * BAR / CONTACT
run('-t', CONTACT + 0.1, '-i', SELECTS / '01 Serve - close front angle.mp4', '-an', '-vf', f'setpts=PTS*{stretch:.5f},fps=30,{FIT}', *VIDEO, FOOTAGE / 'vx-hook.mp4')
print('hook, stretched', round(stretch, 3))

# The real serve and forehand. Sync: src/config/liveTwin.json. Each contact lands on beat 3 of its bar.
TWIN = json.loads((ROOT / 'src/config/liveTwin.json').read_text(encoding='utf8'))
CAMERA, PHONE = SELECTS / 'Full session - MVI_0927.MP4', SELECTS / 'ScreenRecording_11-04-2026 13-16-33_1.MP4'
for i, (contact, speed, cam_x) in enumerate([(86.8, 1, 110), (86.8, 0.5, 110), (47.7, 0.5, 540)]):
    r0 = contact - 2 * BEAT * speed
    count = round(BAR * 30) + 1
    run('-ss', (r0 - TWIN['offset']) * TWIN['factor'], '-i', CAMERA, '-an', '-frames:v', count,
        '-vf', f"setpts=PTS/({TWIN['factor']}*{speed}),fps=30,crop=1180:1080:{cam_x}:0", *VIDEO, FOOTAGE / f'vx-twin-cam-{i}.mp4')
    run('-ss', r0, '-i', PHONE, '-an', '-frames:v', count,
        '-vf', f'setpts=PTS/{speed},fps=30,crop=1180:1088:0:372,scale=740:682:flags=lanczos', *VIDEO, FOOTAGE / f'vx-twin-app-{i}.mp4')
print('twin')

# The tap on the handle, at about real speed: the score goes to 15.
run('-ss', 7.2, '-t', 5.4, '-i', SELECTS / '08 Phone score and racket close-up.mp4', '-an',
    '-vf', 'setpts=PTS/2,crop=1500:844:0:236,scale=1920:1080:flags=lanczos', *VIDEO, FOOTAGE / 'vx-score.mp4')
print('score')

# Their own words, from the cleaned interviews.
for name, source, a, b in [('vx-kellam', 'testimonial-1.mp4', 7.98, 10.52), ('vx-josh', 'testimonial-2.mp4', 15.95, 18.3)]:
    run('-ss', a, '-t', b - a, '-i', FOOTAGE / source, '-af', 'afade=t=in:d=0.02', *VIDEO, '-c:a', 'aac', '-b:a', '256k', FOOTAGE / f'{name}.mp4')
    print(name)


# The live simulator: seconds on the capture's clock (scripts/capture-emulator.mjs). Check them after a new capture.
def spans(items, out):
    parts = ''.join(f'[0:v]trim={a}:{b},setpts=PTS-STARTPTS[v{i}];' for i, (a, b) in enumerate(items))
    joined = ''.join(f'[v{i}]' for i in range(len(items)))
    run('-i', FOOTAGE / 'emu-whole.mp4', '-filter_complex', f'{parts}{joined}concat=n={len(items)}:v=1[v]', '-map', '[v]', *VIDEO, FOOTAGE / out)
    print(out)


spans([(27.6, 28.9), (36.0, 37.3)], 'vx-muse-a.mp4')  # Find it, then the result
spans([(41.0, 43.7)], 'vx-muse-b.mp4')  # What if, in 3D
spans([(6.0, 8.7)], 'vx-sim.mp4')  # Hits landing on Live
