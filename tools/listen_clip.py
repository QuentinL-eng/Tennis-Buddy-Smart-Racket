"""Export an impact clip as WAV, optionally keeping only the tail after clipping.

python tools/listen_clip.py data/sessions/<session>/clips/clip-0001.i16 --tail-only
"""
import argparse
from pathlib import Path
import wave

import numpy as np

FS, PRE, CLIP_LEVEL = 16000, 64, 30000


def tail_start(clip):
    near_full = np.flatnonzero(np.abs(clip.astype(np.int32)) >= CLIP_LEVEL)
    return int(near_full[-1]) + 1 if near_full.size else min(PRE, clip.size)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("clip", type=Path)
    ap.add_argument("--tail-only", action="store_true")
    a = ap.parse_args()
    clip = np.fromfile(a.clip, dtype="<i2")
    if clip.size < 512:
        raise SystemExit("Clip is too short: expected at least 512 samples.")
    start = tail_start(clip)
    print(f"Duration: {clip.size / FS * 1000:.1f} ms; "
          f"tail after last near-full-scale sample (or trigger): {(clip.size - start) / FS * 1000:.1f} ms")
    audio = clip[start:] if a.tail_only else clip
    if not audio.size:
        raise SystemExit("No tail remains; the clip ends at a near-full-scale sample.")
    out = a.clip.with_suffix(".tail.wav" if a.tail_only else ".wav")
    with wave.open(str(out), "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(FS)
        fh.writeframes(audio.astype("<i2").tobytes())
    print(f"Wrote {out} (original level; no volume boost).")


if __name__ == "__main__":
    main()
