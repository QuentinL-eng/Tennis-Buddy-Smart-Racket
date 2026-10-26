#!/usr/bin/env python3
"""Inspect a Tennis Buddy raw recording (.tbrec) or its CSV export.

Prints sample rate, gaps, sensor ranges and detected impacts, and optionally plots them.

    python3 tools/analyze_recording.py data/session-2026-10-17.tbrec
    python3 tools/analyze_recording.py data/session.tbrec --plot     # needs matplotlib

Record format (little-endian, sensor axes): f64 time_s, then f32 ax ay az [g], gx gy gz [rad/s], hx hy hz [g].
"""
import argparse
import struct
import sys

import numpy as np

RECORD = struct.Struct("<d9f")


def load(path):
    if path.endswith(".csv"):
        return np.loadtxt(path, delimiter=",", skiprows=1)
    data = open(path, "rb").read()
    n = len(data) // RECORD.size
    return np.array([RECORD.unpack_from(data, i * RECORD.size) for i in range(n)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--plot", action="store_true")
    ap.add_argument("--threshold", type=float, default=10.0, help="high-g jump (g over 3 ms) that counts as an impact")
    args = ap.parse_args()

    d = load(args.path)
    if len(d) < 10:
        sys.exit("recording is empty")
    t, acc, gyro, hi = d[:, 0], d[:, 1:4], d[:, 4:7], d[:, 7:10]
    dt = np.diff(t)
    print(f"{len(d)} samples over {t[-1] - t[0]:.1f} s  →  {1 / np.median(dt):.0f} Hz median")
    print(f"gaps > 5 ms: {(dt > 0.005).sum()}  (largest {dt.max() * 1000:.0f} ms)")
    print(f"MPU accel |a| max {np.linalg.norm(acc, axis=1).max():.1f} g   (saturates at 16 g)")
    print(f"gyro |w| max {np.degrees(np.linalg.norm(gyro, axis=1)).max():.0f} deg/s   (saturates at 2000)")
    print(f"H3LIS |a| max {np.linalg.norm(hi, axis=1).max():.0f} g")

    jump = np.linalg.norm(hi[3:] - hi[:-3], axis=1)
    impacts, last = [], -1.0
    for i in np.where(jump > args.threshold)[0]:
        if t[i + 3] - last > 0.4:
            impacts.append(i + 3)
            last = t[i + 3]
    print(f"\n{len(impacts)} impacts (high-g jump > {args.threshold} g):")
    for i in impacts:
        w = np.degrees(np.linalg.norm(gyro[max(0, i - 150):i], axis=1)).max()
        print(f"  t={t[i] - t[0]:7.2f} s   peak high-g {np.linalg.norm(hi[i:i + 10], axis=1).max():5.0f} g   "
              f"peak gyro before {w:5.0f} deg/s")

    if args.plot:
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(3, 1, sharex=True, figsize=(12, 8))
        x = t - t[0]
        ax[0].plot(x, np.degrees(gyro)); ax[0].set_ylabel("gyro deg/s")
        ax[1].plot(x, acc); ax[1].set_ylabel("MPU g")
        ax[2].plot(x, hi); ax[2].set_ylabel("H3LIS g")
        for i in impacts:
            for a in ax:
                a.axvline(x[i], color="k", alpha=0.3)
        ax[2].set_xlabel("s")
        plt.tight_layout()
        plt.show()


if __name__ == "__main__":
    main()
