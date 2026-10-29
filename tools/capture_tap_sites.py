#!/usr/bin/env python3
"""Guided tap capture: tap the handle at one marked site at a time, hands-off.

    python3 tools/capture_tap_sites.py --port COM16 --site butt --n 10
    python3 tools/capture_tap_sites.py --port COM16 --all      # every site, in order

Flash the probe first: cd firmware && pio run -e tapprobe -t upload

It prints a 5-4-3-2-1 countdown, then you have a fixed window to tap. Every capture the racket sends is
saved under data/taps/<site>/ with the same fields as collect_taps.py, plus a live jolt reading so you can
see whether the tap registered.

Site labels and where to aim (measured from the butt cap, along the handle):

    butt        the very end, on the butt cap itself
    grip_60     ~60 mm up the handle
    grip_120    ~120 mm (mid-handle)
    grip_180    ~180 mm (just below the throat)
    throat      the shaft above the handle
"""
import argparse
import os
import queue
import sys
import threading
import time

import numpy as np
import serial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import collect_taps as ct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "taps")
SITES = ["butt", "grip_60", "grip_120", "grip_180", "throat"]


def run_site(ser, caps, site, n, window):
    """Countdown, then collect up to n captures during `window` seconds."""
    os.makedirs(os.path.join(OUT, site), exist_ok=True)
    print(f"\n{'=' * 66}")
    print(f"  SITE '{site}'  -  tap {n} times, firmly, in one place")
    print(f"{'=' * 66}")
    for k in range(5, 0, -1):
        print(f"    starting in {k}...", flush=True)
        time.sleep(1.0)
    print(f"    >>> TAP NOW ({window} s) <<<", flush=True)

    got, t_end = 0, time.time() + window
    while time.time() < t_end and got < n:
        try:
            one = caps.get(timeout=0.2)
        except queue.Empty:
            continue
        mag = np.linalg.norm(one["imu_mg"].astype(float), axis=1)
        jolt = mag.max() - np.median(mag[:24])
        if jolt < 300:                       # mic trigger without a jolt: a false trigger, drop it
            print(f"      (skipped: no jolt, {jolt:.0f} mg)")
            continue
        path = os.path.join(OUT, site, f"tap-{int(time.time() * 1000)}.npz")
        np.savez_compressed(path, imu_us=one["imu_us"], imu_mg=one["imu_mg"], mic_us=one["mic_us"],
                            mic=one["mic"], site=site)
        got += 1
        print(f"      {got}/{n}  jolt {jolt:6.0f} mg  mic {np.abs(one['mic']).max():5.0f}", flush=True)
    left = int(t_end - time.time())
    if got < n:
        print(f"    only {got}/{n} captured ({left}s left when you stopped)")
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--site", default=None, help="site label to tap now")
    ap.add_argument("--all", action="store_true", help="walk through every site")
    ap.add_argument("--n", type=int, default=10, help="taps per site")
    ap.add_argument("--window", type=float, default=25.0, help="seconds to allow per site")
    a = ap.parse_args()

    sites = SITES if a.all else ([a.site] if a.site else None)
    if not sites:
        ap.error("pass --site <name> or --all")

    ser = serial.Serial(a.port, 115200, timeout=0.05)
    time.sleep(1.2)
    ser.reset_input_buffer()
    caps = queue.Queue()
    threading.Thread(target=ct.read_serial, args=(ser, caps), daemon=True).start()
    total = 0
    try:
        for site in sites:
            total += run_site(ser, caps, site, a.n, a.window)
            time.sleep(1.5)
    finally:
        ser.close()
    print(f"\n{total} taps saved under {OUT}/")
    print("Next: python3 tools/analyze_taps.py data/taps   (per-site separability)")


if __name__ == "__main__":
    main()
