#!/usr/bin/env python3
"""Inspect a UVC camera and measure what it actually delivers.

    python3 tools/camera_check.py --device /dev/video0
    python3 tools/camera_check.py --device /dev/video2 --fps 120 --save frame.jpg

The negotiated properties are only what the driver accepted.  The measured
interval is what matters for tracking; a camera advertised as 240 fps often
delivers 30 fps in the mode the driver picked.
"""

from __future__ import annotations

import argparse
import glob
import time
from pathlib import Path

import numpy as np


def list_devices() -> None:
    entries = sorted(glob.glob("/sys/class/video4linux/video*"))
    if not entries:
        print("  (no /sys/class/video4linux entries; not Linux?)")
        return
    for entry in entries:
        name = Path(entry, "name")
        try:
            label = name.read_text(encoding="utf-8").strip()
        except OSError:
            label = "?"
        print(f"  /dev/{Path(entry).name}: {label}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", default="/dev/video0")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=float, default=240.0)
    parser.add_argument("--fourcc", default="MJPG")
    parser.add_argument(
        "--buffer",
        type=int,
        default=2,
        help="V4L2 buffer count (1 can halve the delivered rate on some UVC drivers)",
    )
    parser.add_argument("--exposure", type=float, default=-1.0, help="-1 leaves the driver alone")
    parser.add_argument("--gain", type=float, default=-1.0)
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--save", help="write a sample frame to this path")
    args = parser.parse_args()

    try:
        import cv2
    except ImportError:
        print("OpenCV is missing. Install it with: pip install opencv-python")
        return 2

    print("Video devices")
    list_devices()
    print()

    capture = cv2.VideoCapture(args.device, cv2.CAP_V4L2)
    if not capture.isOpened():
        capture.release()
        capture = cv2.VideoCapture(args.device)
    if not capture.isOpened():
        print(f"cannot open {args.device}")
        return 1

    capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*args.fourcc[:4]))
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    capture.set(cv2.CAP_PROP_FPS, args.fps)
    capture.set(cv2.CAP_PROP_BUFFERSIZE, args.buffer)
    if args.exposure >= 0:
        capture.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
        capture.set(cv2.CAP_PROP_EXPOSURE, args.exposure)
    if args.gain >= 0:
        capture.set(cv2.CAP_PROP_GAIN, args.gain)

    print("Negotiated (requested in parentheses)")
    print(f"  format  {int(capture.get(cv2.CAP_PROP_FOURCC))} ({args.fourcc})")
    print(
        f"  size    {int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))}x"
        f"{int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))} ({args.width}x{args.height})"
    )
    print(f"  fps     {capture.get(cv2.CAP_PROP_FPS):.1f} ({args.fps:.1f})")
    print(f"  buffer  {int(capture.get(cv2.CAP_PROP_BUFFERSIZE))} ({args.buffer})")
    print(f"  exposure {capture.get(cv2.CAP_PROP_EXPOSURE):.1f} (requested {args.exposure})")
    print(f"  auto exp {capture.get(cv2.CAP_PROP_AUTO_EXPOSURE):.1f}")
    print(f"  gain    {capture.get(cv2.CAP_PROP_GAIN):.1f} (requested {args.gain})")
    print()

    for _ in range(10):
        capture.read()

    timestamps: list[float] = []
    dropped = 0
    sample = None
    start = time.perf_counter()
    while time.perf_counter() - start < args.seconds:
        ok, frame = capture.read()
        if not ok or frame is None:
            dropped += 1
            continue
        timestamps.append(time.perf_counter())
        sample = frame
    capture.release()

    if len(timestamps) < 2:
        print(f"only {len(timestamps)} frames captured; dropped={dropped}")
        return 1

    intervals = np.diff(timestamps)
    measured = 1.0 / float(np.median(intervals))
    print("Measured")
    print(f"  frames  {len(timestamps)} over {timestamps[-1] - timestamps[0]:.2f} s, dropped {dropped}")
    print(f"  interval median {np.median(intervals) * 1000:.2f} ms, p95 {np.percentile(intervals, 95) * 1000:.2f} ms")
    print(f"  effective fps {measured:.1f}")
    print(f"  frame shape {sample.shape if sample is not None else '?'}")
    if measured < 0.9 * args.fps:
        print(
            f"\nWARNING: asked for {args.fps:.0f} fps but measured {measured:.0f} fps.  "
            "Try a smaller resolution or MJPG, and check `v4l2-ctl --list-formats-ext`."
        )
    if args.exposure < 0:
        print("\nExposure was left to the driver. Set it manually before collecting flight data.")
    if args.save and sample is not None:
        cv2.imwrite(args.save, sample)
        print(f"saved {args.save}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
