#!/usr/bin/env python3
"""Label a session from tools/collect_session.py by clicking where each ball hit in the video.

    python3 tools/label_video.py data/sessions/<session>

First, calibrate once (key c): click the string-bed centre, click a second point toward the racket tip, then type
that point's distance from the centre in cm. Then, for each impact the video opens near the right moment:

    a / d   one frame back / forward        w / s   five frames back / forward
    click   1st: where the ball touches, 2nd: the string-bed centre (racket moves, so re-mark it each time)
    Enter   accept and go to the next impact (with --fixed one click is enough, using the calibrated centre)
    x       discard (double trigger, floor bounce, no ball)       b  previous impact
    c       recalibrate        q  save and quit

The frame you accept teaches the tool the camera/serial delay, so later impacts open closer to the contact
frame. Progress is saved after every label. Output in the session folder: labels.csv (file,dist_cm, read by
ml/train.py --real <session>), positions.csv (file,x_cm,y_cm,frame; x right, y toward the tip), discarded.txt.
"""
import csv
import json
import math
import os
import sys

import cv2
import numpy as np
from session_timing import impact_time

class State:
    cal = None
    needed = 2
    clicks = []          # per impact: [ball contact, string-bed centre]


def on_mouse(event, x, y, flags, st):
    if event == cv2.EVENT_LBUTTONDOWN:
        st.clicks = ([(x, y)] if len(st.clicks) >= st.needed else st.clicks + [(x, y)])


def px_to_cm(cal, p):
    c = np.array(cal["centre"]); u = np.array(cal["up"]); r = np.array([-u[1], u[0]])
    d = np.array(p, dtype=float) - c
    return float(d @ r) / cal["ppc"], float(d @ u) / cal["ppc"]


def calibrate(win, cap, start, n_frames, st, path):
    """Scrub (a/d one frame, w/s 5, j/k 60) to a frame where the racket is visible and still, then click."""
    pts = []
    cur = start
    def click(event, x, y, flags, _):
        if event == cv2.EVENT_LBUTTONDOWN and len(pts) < 2:
            pts.append((x, y))
    cv2.setMouseCallback(win, click)
    while len(pts) < 2:
        frame = read_frame(cap, cur)
        if frame is None:
            return
        v = frame.copy()
        msg = "click string-bed CENTRE" if not pts else "click a point toward the TIP (note its distance)"
        cv2.putText(v, msg, (12, 36), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 255), 2)
        cv2.putText(v, f"frame {cur}   a/d w/s j/k = scrub, find a frame with the racket in view", (12, 70),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
        for p in pts:
            cv2.circle(v, p, 5, (0, 255, 0), -1)
        cv2.imshow(win, v)
        k = cv2.waitKey(30) & 0xFF
        step = {ord("a"): -1, ord("d"): 1, ord("w"): -5, ord("s"): 5, ord("j"): -60, ord("k"): 60}.get(k)
        if step and not pts:
            cur = int(np.clip(cur + step, 0, n_frames - 1))
        elif k == ord("q"):
            return
    cm = float(input("distance of the second point from the centre, in cm: "))
    d = np.array(pts[1], dtype=float) - np.array(pts[0], dtype=float)
    st.cal = {"centre": list(pts[0]), "up": list(d / np.linalg.norm(d)), "ppc": float(np.linalg.norm(d)) / cm, "frame": cur}
    json.dump(st.cal, open(path, "w"))
    cv2.setMouseCallback(win, on_mouse, st)


def suggest(frames, min_c=0.3):
    """(frame, ball centre, racket-head centre) with the ball nearest the head, from sam_prefill.py boxes."""
    best = None
    for fr, r in frames.items():
        balls = [b for b in r.get("ball", []) if b[4] >= min_c]
        heads = [b for b in r.get("racket", []) if b[4] >= min_c]
        if not balls or not heads:
            continue
        b = max(balls, key=lambda b: b[4]); h = max(heads, key=lambda b: b[4])
        bc = ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2); hc = ((h[0] + h[2]) / 2, (h[1] + h[3]) / 2)
        dist = math.hypot(bc[0] - hc[0], bc[1] - hc[1])
        if best is None or dist < best[0]:
            best = (dist, int(fr), (int(bc[0]), int(bc[1])), (int(hc[0]), int(hc[1])))
    return best[1:] if best else None


def frame_clicks(r):
    """Ball and head-centre clicks from one frame's SAM boxes, or [] if either is missing."""
    balls = [b for b in (r or {}).get("ball", []) if b[4] >= 0.3]
    heads = [b for b in (r or {}).get("racket", []) if b[4] >= 0.3]
    if not balls or not heads:
        return []
    b = max(balls, key=lambda b: b[4]); h = max(heads, key=lambda b: b[4])
    return [(int((b[0] + b[2]) / 2), int((b[1] + b[3]) / 2)), (int((h[0] + h[2]) / 2), int((h[1] + h[3]) / 2))]


