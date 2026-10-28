#!/usr/bin/env python3
"""Scale every label from the racket's own string-bed area (100 in^2), using SAM masks. Replaces sam_refine.py.

    python3 tools/sam_scale.py data/sessions/<session>            # asks before uploading frames
    python3 tools/sam_scale.py data/sessions/<session> --head-area 100

For each labelled frame SAM segments the strings ("racket strings": the inside of the frame) and, as a backup, the
whole head ("racket head"). The inside mask's pixel area is set equal to the racket's nominal head size, which gives
pixels-per-cm for that frame, and its centroid is the string-bed centre. Distances are recomputed from the ball
pixel saved by label_video.py. If the inside mask looks wrong (hand in the way, ratio to the head mask off) the head
mask times the usual inside/head ratio is used instead; frames with neither are dropped from labels.csv and listed
in unscaled.txt. Originals stay in labels_unscaled.csv. Masks are cached in sam_cache.json under "__masks__".
Needs: pip install meta-sam-parser openai
"""
import argparse
import base64
import csv
import json
import math
import os
import sys

import cv2
import numpy as np

import meta_sam_parser as msp
from sam_prefill import api_key

CM2_PER_IN2 = 2.54 ** 2
PROMPTS = {"inner": "racket strings", "head": "racket head"}


