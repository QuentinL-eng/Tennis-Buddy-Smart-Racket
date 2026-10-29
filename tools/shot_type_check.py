"""Checks the app's shot-type rules (apple/RacketKit/Sources/RacketKit/ShotAnalyzer.swift) on a labeled recording.

    python tools/shot_type_check.py data/room-2026-10-29 [forehand sign]

The folder holds one session-...-racket.csv (the app's recording, exported as CSV) and labels.txt: one stroke per
visible impact, in order (FH, BH, SV, VO), whitespace or comma separated. Impacts are found from high-g peaks
rather than the app's detector, so hits the phone missed still line up with their labels. Without a forehand sign
(+1 or -1, as "Teach forehand" stores it) the sign is learned during the session the way AppModel does.

This mirrors ShotAnalyzer, including its sample-index windows, under the default calibration and a right-handed
player. Keep the constants in step with the Swift.
"""
import glob
import os
import sys

import numpy as np

SWING_SPAN = 0.35
VOLLEY_MAX_SWING_DEG = 93
SERVE_MAX_VERTICAL = -0.1
LEARN_SHOTS = 5          # AppModel.learnShotsNeeded
RIGHT_HANDED = True
# Calibration.default: rows are the racket x, y, z axes in sensor coordinates.
M = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)


def qmul(a, b):
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return np.array([w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2, w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
                     w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2, w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2])


def rot(q, v):
    return qmul(qmul(q, np.r_[0, v]), q * np.array([1, -1, -1, -1]))[1:]


def mahony(t, acc, gyr):
    """MahonyFilter (Orientation.swift) with RacketEngine's dt clamp, orientation after each sample."""
    q, integ = None, np.zeros(3)
    out = np.zeros((len(t), 4))
    for i in range(len(t)):
        a = acc[i]
        an = np.linalg.norm(a)
        if q is None and an > 0.5:
            u = a / an
            q = np.array([1 + u[2], u[1], -u[0], 0.0])
            q /= np.linalg.norm(q)
        if q is None:
            out[i] = [1, 0, 0, 0]
            continue
        dt = 0.001 if i == 0 else min(max(t[i] - t[i - 1], 0.0002), 0.02)
        w = gyr[i].copy()
        if 0.85 < an < 1.15 and np.linalg.norm(gyr[i]) < 3:
            up = rot(q * np.array([1, -1, -1, -1]), np.array([0, 0, 1.0]))
            e = np.cross(a / an, up)
            integ += 0.05 * e * dt
            w = w + 2.0 * e + integ
        ang = np.linalg.norm(w) * dt
        if ang > 1e-9:
            q = qmul(q, np.r_[np.cos(ang / 2), np.sin(ang / 2) * w / np.linalg.norm(w)])
            q /= np.linalg.norm(q)
        out[i] = q
    return out


def swing_angle_deg(t, gyr, i0):
    """ShotAnalyzer.swingAngleDeg."""
    start, angle, k = t[i0] - SWING_SPAN, 0.0, i0 - 1
    while k > 0 and t[k - 1] > start:
        angle += (np.linalg.norm(gyr[k]) + np.linalg.norm(gyr[k - 1])) / 2 * min(t[k] - t[k - 1], 0.06)
        k -= 1
    return np.degrees(angle)


def main(folder, taught=0.0):
    csv = glob.glob(os.path.join(folder, "*.csv"))[0]
    labels = open(os.path.join(folder, "labels.txt")).read().replace(",", " ").split()
    d = np.loadtxt(csv, delimiter=",", skiprows=1)
    t = d[:, 0]
    acc, gyr, hg = d[:, 1:4] @ M.T, d[:, 4:7] @ M.T, d[:, 7:10] @ M.T
    Q = mahony(t, acc, gyr)

    hgm = np.linalg.norm(hg, axis=1)
    peaks = []
    for i in np.where(hgm > 4)[0]:
        if peaks and t[i] - t[peaks[-1]] < 0.6:
            if hgm[i] > hgm[peaks[-1]]:
                peaks[-1] = i
        else:
            peaks.append(i)
    if len(peaks) != len(labels):
        sys.exit(f"{len(peaks)} impacts but {len(labels)} labels")

    sign, learned = taught, []
    hand = 1 if RIGHT_HANDED else -1
    confusion, rows = {}, []
    for lab, p in zip(labels, peaks):
        # RacketEngine.finishShot: largest 3-sample jump within ±6 samples, impact on its first sample.
        best = max(range(max(3, p - 6), min(len(t), p + 7)), key=lambda k: np.linalg.norm(hg[k] - hg[k - 3]))
        i0 = best - 2
        w_pre = gyr[max(0, i0 - 10):i0 - 2].mean(0)
        omega = np.linalg.norm(w_pre)
        q = Q[max(i0 - 3, 0)]
        tip_up = rot(q, np.array([1.0, 0, 0]))[2]
        vertical = (rot(q, w_pre)[2] / omega if omega > 1e-3 else 0) * hand
        swing = swing_angle_deg(t, gyr, i0)
        if swing < VOLLEY_MAX_SWING_DEG:
            got = "VO"
        elif sign != 0:
            got = "BH" if w_pre[1] * sign <= 0 else ("SV" if vertical < SERVE_MAX_VERTICAL else "FH")
        elif tip_up > 0.5 and omega > 8:
            got = "SV"
        else:
            got = "FH" if vertical > 0 else "BH"
        # AppModel.learnForehandFace
        if sign == 0 and got == "FH" and vertical > 0.6 and abs(w_pre[1]) > 5:
            learned.append(w_pre[1])
            if len(learned) >= LEARN_SHOTS:
                pos = sum(s > 0 for s in learned)
                if pos in (0, len(learned)):
                    sign = 1.0 if pos else -1.0
                learned = []
        confusion[(lab, got)] = confusion.get((lab, got), 0) + 1
        rows.append((t[i0] - t[0], lab, got, swing, vertical, w_pre[1], sign))

    for r in rows:
        print("%7.2f s  %s -> %s%s  swing %4.0f°  vertical %+.2f  wPre.y %+5.1f  forehand sign %+.0f"
              % (r[0], r[1], r[2], "  " if r[1] == r[2] else " x", r[3], r[4], r[5], r[6]))
    right = sum(n for (a, b), n in confusion.items() if a == b)
    print(f"\n{right}/{len(rows)} correct")
    for lab in ["FH", "BH", "SV", "VO"]:
        got = {b: n for (a, b), n in confusion.items() if a == lab}
        if got:
            print(f"  {lab}: " + ", ".join(f"{b} {n}" for b, n in sorted(got.items())))


if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 0.0)
