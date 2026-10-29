#!/usr/bin/env python3
"""Self-test for csv_session_stats.py: build a CSV in the app's export format with known packet loss, a reboot,
gyro clipping and high-g hits, then check the stats recover them.

    python tools/test_csv_session_stats.py
"""
import os
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import csv_session_stats as cs  # noqa: E402

HEADER = "time_s,ax_g,ay_g,az_g,gx_rads,gy_rads,gz_rads,hx_g,hy_g,hz_g\n"


def build(path):
    # 20 s at 1 kHz, keeping one 8-sample packet in four; the racket reboots at 12 s (clock restarts at 0).
    t = np.arange(20000) / 1000.0
    keep = (np.arange(20000) // 8) % 4 == 0
    t = np.where(t < 12, 100 + t, t - 12)
    rows = np.zeros((20000, 10))
    rows[:, 0] = t
    rows[:, 3] = 1.0                          # resting: 1 g on z
    hits = [2016, 4992, 8992, 14016]          # sample indices, multiples of 32: all in kept packets
    for i in hits:
        rows[i, 7:10] = (0, 0, 40)
        rows[i - 40:i, 5] = 34.87             # swing clipped at the 2000 dps wire limit
    with open(path, "w") as fh:
        fh.write(HEADER)
        for r in rows[keep]:
            fh.write(",".join(f"{v:.4f}" for v in r) + "\n")
    return len(hits)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "session-test-racket.csv")
        hits = build(path)
        r = cs.analyze(path)
        open(os.path.join(tmp, "empty-racket.csv"), "w").write(HEADER)
        empty = cs.analyze(os.path.join(tmp, "empty-racket.csv"))
    assert r["resets"] == 1, r["resets"]
    assert abs(r["received"] - 0.25) < 0.01, r["received"]
    assert abs(r["gap_median_ms"] - 25) < 0.5, r["gap_median_ms"]
    assert r["high_g_events"] == hits, r["high_g_events"]
    assert r["gyro_clipped"] > 0
    assert r["accel_clipped"] == 0
    assert abs(np.median(r["throughput"]) - 250) < 10, np.median(r["throughput"])
    assert empty == {"file": "empty-racket.csv", "samples": 0}, empty
    print("PASS")


if __name__ == "__main__":
    main()
