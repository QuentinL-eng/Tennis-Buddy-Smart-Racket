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

from find_port import find_port

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "impacts")


def record_batch(ser):
    """Save every impact clip in order. Label later against the video (clip N = the Nth thump in the recording).

    Writes session-<start>.csv next to the clips: n,file,host_time_s,verdict  (host_time_s is seconds since start).
    """
    t0 = time.time()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    index = os.path.join(OUT, f"session-{stamp}.csv")
    open(index, "w").write("n,file,t_s,verdict\n")
    print(f"Recording to {index}. Start the video, then throw balls. Ctrl+C to stop.")
    n, verdict = 0, ""
    try:
        while True:
            line = ser.readline().decode(errors="ignore").strip()
            if line.startswith("SHOT"):
                verdict = line
                continue
            if not line.startswith("CLIP,"):
                continue
            n += 1
            t = time.time() - t0
            clip = np.frombuffer(bytes.fromhex(line[5:]), dtype=">i2").astype("<i2")
            name = f"clip-{stamp}-{n:04d}.i16"
            clip.tofile(os.path.join(OUT, name))
            open(index, "a").write(f"{n},{name},{t:.2f},{verdict.replace(',', ';')}\n")
            print(f"#{n:3d}  t={t:6.1f}s  {verdict}")
    except KeyboardInterrupt:
        print(f"\n{n} clips saved. Next: python3 tools/label_clips.py {index}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", help="serial port; found automatically if omitted")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--batch", action="store_true",
                    help="no prompts: record every impact with a number, then label from video with tools/label_clips.py")
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    labels = os.path.join(OUT, "labels.csv")
    if not os.path.exists(labels):
        open(labels, "w").write("file,dist_cm\n")

    ser = serial.Serial(a.port or find_port(), a.baud, timeout=0.2)
    ser.write(b"c")                       # firmware toggles; check the reply
    time.sleep(0.5)
    banner = ser.read_all().decode(errors="ignore")
    if "collect mode OFF" in banner:
        ser.write(b"c")                   # it was already on; turn it back on
    if a.batch:
        record_batch(ser)
        return
    print("Listening. Hit the ball on the strings...")
    last = "0"
    while True:
        line = ser.readline().decode(errors="ignore").strip()
        if line.startswith("SHOT"):
            print(line)
        if not line.startswith("CLIP,"):
            continue
        clip = np.frombuffer(bytes.fromhex(line[5:]), dtype=">i2").astype("<i2")
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
