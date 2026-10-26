#!/usr/bin/env python3
"""Collect labelled impact-sound clips from the racket over USB serial (training data for ml/train.py).

    pip install pyserial
    python3 tools/collect_clips.py --port /dev/cu.usbmodem1101

Workflow (matches the app's drop-grid calibration): drop/hit a ball at a known spot on the strings, a clip
appears, type how far from the sweet-spot centre it landed in cm (0 = dead centre). Enter repeats the last
value, 'x' discards a false trigger, 'q' quits. Files go to data/impacts/ with a labels.csv that
`python3 ml/train.py --real data/impacts` reads.
"""
import argparse
import os
import time

import numpy as np
import serial

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "impacts")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    labels = os.path.join(OUT, "labels.csv")
    if not os.path.exists(labels):
        open(labels, "w").write("file,dist_cm\n")

    ser = serial.Serial(a.port, a.baud, timeout=0.2)
    ser.write(b"c")                       # firmware toggles; check the reply
    time.sleep(0.5)
    banner = ser.read_all().decode(errors="ignore")
    if "collect mode OFF" in banner:
        ser.write(b"c")                   # it was already on; turn it back on
    print("Listening. Hit the ball on the strings...")
    last = "0"
    while True:
        line = ser.readline().decode(errors="ignore").strip()
        if line.startswith("SHOT"):
            print(line)
        if not line.startswith("CLIP,"):
            continue
        clip = np.frombuffer(bytes.fromhex(line[5:]), dtype="<i2")
        ans = input(f"  distance from sweet spot in cm [{last}] (x = discard, q = quit): ").strip() or last
        if ans == "q":
            break
        if ans == "x":
            continue
        last = ans
        name = f"clip-{int(time.time() * 1000)}.i16"
        clip.tofile(os.path.join(OUT, name))
        open(labels, "a").write(f"{name},{float(ans)}\n")
        print("  saved", name)


if __name__ == "__main__":
    main()
