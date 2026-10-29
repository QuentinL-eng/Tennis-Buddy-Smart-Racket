#!/usr/bin/env python3
"""Rescale labelled distances per impact from the racket head's size in the frame (needs SAM boxes).

    python3 tools/sam_refine.py data/sessions/<session>                # asks before uploading
    python3 tools/sam_refine.py data/sessions/<session> --cal-frame 812   # if calibration.json has no frame

The calibration gives centimetres-per-pixel at one racket distance. When the racket moves toward or away from the
camera it looks bigger or smaller, so each label is rescaled by (head box height in that frame) / (head box height in
the calibration frame). The head boxes come from sam_cache.json, or one SAM request per frame that lacks one.
Originals are kept in labels_unscaled.csv; positions.csv gains a `scale` column. Re-running is safe.
"""
import argparse
import csv
import json
import math
import os
import shutil
import sys

import cv2
import numpy as np

from sam_prefill import api_key, ask


def head_height(boxes, min_c=0.3):
    boxes = [b for b in boxes if b[4] >= min_c]
    if not boxes:
        return None
    b = max(boxes, key=lambda b: b[4])
    return b[3] - b[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("--cal-frame", type=int, help="frame used for calibration (older calibration.json lacks it)")
    ap.add_argument("--racket", default="racket head")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--yes", action="store_true")
    a = ap.parse_args()
    d = a.session

    cal = json.load(open(os.path.join(d, "calibration.json")))
    cal_frame = a.cal_frame if a.cal_frame is not None else cal.get("frame")
    if cal_frame is None:
        sys.exit("calibration.json has no frame number. Run label_video.py and press c to recalibrate "
                 "(it records the frame), or pass --cal-frame N.")

    pos_p, lab_p, unscaled_p = (os.path.join(d, n) for n in ("positions.csv", "labels.csv", "labels_unscaled.csv"))
    if not os.path.exists(unscaled_p):
        shutil.copy(lab_p, unscaled_p)                      # keep the first, unscaled labels
    rows = [r for r in csv.reader(open(pos_p)) if r and r[0] != "file"]
    rows = [r[:8] for r in rows]                            # drop a `scale` column from an earlier run
    todo = [r for r in rows if len(r) >= 8]
    skipped = len(rows) - len(todo)

    cache_p = os.path.join(d, "sam_cache.json")
    cache = json.load(open(cache_p)) if os.path.exists(cache_p) else {}
    heads = cache.setdefault("__frames__", {})              # frame -> head box height, shared across impacts

    def known(frame):
        if str(frame) in heads:
            return True
        for clip, fr in cache.items():
            if clip != "__frames__" and str(frame) in fr and head_height(fr[str(frame)].get("racket", [])):
                heads[str(frame)] = head_height(fr[str(frame)]["racket"])
                return True
        return False

    need = sorted({int(r[3]) for r in todo} | {cal_frame})
    need = [f for f in need if not known(f)]
    print(f"{len(todo)} labels to rescale ({skipped} without pixel positions are left as they are); "
          f"{len(need)} frames need a SAM request, about ${len(need) * 2.5 / 1000:.2f}.")
    if need:
        key = api_key()
        if not key:
            sys.exit("No key: put MUSE_API_KEY=... in the repo-root .env")
        if not a.yes and input("Upload those frames to Meta? [y/N] ").lower() != "y":
            return
        from openai import OpenAI
        client = OpenAI(base_url="https://api.meta.ai/v1", api_key=key)
        cap = cv2.VideoCapture(os.path.join(d, "video.avi"))
        for k, f in enumerate(need):
            cap.set(cv2.CAP_PROP_POS_FRAMES, f)
            ok, frame = cap.read()
            if not ok:
                continue
            _, boxes = ask(client, a.racket, frame, a.width)
            h = head_height(boxes)
            if h:
                heads[str(f)] = h
            print(f"{k + 1}/{len(need)} frame {f}: head height {h}")
            json.dump(cache, open(cache_p, "w"))

    ref = heads.get(str(cal_frame))
    if not ref:
        sys.exit(f"SAM found no racket head in the calibration frame ({cal_frame}); try --cal-frame with a clearer frame.")

    up = np.array(cal["up"]); right = np.array([-up[1], up[0]])
    labels = {r[0]: r[1] for r in csv.reader(open(unscaled_p)) if r and r[0] != "file"}
    out_rows, n_scaled = [], 0
    for r in rows:
        f = r[0]
        h = heads.get(r[3]) if len(r) >= 8 else None
        if h is None:
            out_rows.append(r + ["1.000"])
            continue
        scale = h / ref
        ball = np.array([float(r[4]), float(r[5])]); centre = np.array([float(r[6]), float(r[7])])
        dv = ball - centre
        ppc = cal["ppc"] * scale
        x, y = float(dv @ right) / ppc, float(dv @ up) / ppc
        labels[f] = f"{math.hypot(x, y):.2f}"
        out_rows.append([f, f"{x:.2f}", f"{y:.2f}", *r[3:8], f"{scale:.3f}"])
        n_scaled += 1
    with open(lab_p, "w") as fh:
        fh.write("file,dist_cm\n" + "".join(f"{k},{v}\n" for k, v in labels.items()))
    with open(pos_p, "w") as fh:
        fh.write("file,x_cm,y_cm,frame,ball_x,ball_y,centre_x,centre_y,scale\n" + "".join(",".join(r) + "\n" for r in out_rows))
    sc = [float(r[-1]) for r in out_rows if r[-1] != "1.000"]
    print(f"rescaled {n_scaled} labels" + (f" (scale {min(sc):.2f} to {max(sc):.2f}, median {np.median(sc):.2f})" if sc else ""))


if __name__ == "__main__":
    main()
