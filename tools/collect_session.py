#!/usr/bin/env python3
"""Record a sweet-spot data session on the PC: webcam video + racket impact clips on one clock.

    pip install pyserial opencv-python numpy
    python3 tools/collect_session.py            # port found automatically; add --port COM5 to override

Hold the racket head up over the camera, throw balls onto the strings. Every impact the racket hears is saved
with the host time it arrived; every video frame is saved with its host time. Afterwards run
`python3 tools/label_video.py data/sessions/<session>` and click where each ball landed.

Writes data/sessions/<time>/{video.avi, frames.csv, clips.csv, clips/*.i16}. Press q in the preview to stop.
"""
import argparse
import os
import queue
import threading
import time

import cv2
import numpy as np
import serial

from find_camera import find_camera
from find_port import find_port

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "sessions")


def serial_reader(ser, q, stop):
    pending = b""
    while not stop.is_set():
        pending += ser.readline()
        if not pending.endswith(b"\n"):
            continue  # a long audio line can span several serial timeouts
        line = pending.decode(errors="ignore").strip()
        pending = b""
        if line.startswith(("SHOT", "CLIP,", "CLIP_META,")):
            q.put((time.perf_counter(), line))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", help="serial port; found automatically if omitted")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--camera", type=int, help="camera index; defaults to the external USB cam (Razer Kiyo)")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=60, help="requested camera frame rate (higher = easier to find the contact frame)")
    ap.add_argument("--name", default="", help="note appended to the session folder name, e.g. racket-a")
    a = ap.parse_args()

    stamp = time.strftime("%Y%m%d-%H%M%S") + (f"-{a.name}" if a.name else "")
    out = os.path.join(ROOT, stamp)
    os.makedirs(os.path.join(out, "clips"))

    cap = cv2.VideoCapture(find_camera() if a.camera is None else a.camera,cv2.CAP_DSHOW if os.name == "nt" else cv2.CAP_ANY)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)
    cap.set(cv2.CAP_PROP_FPS, a.fps)
    ok, frame = cap.read()
    if not ok:
        raise SystemExit("camera not available")
    h, w = frame.shape[:2]
    print(f"camera {w}x{h} @ {cap.get(cv2.CAP_PROP_FPS):.0f} fps requested")
    writer = cv2.VideoWriter(os.path.join(out, "video.avi"), cv2.VideoWriter_fourcc(*"MJPG"), a.fps, (w, h))

    ser = serial.Serial(a.port or find_port(), a.baud, timeout=0.2)
    ser.write(b"c")
    time.sleep(0.5)
    if "collect mode OFF" in ser.read_all().decode(errors="ignore"):
        ser.write(b"c")                          # was already on; switch it back on
    q, stop = queue.Queue(), threading.Event()
    threading.Thread(target=serial_reader, args=(ser, q, stop), daemon=True).start()

    frames_f = open(os.path.join(out, "frames.csv"), "w")
    frames_f.write("frame,t_s\n")
    clips_f = open(os.path.join(out, "clips.csv"), "w")
    clips_f.write("n,file,t_s,verdict,clipped,impact_t_s,samples\n")
    t0 = time.perf_counter()
    n_frame, n_clip, n_sat, verdict, flash_until = 0, 0, 0, "", 0.0
    impact_t = None
    print("Recording. Throw balls. Press q in the video window to stop.")
    while True:
        ok, frame = cap.read()
        t = time.perf_counter() - t0
        if not ok:
            break
        writer.write(frame)
        frames_f.write(f"{n_frame},{t:.4f}\n")
        n_frame += 1
        while not q.empty():
            tr, line = q.get()
            if line.startswith("SHOT"):
                verdict = line
                impact_t = None
                continue
            if line.startswith("CLIP_META,"):
                meta = dict(part.split("=", 1) for part in line.split(",")[1:])
                impact_t = tr - t0 - int(meta["trigger_age_us"]) / 1e6
                continue
            n_clip += 1
            name = f"clips/clip-{n_clip:04d}.i16"
            clip = np.frombuffer(bytes.fromhex(line[5:]), dtype=">i2").astype("<i2")
            clip.tofile(os.path.join(out, name))
            sat = int((np.abs(clip.astype(int)) >= 30000).sum())      # samples near the mic's full scale
            n_sat += sat >= 10
            onset = f"{impact_t:.4f}" if impact_t is not None else ""
            clips_f.write(f"{n_clip},{name},{tr - t0:.4f},{verdict.replace(',', ';')},{sat},{onset},{clip.size}\n")
            clips_f.flush()
            print(f"#{n_clip:3d}  t={tr - t0:6.1f}s  {clip.size / 16:.1f} ms  {verdict}" + (f"   ** CLIPPED ({sat} samples near full scale)" if sat >= 10 else ""))
            flash_until = time.perf_counter() + 0.3
        if n_frame % 5 == 0:
            frames_f.flush()
        view = frame.copy()
        cv2.putText(view, f"impacts: {n_clip}", (12, 36), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 255), 2)
        if time.perf_counter() < flash_until:
            cv2.rectangle(view, (0, 0), (w - 1, h - 1), (0, 255, 0), 10)
        cv2.imshow("record (q = stop)", cv2.resize(view, (w // 2, h // 2)))
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break
    stop.set()
    writer.release()
    cap.release()
    cv2.destroyAllWindows()
    frames_f.close(); clips_f.close()
    real_fps = n_frame / max(t, 1e-6)
    if n_sat:
        print(f"WARNING: {n_sat}/{n_clip} clips hit the mic's full scale; those sounds are distorted. Reduce the mic's exposure and retest.")
    print(f"{n_clip} impacts, {n_frame} frames ({real_fps:.1f} fps actual).\nNext: python3 tools/label_video.py {out}")


if __name__ == "__main__":
    main()
