#!/usr/bin/env python3
"""Levels the rendered Demo's audio for upload: limits peaks, then a two-pass loudness normalize. The picture is copied.

    FFMPEG=path/to/ffmpeg python scripts/master-demo.py [in.mp4] [out.mp4]
"""
import json
import os
import re
import subprocess
import sys

FFMPEG = os.environ.get('FFMPEG', 'ffmpeg')
src = sys.argv[1] if len(sys.argv) > 1 else 'out/demo.mp4'
out = sys.argv[2] if len(sys.argv) > 2 else 'out/tennis-buddee-demo.mp4'
TARGET = f"I={os.environ.get('LOUDNESS', '-15')}:TP=-1.5:LRA=11"
LIMIT = 'volume=6dB,alimiter=limit=0.8:attack=5:release=80:level=false'

first = subprocess.run([FFMPEG, '-hide_banner', '-i', src, '-af', f'{LIMIT},loudnorm={TARGET}:print_format=json', '-f', 'null', '-'],
                       capture_output=True, text=True, check=True).stderr
m = json.loads(re.search(r'\{[^{}]*"input_i"[^{}]*\}', first).group(0))
second = (f"{LIMIT},loudnorm={TARGET}:linear=true:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
          f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}")
subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', '-i', src, '-c:v', 'copy', '-af', second, '-ar', '48000',
                '-c:a', 'aac', '-b:a', '320k', '-movflags', '+faststart', out], check=True)
check = subprocess.run([FFMPEG, '-hide_banner', '-i', out, '-af', 'loudnorm=print_format=summary', '-f', 'null', '-'],
                       capture_output=True, text=True).stderr
print(out, re.search(r'Input Integrated:\s+\S+ LUFS', check).group(0), re.search(r'Input True Peak:\s+\S+ dBTP', check).group(0))
