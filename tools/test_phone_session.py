#!/usr/bin/env python3
"""Self-test for phone_session.py: build a synthetic session in the app's file format, with a known racket clock
offset and drift, BLE latency jitter and ball contacts, then check the alignment recovers the truth.

    python tools/test_phone_session.py
"""
import json
import os
import struct
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import phone_session as ps  # noqa: E402

OFFSET_S, DRIFT, MIN_LATENCY_S = 1.234567, 35e-6, 0.004


def build(folder, seed=1, seconds=60.0):
    rng = np.random.default_rng(seed)
    t_start = 5000.0                                         # phone host clock at the start
    impacts = np.arange(4.0, seconds - 3, 5.0) + rng.uniform(-0.5, 0.5, size=int((seconds - 7) // 5 + 1))
    impacts = impacts[impacts < seconds - 2]

    # --- racket IMU: racket clock r = (T - t_start) * (1 + DRIFT) + OFFSET_S
    n = int(seconds * 1000)
    k = np.arange(n)
    T = k * 1e-3                                              # true time of each sample (phone seconds from start)
    raw = np.zeros((n, 9), dtype=np.int16)
    raw[:, 2] = 2048                                          # 1 g on z
    raw[:, 8] = 10 << 4                                       # ~1 g on the high-g z
    for ti in impacts:
        i = int(round(ti * 1000))
        for d, counts in enumerate((900, 500, 250, 100)):
            raw[i + d, 8] = counts << 4
    r_us = ((T * (1 + DRIFT) + OFFSET_S) * 1e6).astype(np.int64)
    data = bytearray()
    for p in range(n // 8):
        sl = slice(p * 8, p * 8 + 8)
        t_last = T[sl][-1]
        arrival = t_start + t_last + MIN_LATENCY_S + rng.exponential(0.004)
        payload = struct.pack("<HIBB", p & 0xFFFF, int(r_us[sl][0]) & 0xFFFFFFFF, 8, 0) + raw[sl].astype("<i2").tobytes()
        data += struct.pack("<QBH", int(arrival * 1e9), ps.IMU, len(payload)) + payload
    status = struct.pack("<HBBBBH", 4000, 1, 3, 7, 1, 0)
    data = struct.pack("<QBH", int(t_start * 1e9), ps.STATUS, len(status)) + status + bytes(data)

    # --- camera: 240 fps frames, ball visible 0.35 s either side of each contact, reversing at the contact
    ft = np.arange(0, seconds, 1 / 240)
    det = []
    for ti in impacts:
        for f in ft[(ft > ti - 0.35) & (ft < ti + 0.35)]:
            s = f - ti
            u = 900 + (-4000 * s if s < 0 else 3200 * s)      # incoming towards +x? sign flips at contact
            v = 500 + (800 * s if s < 0 else -600 * s)
            det.append((int((t_start + f) * 1e9), u + rng.normal(0, .3), v + rng.normal(0, .3), 20, .9))

    os.makedirs(folder, exist_ok=True)
    open(os.path.join(folder, "racket.bin"), "wb").write(data)
    (t_start + ft).__mul__(1e9).astype("<u8").tofile(os.path.join(folder, "frames.bin"))
    np.array(det, dtype=np.dtype([("t", "<u8"), ("u", "<f4"), ("v", "<f4"), ("r", "<f4"), ("c", "<f4")])).tofile(
        os.path.join(folder, "detections.bin"))
    open(os.path.join(folder, "events.csv"), "w").write("t_ns,label\n")
    json.dump({"format_version": 1}, open(os.path.join(folder, "meta.json"), "w"))
    return t_start, impacts


def main():
    with tempfile.TemporaryDirectory() as folder:
        t_start, impacts = build(folder)
        report, (t, hi, imp_phone, bt, bu, kinks) = ps.analyze(folder)
        truth = t_start + impacts
        err = np.array([imp_phone[np.argmin(np.abs(imp_phone - x))] - x for x in truth])
        print(json.dumps(report, indent=2))
        print(f"impacts found {len(imp_phone)}/{len(truth)}; error vs truth: median {np.median(err) * 1e3:.2f} ms, "
              f"worst {np.max(np.abs(err)) * 1e3:.2f} ms")
        assert len(imp_phone) == len(truth), "missed or extra IMU impacts"
        assert report["contacts"]["pairs"] >= len(truth) - 1, "contacts not paired"
        # The racket clock runs fast by DRIFT, so phone time advances 35 ppm slower than racket time.
        assert abs(report["clock"]["drift_ppm"] + DRIFT * 1e6) < 5, "drift not recovered"
        assert np.max(np.abs(err)) < 0.002, "alignment worse than 2 ms"
        print("PASS")


if __name__ == "__main__":
    main()
