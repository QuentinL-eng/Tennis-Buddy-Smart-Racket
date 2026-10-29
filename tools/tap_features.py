#!/usr/bin/env python3
"""Reference implementation of the tap detector in firmware/src/tap.cpp.

This is the specification the firmware follows, kept in step with it by hand (the same arrangement as
ml/features.py for the sweet-spot model). It exists so the detector can be developed and checked against
recorded data without flashing the racket:

    python3 tools/tap_features.py data/taps/unplaced/*.npz     # detection rate over recorded taps
    python3 tools/tap_features.py --calibrate data/taps         # fit + write firmware/src/tap_model.h

Sample stream in, taps out: a running baseline of |a|, trigger when |a| jumps TAP_TRIG_MG above it, then wait
for the ring-down to fall back before closing the window and extracting features.

Keep TAP_* constants below identical to the defaults in tap.cpp.
"""
import numpy as np

TAP_WINDOW = 256
TAP_PRE = 96
N_FEATURES = 10
N_ZONES = 5
ZONE_NAMES = ["unknown", "butt", "grip_60", "grip_120", "grip_180", "throat"]

TAP_TRIG_MG = 300
TAP_MAX_LEN = 90            # samples between trigger and end of jolt (~17 ms at 5.3 kHz)
TAP_REFRACTORY_MS = 200
BASE_SHIFT = 11             # baseline += (mag - base) >> shift


def _mag(a):
    """Per-sample |a| in mg (float for numpy convenience; the firmware uses integer sqrt)."""
    return np.sqrt((a.astype(np.float64) ** 2).sum(axis=1))


def detect(a, t_us):
    """Run the detector over one capture. Returns a list of (trigger_index, end_index).

    The window stays open while the signal keeps climbing past 90 % of the running maximum, so the whole
    jolt and its ring-down land inside it. Closing on the first quiet sample would clip the peak to the
    couple of samples before the trigger, which is exactly the part the localisation features need.
    """
    mag = _mag(a)
    n = len(a)
    base = mag[0]
    hits = []
    lag, trig, peak = 0, 0, 0.0
    last_us = -10 ** 9
    for i in range(n):
        m = mag[i]
        if lag > 0:
            lag += 1
            if m > peak:
                peak = m
            quiet = m - base < TAP_TRIG_MG // 3
            if not quiet and lag < 2 * TAP_MAX_LEN and (m > base + TAP_TRIG_MG // 3 and m > 0.9 * peak):
                continue
            hits.append((trig, i))
            base += (m - base) / (1 << BASE_SHIFT)
            lag = 0
            last_us = t_us[i]
            continue
        base += (m - base) / (1 << BASE_SHIFT)
        if m - base > TAP_TRIG_MG and (t_us[i] - last_us) > TAP_REFRACTORY_MS * 1000:
            lag = 1
            trig = i
            peak = m
    return hits


def features(a, trig, end):
    """Feature vector for one detected tap. Mirrors features() in tap.cpp."""
    w = TAP_WINDOW
    # The window ends at `end` and holds TAP_PRE samples before the trigger.
    lo = max(0, end - w + 1)
    seg = a[lo:end + 1]
    if len(seg) < w:                       # pad the front if the trigger was near the start
        seg = np.vstack([np.zeros((w - len(seg), 3), np.int32), seg])
    tri = TAP_PRE                        # by construction the trigger is TAP_PRE samples back from the end
    tri = min(tri, len(seg) - 1)

    mag = _mag(seg)
    b = mag[:TAP_PRE].mean() if TAP_PRE else mag[0]
    span = min(len(seg) - TAP_PRE, end - trig + 1)
    post = seg[TAP_PRE:TAP_PRE + span]

    pm = mag[TAP_PRE:TAP_PRE + span]
    smag = pm.max() if span else b
    step = np.abs(np.diff(np.concatenate([[b], pm]))).max() if span else 0
    pk = np.abs(post).max(axis=0) if span else np.zeros(3)
    lead = pk.max()
    quarter = b + (smag - b) / 4
    over = np.where(pm > quarter)[0]
    decay = int(over[-1] + 1) if len(over) else 0
    zc = int((np.diff((pm > b + 40).astype(int)) != 0).sum()) if span else 0
    e = (post.astype(np.float64) ** 2).sum(axis=0) if span else np.zeros(3)
    etot = e.sum() + 1
    peak_i = int(np.abs(post).max(axis=1).argmax()) if span else 0

    jolt = smag - b
    f = np.zeros(N_FEATURES, dtype=np.uint8)
    f[0] = np.clip(jolt * 255 // 2048, 0, 255) if jolt > 0 else 0
    f[1] = np.clip(lead * 255 // 1024, 0, 255) if lead > 0 else 0
    f[2] = min(255, int(step))
    f[3] = decay * 255 // 64
    f[4] = min(63, zc)
    f[5] = int(e[0] * 255 / etot)
    f[6] = int(e[1] * 255 / etot)
    f[7] = int(e[2] * 255 / etot)
    f[8] = int(peak_i * 255 / max(1, span))
    f[9] = int((end - trig + 1) * 255 // (TAP_WINDOW - TAP_PRE))
    return f, jolt


def detect_features(a, t_us):
    """All taps in one capture, as (features, jolt_mg, trig_index)."""
    out = []
    for trig, end in detect(a, t_us):
        f, jolt = features(a, trig, end)
        out.append((f, jolt, trig))
    return out
