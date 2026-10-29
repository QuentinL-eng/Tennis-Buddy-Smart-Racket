#!/usr/bin/env python3
"""Look at what the probe captured: print (or plot) one tap window, and summarise a whole directory.

    python3 tools/analyze_taps.py --port COM16             # capture one live tap and describe it
    python3 tools/analyze_taps.py data/taps/butt/tap-*.npz # describe saved captures
    python3 tools/analyze_taps.py --plot data/taps/butt    # plot every capture in a directory

What it reports per capture: the IMU jolt (peak |a| and how many samples over 1 g), where the onset is in
the window, and the mic onset relative to it. Those two onsets are the position cue: a tap closer to the
butt cap reaches the IMU before the mic, and vice versa.
"""
import argparse
import glob
import os
import sys

import numpy as np

TAPROBE_PORT = "COM16"


def load(path):
    d = np.load(path, allow_pickle=False)
    return d


def describe(d, name="", verbose=True):
    a = d["imu_mg"].astype(np.float64)                       # (N,3) mg
    t_imu = d["imu_us"].astype(np.float64) / 1e6             # s
    mic = d["mic"].astype(np.float64)
    t_mic = d["mic_us"].astype(np.float64) / 1e6

    mag = np.linalg.norm(a, axis=1)                          # mg
    # The probe records absolute acceleration: gravity is ~1000 mg, a tap adds a fast transient on top of it.
    hp = np.abs(np.diff(mag, prepend=mag[0]))                # |da| between samples
    onset = int(np.argmax(hp > 300)) if (hp > 300).any() else int(np.argmax(mag))
    jolt = mag[onset:onset + 20]

    mic_env = np.abs(mic)
    mic_onset = int(np.argmax(mic_env > max(120, 4 * np.median(mic_env[:200]))))

    if verbose:
        print(f"{name or '':28s} n={len(a):3d} @ {1e6 * len(a) / (t_imu[-1] - t_imu[0]):.0f} Hz  "
              f"peak {mag.max():6.0f} mg  jolt {jolt.max() - mag[:8].mean():6.0f} mg  "
              f"onset#{onset:3d}  mic peak {np.abs(mic).max():5.0f} @ #{mic_onset}")
        print(f"{'':28s} pre-tap baseline {np.linalg.norm(a[:8], axis=1).mean():6.0f} mg  "
              f"quiet after {np.linalg.norm(a[-8:], axis=1).mean():6.0f} mg  "
              f"gyro? ---   axis at onset: {a[onset].astype(int)}")
    return {"onset": onset, "peak": mag.max(), "mic_onset": mic_onset, "n": len(a)}


def plot(paths):
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(len(paths), 2, figsize=(13, 2.2 * len(paths)), squeeze=False)
    for r, p in enumerate(paths):
        d = load(p)
        a = d["imu_mg"].astype(np.float64)
        t = (d["imu_us"] - d["imu_us"][0]) / 1000.0           # ms
        tm = (d["mic_us"] - d["imu_us"][0]) / 1000.0          # ms, same clock
        ax[r][0].plot(t, a[:, 0], "r", lw=1, label="ax")
        ax[r][0].plot(t, a[:, 1], "g", lw=1, label="ay")
        ax[r][0].plot(t, a[:, 2], "b", lw=1, label="az")
        ax[r][0].set_ylabel("mg")
        ax[r][0].set_title(os.path.basename(p), fontsize=8)
        ax[r][0].legend(fontsize=6)
        ax[r][1].plot(tm, d["mic"], "k", lw=0.6)
        ax[r][1].set_ylabel("mic")
    ax[-1][0].set_xlabel("ms")
    ax[-1][1].set_xlabel("ms")
    plt.tight_layout()
    plt.show()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*", help="saved .npz captures, or a directory")
    ap.add_argument("--plot", action="store_true")
    ap.add_argument("--port", default=None, help="capture one live tap from the probe on this port")
    a = ap.parse_args()

    if a.port:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import collect_taps as ct
        import queue
        import threading
        import serial
        ser = serial.Serial(a.port, 115200, timeout=0.05)
        caps = queue.Queue()
        threading.Thread(target=ct.read_serial, args=(ser, caps), daemon=True).start()
        print("tap the handle...")
        one = caps.get()
        ser.close()
        d = {"imu_us": one["imu_us"], "imu_mg": one["imu_mg"], "mic_us": one["mic_us"], "mic": one["mic"]}
        describe(d, "live capture")
        if a.plot:
            plot(["-"]) if False else None
            import matplotlib.pyplot as plt
            t = (d["imu_us"] - d["imu_us"][0]) / 1000.0
            tm = (d["mic_us"] - d["imu_us"][0]) / 1000.0
            fig, axes = plt.subplots(1, 2, figsize=(13, 3))
            axes[0].plot(t, d["imu_mg"])
            axes[1].plot(tm, d["mic"], "k", lw=0.6)
            plt.show()
        return

    paths = []
    for p in a.paths:
        paths.extend(sorted(glob.glob(os.path.join(p, "*.npz"))) if os.path.isdir(p) else [p])
    if not paths:
        ap.error("give a path, a directory, or --port")
    rows = [describe(load(p), os.path.basename(os.path.dirname(p)) + "/" + os.path.basename(p))
            for p in paths]
    if len(rows) > 1:
        onsets = np.array([r["onset"] for r in rows])
        print(f"\n{len(rows)} captures, onset#{onsets.mean():.1f} +/- {onsets.std():.1f}")
    if a.plot:
        plot(paths)


if __name__ == "__main__":
    main()