def ask_mask(client, prompt, frame, send_w=640, min_conf=0.3):
    """Best mask for the prompt as {area_px, cx, cy, conf} in the original frame's pixels, or None."""
    h0, w0 = frame.shape[:2]
    small = cv2.resize(frame, (send_w, int(h0 * send_w / w0)))
    ok, jpg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 85])
    url = "data:image/jpeg;base64," + base64.b64encode(jpg.tobytes()).decode()
    text = ""
    with client.responses.stream(
        model="sam-3.1",
        input=[{"type": "message", "role": "user",
                "content": [{"type": "input_text", "text": prompt}, {"type": "input_image", "image_url": url}]}],
        metadata={"include_confidence": "true"},
    ) as stream:
        for ev in stream:
            if ev.type == "response.output_text.delta":
                text += ev.delta
    parser = msp.image_segmentation_format().create_parser()
    parser.push(text)
    records = [r for r in parser.finish(msp.CompletedOutcome()).result.records if hasattr(r, "mask")]
    records = [r for r in records if (r.confidence or 0) >= min_conf]
    if not records:
        return None
    r = max(records, key=lambda r: r.confidence or 0)
    ras = np.frombuffer(msp.decode_mask_to_raster(r.mask), np.uint8).reshape(r.mask.height, r.mask.width) > 0
    ys, xs = np.nonzero(ras)
    if len(xs) == 0:
        return None
    k = w0 / send_w
    return {"area_px": float(len(xs)) * k * k, "cx": float((r.bounds.left + xs.mean() + 0.5) * k),
            "cy": float((r.bounds.top + ys.mean() + 0.5) * k), "conf": float(r.confidence or 0)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("--head-area", type=float, default=100.0, help="nominal head size, square inches")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--width", type=int, default=640)
    a = ap.parse_args()
    d = a.session
    area_cm2 = a.head_area * CM2_PER_IN2

    cal = json.load(open(os.path.join(d, "calibration.json")))
    up = np.array(cal["up"]); right = np.array([-up[1], up[0]])
    pos_p, lab_p, unscaled_p = (os.path.join(d, n) for n in ("positions.csv", "labels.csv", "labels_unscaled.csv"))
    if not os.path.exists(unscaled_p):
        import shutil
        shutil.copy(lab_p, unscaled_p)
    rows = [r[:8] for r in csv.reader(open(pos_p)) if r and r[0] != "file"]
    labelled = [r for r in rows if len(r) >= 8]
    all_files = [r[0] for r in csv.reader(open(unscaled_p)) if r and r[0] != "file"]

    cache_p = os.path.join(d, "sam_cache.json")
    cache = json.load(open(cache_p)) if os.path.exists(cache_p) else {}
    masks = cache.setdefault("__masks__", {})               # "frame:kind" -> mask dict or null
    frames = sorted({int(r[3]) for r in labelled} | {cal.get("frame")} - {None})
    need = [(f, k) for f in frames for k in PROMPTS if f"{f}:{k}" not in masks]
    print(f"{len(labelled)} labelled impacts; {len(need)} SAM requests needed, about ${len(need) * 2.5 / 1000:.2f}.")
    if need:
        key = api_key()
        if not key:
            sys.exit("No key: put MUSE_API_KEY=... in the repo-root .env")
        if not a.yes and input("Upload those frames to Meta? [y/N] ").lower() != "y":
            return
        from openai import OpenAI
        client = OpenAI(base_url="https://api.meta.ai/v1", api_key=key)
        cap = cv2.VideoCapture(os.path.join(d, "video.avi"))
        cur_f, frame = None, None
        for i, (f, k) in enumerate(need):
            if f != cur_f:
                cap.set(cv2.CAP_PROP_POS_FRAMES, f)
                ok, frame = cap.read()
                cur_f = f
            masks[f"{f}:{k}"] = ask_mask(client, PROMPTS[k], frame, a.width) if ok else None
            if i % 10 == 0:
                json.dump(cache, open(cache_p, "w"))
                print(f"  {i + 1}/{len(need)}")
        json.dump(cache, open(cache_p, "w"))

    pairs = [(masks.get(f"{f}:inner"), masks.get(f"{f}:head")) for f in frames]
    ratios = [i["area_px"] / h["area_px"] for i, h in pairs if i and h]
    if not ratios:
        sys.exit("SAM found no usable masks.")
    med = float(np.median(ratios))
    print(f"inside/head area ratio: median {med:.2f} (range {min(ratios):.2f} to {max(ratios):.2f})")

    def source(f):
        i, h = masks.get(f"{f}:inner"), masks.get(f"{f}:head")
        if i and (not h or 0.8 * med <= i["area_px"] / h["area_px"] <= 1.15 * med):
            return i["area_px"], i["cx"], i["cy"], "inner"
        if h:
            return h["area_px"] * med, h["cx"], h["cy"], "head"
        return None

    out, dropped, ppcs, off = [], [], [], []
    labels = {}
    for r in labelled:
        src = source(int(r[3]))
        if src is None:
            dropped.append(r[0])
            continue
        area_px, cx, cy, kind = src
        ppc = math.sqrt(area_px / area_cm2)
        dv = np.array([float(r[4]) - cx, float(r[5]) - cy])
        x, y = float(dv @ right) / ppc, float(dv @ up) / ppc
        labels[r[0]] = f"{math.hypot(x, y):.2f}"
        ppcs.append(ppc)
        off.append(math.hypot(cx - float(r[6]), cy - float(r[7])))
        out.append([r[0], f"{x:.2f}", f"{y:.2f}", *r[3:8], f"{ppc / cal['ppc']:.3f}", f"{cx:.0f}", f"{cy:.0f}", f"{ppc:.2f}", kind])
    dropped += [f for f in all_files if f not in labels and f not in dropped]

    with open(lab_p, "w") as fh:
        fh.write("file,dist_cm\n" + "".join(f"{k},{v}\n" for k, v in labels.items()))
    with open(pos_p, "w") as fh:
        fh.write("file,x_cm,y_cm,frame,ball_x,ball_y,centre_x,centre_y,scale,mask_cx,mask_cy,ppc,area_src\n"
                 + "".join(",".join(r) + "\n" for r in out))
    open(os.path.join(d, "unscaled.txt"), "w").write("\n".join(dropped))
    kinds = [r[-1] for r in out]
    dist = np.array([float(v) for v in labels.values()])
    ci = masks.get(f"{cal.get('frame')}:inner")
    print(f"{len(labels)} labels rescaled ({kinds.count('inner')} from the inside mask, {kinds.count('head')} from the head mask), "
          f"{len(dropped)} dropped (listed in unscaled.txt)")
    print(f"pixels per cm: {min(ppcs):.1f} to {max(ppcs):.1f}, median {np.median(ppcs):.1f}; "
          f"your calibration said {cal['ppc']:.2f}" + (f" and the inside mask at frame {cal['frame']} says {math.sqrt(ci['area_px'] / area_cm2):.2f}" if ci else ""))
    print(f"mask centre vs your clicked centre: median {np.median(off):.0f} px apart")
    print(f"distance from centre: within 4 cm {int((dist <= 4).sum())}, 4-8 cm {int(((dist > 4) & (dist <= 8)).sum())}, over 8 cm {int((dist > 8).sum())}, median {np.median(dist):.1f} cm")


if __name__ == "__main__":
    main()