def read_frame(cap, i):
    cap.set(cv2.CAP_PROP_POS_FRAMES, i)
    ok, f = cap.read()
    return f if ok else None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    clips = list(csv.DictReader(open(os.path.join(d, "clips.csv"))))
    ft = np.array([float(r["t_s"]) for r in csv.DictReader(open(os.path.join(d, "frames.csv")))])
    cap = cv2.VideoCapture(os.path.join(d, "video.avi"))
    n_frames = min(int(cap.get(cv2.CAP_PROP_FRAME_COUNT)), len(ft))

    lab_p, pos_p, dis_p, cal_p = (os.path.join(d, n) for n in ("labels.csv", "positions.csv", "discarded.txt", "calibration.json"))
    labels = {r[0]: r[1] for r in csv.reader(open(lab_p)) if r and r[0] != "file"} if os.path.exists(lab_p) else {}
    pos = {r[0]: r[1:] for r in csv.reader(open(pos_p)) if r and r[0] != "file"} if os.path.exists(pos_p) else {}
    dis = set(open(dis_p).read().split()) if os.path.exists(dis_p) else set()

    def save():
        with open(lab_p, "w") as f:
            f.write("file,dist_cm\n" + "".join(f"{k},{v}\n" for k, v in labels.items()))
        with open(pos_p, "w") as f:
            f.write("file,x_cm,y_cm,frame,ball_x,ball_y,centre_x,centre_y\n" + "".join(f"{k},{','.join(v)}\n" for k, v in pos.items()))
        open(dis_p, "w").write("\n".join(sorted(dis)))

    st = State()
    st.needed = 1 if "--fixed" in sys.argv else 2      # --fixed: racket and camera never move, one click per impact
    st.cal = json.load(open(cal_p)) if os.path.exists(cal_p) else None
    win = "label (a/d w/s step, click, Enter, x, b, c, q)"
    cv2.namedWindow(win)
    cv2.setMouseCallback(win, on_mouse, st)
    if st.cal is None:
        first = int(np.searchsorted(ft, impact_time(clips[0]))) if clips else 0
        calibrate(win, cap, first, n_frames, st, cal_p)
        if st.cal is None:
            sys.exit("calibration cancelled")

    sam_p = os.path.join(d, "sam_cache.json")
    sam = json.load(open(sam_p)) if os.path.exists(sam_p) else {}      # tools/sam_prefill.py output

    shifts = []                                     # accepted frame minus guessed frame, for the delay estimate
    i = 0
    while i < len(clips):
        c = clips[i]
        f = c["file"]
        if (f in labels or f in dis) and "--redo" not in sys.argv:
            i += 1
            continue
        guess = int(np.searchsorted(ft, impact_time(c)))
        cur = int(np.clip(guess + (int(np.median(shifts[-5:])) if shifts else 0), 0, n_frames - 1))
        st.clicks = []
        sug = suggest(sam.get(f, {}))
        if sug and st.needed == 2:                  # SAM proposal: frame where the ball is closest to the racket head
            cur, st.clicks = sug[0], [sug[1], sug[2]]
        action = None
        while action is None:
            fr = read_frame(cap, cur)
            if fr is None:
                break
            v = fr.copy()
            ppc = st.cal["ppc"]
            centre = st.clicks[1] if len(st.clicks) == 2 else tuple(st.cal["centre"]) if st.needed == 1 else None
            if centre:
                cx, cy = map(int, centre)
                cv2.drawMarker(v, (cx, cy), (255, 255, 0), cv2.MARKER_CROSS, 20, 1)
                cv2.circle(v, (cx, cy), int(4 * ppc), (0, 255, 0), 1)       # sweet-spot disc
            if st.clicks:
                cv2.circle(v, st.clicks[0], 7, (0, 0, 255), 2)
                if centre:
                    x, y = px_to_cm({**st.cal, "centre": list(centre)}, st.clicks[0])
                    cv2.putText(v, f"x={x:+.1f} y={y:+.1f} dist={math.hypot(x, y):.1f} cm", (12, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
                else:
                    cv2.putText(v, "now click the string-bed CENTRE", (12, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
            cv2.putText(v, f"impact {c['n']}/{len(clips)}  frame {cur} ({cur - guess:+d})  {c['verdict']}", (12, 36),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
            cv2.imshow(win, v)
            k = cv2.waitKey(30) & 0xFF
            prev = cur
            if k == ord("a"): cur = max(0, cur - 1)
            elif k == ord("d"): cur = min(n_frames - 1, cur + 1)
            elif k == ord("w"): cur = max(0, cur - 5)
            elif k == ord("s"): cur = min(n_frames - 1, cur + 5)
            elif k == ord("x"): action = "x"
            elif k in (ord("b"), 26): action = "b"      # 26 = Ctrl+Z
            elif k == ord("q"): action = "q"
            elif k == ord("c"): calibrate(win, cap, cur, n_frames, st, cal_p)
            elif k in (13, 32) and len(st.clicks) >= st.needed: action = "ok"
            if cur != prev:                         # the racket moves between frames, so old marks are stale
                st.clicks = frame_clicks(sam.get(f, {}).get(str(cur))) if st.needed == 2 else []
        if action in (None, "q"):
            break
        if action == "x":
            dis.add(f)
        elif action == "b":
            i = max(0, i - 1)
            for dct in (labels, pos):
                dct.pop(clips[i]["file"], None)
            dis.discard(clips[i]["file"])
            continue
        else:
            centre = st.clicks[1] if st.needed == 2 else st.cal["centre"]
            x, y = px_to_cm({**st.cal, "centre": list(centre)}, st.clicks[0])
            labels[f] = f"{math.hypot(x, y):.2f}"
            ball_px = st.clicks[0]
            pos[f] = [f"{x:.2f}", f"{y:.2f}", str(cur), str(int(ball_px[0])), str(int(ball_px[1])),
                      str(int(centre[0])), str(int(centre[1]))]
            if abs(cur - guess) <= 15:      # a far-off frame means a mismatched impact, not camera delay
                shifts.append(cur - guess)
        save()
        i += 1
    save()
    cv2.destroyAllWindows()
    print(f"{len(labels)} labelled, {len(dis)} discarded. Train: python3 ml/train.py --real {d}")


if __name__ == "__main__":
    main()
