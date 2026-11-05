#!/usr/bin/env python3
"""Cuts the on-court selects, voiceover takes and interviews into public/ for the Demo.

    FFMPEG=path/to/ffmpeg DEEP_FILTER=path/to/deep-filter.exe python scripts/cut-selects.py

SELECTS points at the folder of selects (default E:/Tennis selects). In-points were picked from contact sheets, and
speech cuts from Whisper word times. ONLY=vo redoes just the voiceover. Footage is never re-labelled: the real-serve clip keeps
the camera and the phone recording at their measured offset, and crops the phone below any notification banner.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import voice

FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')
DEEP_FILTER = os.environ.get('DEEP_FILTER', 'deep-filter')
SELECTS = Path(os.environ.get('SELECTS', 'E:/Tennis selects'))
ROOT = Path(__file__).resolve().parents[1]
FOOTAGE = ROOT / 'public/footage'
VO = ROOT / 'public/audio/vo'
VIDEO = ['-c:v', 'libx264', '-preset', 'medium', '-crf', '17', '-pix_fmt', 'yuv420p', '-r', '30']
FIT = 'scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080'


def run(*args):
    subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', *map(str, args)], check=True)


def clip(out, source, start, length, vf=FIT):
    run('-ss', start, '-t', length, '-i', SELECTS / source, '-an', '-vf', vf, *VIDEO, FOOTAGE / f'{out}.mp4')
    print(out)


# ---- Voiceover: the take to use for each line, trimmed to the words ----
TAKES = {'open': 'Open2', 'reveal': 'Reveal2', 'hardware': 'Hardware1', 'models': 'Models1', 'everywhere': 'Everywhere2',
         'whatif': 'Whatif1', 'drill': 'Drill1', 'sam': 'Sam2', 'end': 'End1'}
VO.mkdir(parents=True, exist_ok=True)
ENDS = {'everywhere': 7.45}  # that take has handling noise after the last word
for line, take in TAKES.items():
    voice.pro_voice(SELECTS / 'Voiceovers' / f'{take}.m4a', VO / f'{line}.wav', end=ENDS.get(line))
    print(line, take)

if os.environ.get('ONLY') == 'vo':
    raise SystemExit

# ---- On court ----
# Most selects are 120 fps playing at 30, so they are 1/4 speed as they stand.
clip('sl-serve', '02 Serve - full body.mp4', 1.8, 5.4)
clip('sl-forehand', '12 Red player - forehand rally - bounce and return.mp4', 1.2, 3)
clip('sl-watch', '10 Watch and tennis ball close-up.mp4', 5, 3.2)
clip('sl-side', '03 Serve - side angle.mp4', 0.8, 3.2)
clip('sl-pov', 'video-5587_singular_display.MOV', 33.5, 7, 'crop=864:486:0:230,scale=1920:1080:flags=lanczos')
# Phone in one hand, a tap on the handle with the other: the score goes to 15. Doubled, so the tap doesn't crawl.
clip('sl-score', '08 Phone score and racket close-up.mp4', 5, 11.2, 'setpts=PTS/2,crop=1500:844:0:236,scale=1920:1080:flags=lanczos')

# ---- A real serve beside the app: config/liveTwin.json has the sync, and how it was measured ----
TWIN = json.loads((ROOT / 'src/config/liveTwin.json').read_text(encoding='utf8'))
CAMERA, PHONE = SELECTS / 'Full session - MVI_0927.MP4', SELECTS / 'ScreenRecording_11-04-2026 13-16-33_1.MP4'
with tempfile.TemporaryDirectory() as tmp:
    parts = {'cam': [], 'app': []}
    for i, seg in enumerate(TWIN['segments']):
        r0, r1 = seg['r']
        count = round((r1 - r0) / seg['speed'] * 30)
        cam, app = Path(tmp) / f'cam{i}.mp4', Path(tmp) / f'app{i}.mp4'
        # The camera's frames are 1/4 speed: file time = (r - offset) * factor. Dropping frames, never blending them.
        run('-ss', (r0 - TWIN['offset']) * TWIN['factor'], '-i', CAMERA, '-an', '-frames:v', count,
            '-vf', f"setpts=PTS/({TWIN['factor']}*{seg['speed']}),fps=30,crop=1130:1008:{seg['camX']}:36", *VIDEO, cam)
        # Below the status bar and any notification banner: the Live title and the 3D racket, nothing else.
        run('-ss', r0, '-i', PHONE, '-an', '-frames:v', count, '-vf', f"setpts=PTS/{seg['speed']},fps=30,crop=1180:1088:0:372,scale=688:630:flags=lanczos", *VIDEO, app)
        parts['cam'].append(cam)
        parts['app'].append(app)
    for name, files in parts.items():
        lst = Path(tmp) / f'{name}.txt'
        lst.write_text(''.join(f"file '{f.as_posix()}'\n" for f in files))
        run('-f', 'concat', '-safe', 0, '-i', lst, '-c', 'copy', FOOTAGE / f'twin-{name}.mp4')
print('twin')

# ---- New robot shots, from the arm session's raw footage ----
RAW = ROOT.parent / 'marketing/Videos'
DESQUEEZE = 'scale=1920:1080:flags=lanczos,setsar=1'
for name, source, start, length in [('rt-arm', 'MAH08230.MP4', 8.2, 1.5), ('rt-racket', 'IMG_4691.MOV', 1.3, 1.5), ('rt-handle', 'MAH08225.MP4', 1.0, 1.5),
                                    ('rt-swing', 'MAH08231.MP4', 14.1, 1.5), ('rt-wide', 'MAH08225.MP4', 17.0, 2.0)]:
    run('-ss', start, '-t', length, '-i', RAW / source, '-an', '-vf', DESQUEEZE, *VIDEO, FOOTAGE / f'{name}.mp4')
    print(name)

# ---- On camera ----
with tempfile.TemporaryDirectory() as tmp:
    talk = Path(tmp) / 'talk.wav'
    voice.pro_voice(SELECTS / 'TalkingToCamera.MP4', talk, natural=True)
    run('-ss', 3.95, '-t', 12.1, '-i', SELECTS / 'TalkingToCamera.MP4', '-ss', 3.95, '-t', 12.1, '-i', talk,
        '-map', '0:v', '-map', '1:a', '-vf', FIT, *VIDEO, '-c:a', 'aac', '-b:a', '256k', FOOTAGE / 'talk-intro.mp4')
print('talk-intro')


# ---- Interviews: the lines themselves, without the questions ----
def spliced(source, spans, out):
    parts = ''.join(
        f'[0:v]trim={a}:{b},setpts=PTS-STARTPTS[v{i}];[0:a]atrim={a}:{b},asetpts=PTS-STARTPTS,afade=t=in:d=0.03,'
        f'afade=t=out:st={b - a - 0.05}:d=0.05[a{i}];' for i, (a, b) in enumerate(spans))
    joined = ''.join(f'[v{i}][a{i}]' for i in range(len(spans)))
    run('-i', FOOTAGE / source, '-filter_complex', f'{parts}{joined}concat=n={len(spans)}:v=1:a=1[v][a]',
        '-map', '[v]', '-map', '[a]', *VIDEO, '-c:a', 'aac', '-b:a', '256k', FOOTAGE / out)
    print(out, round(sum(b - a for a, b in spans), 2))


spliced('testimonial-1.mp4', [(7.85, 11.62), (15.72, 21.6)], 'testimonial-1-cut.mp4')
spliced('testimonial-2.mp4', [(0.38, 3.55), (15.95, 18.05)], 'testimonial-2-cut.mp4')
