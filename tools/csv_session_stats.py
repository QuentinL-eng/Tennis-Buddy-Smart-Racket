"""Link and sensor health of the app's raw-stream CSV recordings (session-...-racket.csv).

python3 tools/csv_session_stats.py data/<day>/          one row per recording, then totals

Reports how much of the 1 kHz stream arrived, the gap pattern, BLE throughput, sensor clipping
(gyro at the ±2000 dps wire limit, accel at ±16 g) and high-g events (|high-g| > 10 g, 0.3 s apart),
which are hit candidates. Recordings restart their clock when the racket reboots; those resets are
counted and skipped.
"""
import glob
import os
import sys
import warnings

import numpy as np

GYRO_2000_RADS = 32767 / 16.4 * np.pi / 180   # int16 limit at 16.4 LSB/dps: 34.87 rad/s
ACCEL_LIMIT_G = 15.9
EVENT_G = 10.0


def events(t, mag, threshold, spacing):
    out = []
    for i in np.where(mag > threshold)[0]:
        if not out or t[i] - t[out[-1]] > spacing or t[i] < t[out[-1]]:
            out.append(i)
    return out


def analyze(path):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        d = np.loadtxt(path, delimiter=",", skiprows=1, ndmin=2)
    r = {"file": os.path.basename(path), "samples": len(d)}
    if len(d) < 1000:
        return r
    t = d[:, 0]
    dt = np.diff(t)
    resets = int((dt < -0.05).sum())
    duration = float(dt[dt > 0].sum())
    gaps = dt[dt > 0.0015]
    gyro = np.linalg.norm(d[:, 4:7], axis=1)
    high_g = np.linalg.norm(d[:, 7:10], axis=1)
    hits = events(t, high_g, EVENT_G, 0.3)
    r.update(
        duration_s=duration,
        resets=resets,
        received=len(d) / (duration * 1000 + 1 + resets),
        gaps=len(gaps),
        gap_median_ms=float(np.median(gaps)) * 1000 if len(gaps) else 0.0,
        gap_max_s=float(gaps.max()) if len(gaps) else 0.0,
        gyro_clipped=int((np.abs(d[:, 4:7]) > GYRO_2000_RADS - 0.01).sum()),
        accel_clipped=int((np.abs(d[:, 1:4]) > ACCEL_LIMIT_G).sum()),
        high_g_max=float(high_g.max()),
        high_g_events=len(hits),
        swings=len(events(t, gyro, 10.0, 0.5)),
        intervals=[t[b] - t[a] for a, b in zip(hits, hits[1:]) if 0 < t[b] - t[a] < 30],
    )
    bins = np.floor((t - t[0]) / 5)
    r["throughput"] = [np.count_nonzero(bins == k) / 5 for k in np.unique(bins) if k >= 0 and np.count_nonzero(bins == k) > 50]
    return r


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rows = [analyze(p) for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.csv")))]
    print(f"{'file':40} {'min':>5} {'recv':>5} {'gap ms':>6} {'max gap':>8} {'gyro clip':>9} {'hi-g max':>8} {'events':>6} {'swings':>6}")
    for r in rows:
        if "duration_s" not in r:
            print(f"{r['file']:40} empty ({r['samples']} samples)")
            continue
        print(f"{r['file']:40} {r['duration_s'] / 60:5.1f} {r['received']:5.0%} {r['gap_median_ms']:6.0f} {r['gap_max_s']:7.1f}s"
              f" {r['gyro_clipped']:9d} {r['high_g_max']:7.0f}g {r['high_g_events']:6d} {r['swings']:6d}"
              + (f"  ({r['resets']} reboot)" if r["resets"] else ""))
    full = [r for r in rows if "duration_s" in r]
    if not full:
        return
    samples = sum(r["samples"] for r in full)
    expected = sum(r["samples"] / r["received"] for r in full)
    thr = np.concatenate([r["throughput"] for r in full])
    ints = np.concatenate([r["intervals"] for r in full])
    print(f"\n{sum(r['duration_s'] for r in full) / 60:.0f} min recorded, {samples / expected:.0%} of samples received")
    print(f"throughput samples/s p10/p50/p90: {np.percentile(thr, [10, 50, 90]).round().astype(int).tolist()}")
    print(f"gyro clipped at 2000 dps in {sum(r['gyro_clipped'] > 0 for r in full)} of {len(full)} recordings")
    if len(ints):
        print(f"high-g event spacing p10/p50 (s): {np.percentile(ints, [10, 50]).round(2).tolist()}")


if __name__ == "__main__":
    main()
