#!/usr/bin/env python3
"""Collect labelled taps from the racket handle (data for the tap-location model).

Flash the probe first:

    cd firmware && pio run -e tapprobe -t upload

then run this (Windows: use the COM port, macOS/Linux: /dev/cu.usbmodemXXXX):

    python3 tools/collect_taps.py --port COM16

Tap the handle at the site it asks for (tap - pause - tap, with a fingernail or something small and hard).
Every tap the probe catches is queued and saved as one .npz in data/taps/<site>/:

    imu_us  (N,)    micros() of each IMU read (the probe's clock)
    imu_mg  (N,3)   low-g accelerometer in mg, 6.67 kHz sample rate
    mic_us  (M,)    micros() of each mic sample, on the same clock (16 kHz)
    mic     (M,)    int16 mic samples, M = 384 (~24 ms, starts 4 ms before the trigger)
    site            the label you were asked for

Then: python3 tools/analyze_taps.py
"""
import argparse
import glob
import os
import queue
import re
import threading
import time

import numpy as np
import serial

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "taps")

SITES = [
    ("butt", "the very end, on the butt cap"),
    ("grip_lo", "on the grip, ~70 mm from the butt (just above the hand)"),
    ("grip_hi", "on the grip, ~150 mm from the butt (just below the throat)"),
    ("throat", "up at the throat / shaft, just above the handle"),
]

MIC_US = 62.5          # 16 kHz
MIC_PRE = 64           # samples the probe keeps before the trigger


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--reps", type=int, default=12, help="taps per site")
    ap.add_argument("--sites", default=",".join(s for s, _ in SITES), help="comma-separated site order")
    ap.add_argument("--ball", action="store_true", help="also collect 10 ball hits on the strings (contrast set)")
    ap.add_argument("--seconds", type=float, default=0, help="just listen for this long and print a summary")
    a = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    ser = serial.Serial(a.port, a.baud, timeout=0.05)
    caps = queue.Queue()
    threading.Thread(target=read_serial, args=(ser, caps), daemon=True).start()

    if a.seconds:
        t0 = time.time()
        n = 0
        while time.time() - t0 < a.seconds:
            for one in drain(caps):
                n += 1
                print(f"capture {n}: {len(one['imu_us'])} IMU samples, mic peak {one['peak']}, "
                      f"imu t0 {one['imu_us'][0]}, mic start {one['mic_us'][0]}")
                if n >= 3:
                    return
            time.sleep(0.02)
        print(f"heard {n} captures in {a.seconds:.0f}s")
        return

    sites = [(s, dict(SITES).get(s, s)) for s in a.sites.split(",") if s]
    pending = []
    try:
        for site, blurb in sites:
            os.makedirs(os.path.join(OUT, site), exist_ok=True)
            print(f"\n=== site '{site}': {blurb} ===")
            got = 0
            while got < a.reps:
                pending.extend(drain(caps))
                if not pending:
                    time.sleep(0.01)
                    continue
                one = pending[0]
                ans = input(f"  [{len(pending)} queued] tap #{got + 1}/{a.reps} at '{site}'? "
                            "(Enter = keep, 'x' = discard, 'q' = stop): ").strip().lower()
                if ans == "q":
                    raise KeyboardInterrupt
                pending.pop(0)
                if ans == "x":
                    continue
                save(one, site)
                got += 1
                print(f"  saved {got}/{a.reps}  (mic peak {one['peak']}, "
                      f"{len(one['imu_us'])} IMU samples)")
            print(f"  {site} done" if got else "  nothing captured")

        if a.ball:
            os.makedirs(os.path.join(OUT, "ball"), exist_ok=True)
            print("\n=== contrast set: bounce a ball on the strings ~10 times ===")
            got = 0
            while got < 10:
                pending.extend(drain(caps))
                if not pending:
                    time.sleep(0.01)
                    continue
                one = pending.pop(0)
                ans = input(f"  [{len(pending)} queued] ball hit #{got + 1}/10? "
                            "(Enter = keep, 'x' = discard, 'q' = stop): ").strip().lower()
                if ans == "q":
                    raise KeyboardInterrupt
                if ans == "x":
                    continue
                save(one, "ball")
                got += 1
                print(f"  saved {got}/10 (mic peak {one['peak']})")
    except KeyboardInterrupt:
        print("\nstopped early")
    finally:
        ser.close()
    print(f"\nFiles in {OUT}. Next: python3 tools/analyze_taps.py")


def drain(caps):
    out = []
    while True:
        try:
            out.append(caps.get_nowait())
        except queue.Empty:
            return out


def save(cap, site):
    n = len(glob.glob(os.path.join(OUT, site, "tap-*.npz")))
    path = os.path.join(OUT, site, f"tap-{int(time.time() * 1000)}-{n:03d}.npz")
    np.savez_compressed(path, imu_us=cap["imu_us"], imu_mg=cap["imu_mg"],
                        mic_us=cap["mic_us"], mic=cap["mic"], site=site)
    return path


def read_serial(ser, caps):
    """Parse the probe's dump format:

        PT <n>                          start of a capture
        I <16 x (ax,ay,az) hex>         IMU samples in mg, oldest first
        M <64 x mic hex>                mic samples, oldest first
        T0 <t0_us> <n> <dt_us> <mic_trig_us>
        CAP <seq> mic_peak <v>
    """
    pt = None
    mic_trig = 0
    while True:
        try:
            raw = ser.readline()
        except (OSError, TypeError):   # TypeError: pyserial raises it when the handle is torn down
            return
        if not raw:
            continue
        line = raw.decode(errors="ignore").rstrip("\r\n")
        if line.startswith("PT "):
            pt = {"imu_mg": [], "mic": []}
        elif line.startswith("I ") and pt is not None:
            h = line[2:].replace(" ", "")
            vals = np.frombuffer(bytes.fromhex(h), dtype=">i2").astype(np.int16)
            pt["imu_mg"].append(vals.reshape(-1, 3))
        elif line.startswith("M ") and pt is not None:
            h = line[2:].replace(" ", "")
            pt["mic"].append(np.frombuffer(bytes.fromhex(h), dtype=">i2").astype(np.int16))
        elif line.startswith("T0 ") and pt is not None:
            m = re.match(r"T0 (\d+) (\d+) (\d+) (\d+)", line)
            if m:
                t0, n, dt, trig = (int(m.group(i)) for i in (1, 2, 3, 4))
                imu = np.concatenate(pt["imu_mg"])[:n] if pt["imu_mg"] else np.zeros((0, 3), np.int16)
                if len(imu):
                    dt = dt or 150
                    pt["imu_us"] = t0 + np.arange(len(imu), dtype=np.int64) * dt
                pt["imu_mg"] = imu
                mic = np.concatenate(pt["mic"]) if pt["mic"] else np.zeros(0, np.int16)
                # The clip starts MIC_PRE samples before the trigger, so anchor it there.
                pt["mic_us"] = (trig - MIC_PRE * MIC_US +
                                np.arange(len(mic), dtype=np.float64) * MIC_US).astype(np.int64)
                pt["mic"] = mic
                pt["mic_trig"] = trig
        elif line.startswith("CAP ") and pt is not None:
            m = re.match(r"CAP \d+ mic_peak (-?\d+)", line)
            pt["peak"] = int(m.group(1)) if m else 0
            if len(pt.get("imu_us", [])) and len(pt.get("mic", [])):
                caps.put(pt)
            pt = None


if __name__ == "__main__":
    main()
