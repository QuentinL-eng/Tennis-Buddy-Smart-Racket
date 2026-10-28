#!/usr/bin/env python3
"""Pre-fill ball and racket-head positions with Meta's SAM 3.1 API, to speed up tools/label_video.py.

    # key: MUSE_API_KEY in the repo-root .env (git-ignored), or in the environment
    python3 tools/sam_prefill.py data/sessions/<session> --probe     # 1 frame, shows raw output + annotated image
    python3 tools/sam_prefill.py data/sessions/<session> --n 3       # first 3 impacts
    python3 tools/sam_prefill.py data/sessions/<session>             # all impacts (prints the cost first)

For each impact it sends a few frames around the expected contact (JPEG, resized) twice: once asking for the ball,
once for the racket head. Boxes go to <session>/sam_cache.json; label_video.py then opens each impact on the frame
where the ball is closest to the racket head, with the ball and head-centre clicks pre-filled (click to override).
SAM only proposes; you still confirm every label. This UPLOADS video frames (including your face) to Meta.
Docs: https://dev.meta.ai/docs/media-segmentation/   Pricing: $2.50 per 1000 images.
"""
import argparse
import base64
import csv
import json
import os
import re
import sys

import cv2
import numpy as np

LAG_S = 0.08
BOX = re.compile(r"<\|box;x1=(-?\d+);y1=(-?\d+);x2=(-?\d+);y2=(-?\d+);w=(\d+);h=(\d+)(?:;c=([\d.]+))?\|>")


def api_key():
    """MUSE_API_KEY (or MODEL_API_KEY) from the environment, else from the repo-root .env. Never printed."""
    for name in ("MUSE_API_KEY", "MODEL_API_KEY"):
        if os.environ.get(name):
            return os.environ[name]
    env = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if os.path.exists(env):
        for line in open(env):
            m = re.match(r"\s*(MUSE_API_KEY|MODEL_API_KEY)\s*=\s*(.*)", line)
            if m and m.group(2).strip().strip("\"'"):
                return m.group(2).strip().strip("\"'")
    return None


def parse_boxes(text, out_w, out_h):
    """Boxes as [x1, y1, x2, y2, confidence] in the original frame's pixels (the response repeats the sent size)."""
    boxes = []
    for x1, y1, x2, y2, w, h, c in BOX.findall(text):
        sx, sy = out_w / int(w), out_h / int(h)
        boxes.append([int(x1) * sx, int(y1) * sy, (int(x2) + 1) * sx, (int(y2) + 1) * sy, float(c) if c else 1.0])
    return boxes


def ask(client, prompt, frame, send_w):
    h, w = frame.shape[:2]
    small = cv2.resize(frame, (send_w, int(h * send_w / w)))
    ok, jpg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 85])
    url = "data:image/jpeg;base64," + base64.b64encode(jpg.tobytes()).decode()
    text = ""
    with client.responses.stream(
        model="sam-3.1",
        input=[{"type": "message", "role": "user",
                "content": [{"type": "input_text", "text": prompt}, {"type": "input_image", "image_url": url}]}],
        metadata={"include_confidence": "true", "mask_encoding": "one_bit"},
    ) as stream:
        for ev in stream:
            if ev.type == "response.output_text.delta":
                text += ev.delta
    return text, parse_boxes(text, w, h)


def centre(b):
    return [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2]


def best(boxes, min_c):
    boxes = [b for b in boxes if b[4] >= min_c]
    return max(boxes, key=lambda b: b[4]) if boxes else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("--probe", action="store_true", help="one frame only; print raw output and save sam_probe.jpg")
    ap.add_argument("--n", type=int, help="only the first N impacts")
    ap.add_argument("--window", type=int, default=8, help="frames each side of the expected contact")
    ap.add_argument("--step", type=int, default=2)
    ap.add_argument("--ball", default="tennis ball")
    ap.add_argument("--racket", default="racket head")
    ap.add_argument("--width", type=int, default=640, help="width frames are resized to before upload")
    ap.add_argument("--min-conf", type=float, default=0.3)
    ap.add_argument("--yes", action="store_true", help="skip the cost confirmation")
    a = ap.parse_args()

    d = a.session
    clips = list(csv.DictReader(open(os.path.join(d, "clips.csv"))))[: a.n]
    ft = np.array([float(r["t_s"]) for r in csv.DictReader(open(os.path.join(d, "frames.csv")))])
    cap = cv2.VideoCapture(os.path.join(d, "video.avi"))
    n_frames = min(int(cap.get(cv2.CAP_PROP_FRAME_COUNT)), len(ft))
    cache_p = os.path.join(d, "sam_cache.json")
    cache = json.load(open(cache_p)) if os.path.exists(cache_p) else {}

    def frames_for(c):
        g = int(np.searchsorted(ft, float(c["t_s"]) - LAG_S))
        return [f for f in range(g - a.window, g + a.window + 1, a.step) if 0 <= f < n_frames]

    todo = [(c, f) for c in clips for f in frames_for(c) if str(f) not in cache.get(c["file"], {})]
    if a.probe:
        todo = todo[len(todo) // 2: len(todo) // 2 + 1]
    n_img = 2 * len(todo)
    print(f"{len(todo)} frames x 2 prompts = {n_img} images, about ${n_img * 2.5 / 1000:.2f} at $2.50 per 1000.")
    if not todo:
        return
    key = api_key()
    if not key:
        sys.exit("No key: put MUSE_API_KEY=... in the repo-root .env (or set it in the environment).")
    if not (a.yes or a.probe or a.n) and input("Upload these frames to Meta? [y/N] ").lower() != "y":
        return

    from openai import OpenAI
    client = OpenAI(base_url="https://api.meta.ai/v1", api_key=key)

    for k, (c, f) in enumerate(todo):
        cap.set(cv2.CAP_PROP_POS_FRAMES, f)
        ok, frame = cap.read()
        if not ok:
            continue
        res = {}
        for name, prompt in (("ball", a.ball), ("racket", a.racket)):
            try:
                text, boxes = ask(client, prompt, frame, a.width)
            except Exception as e:                       # network / quota: keep what we have
                print("request failed:", e)
                json.dump(cache, open(cache_p, "w"))
                sys.exit(1)
            res[name] = boxes
            if a.probe:
                print(f"--- {name} ({prompt!r}) raw ---\n{text[:600]}\nparsed boxes: {boxes}")
        cache.setdefault(c["file"], {})[str(f)] = res
        json.dump(cache, open(cache_p, "w"))
        print(f"{k + 1}/{len(todo)}  impact {c['n']} frame {f}: ball {len(res['ball'])} racket {len(res['racket'])}")
        if a.probe:
            v = frame.copy()
            for name, col in (("ball", (0, 255, 255)), ("racket", (255, 128, 0))):
                for b in res[name]:
                    cv2.rectangle(v, (int(b[0]), int(b[1])), (int(b[2]), int(b[3])), col, 2)
                    cv2.putText(v, f"{name} {b[4]:.2f}", (int(b[0]), int(b[1]) - 6), 0, 0.6, col, 2)
            out = os.path.join(d, "sam_probe.jpg")
            cv2.imwrite(out, v)
            print("wrote", out)


if __name__ == "__main__":
    main()
