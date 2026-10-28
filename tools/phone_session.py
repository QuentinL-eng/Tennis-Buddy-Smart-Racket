#!/usr/bin/env python3
"""Load a TennisCamera recording session (phone camera + racket IMU on one clock) and time-align it.

    python tools/phone_session.py <session folder>            # fit the clock, print the report, write aligned files
    python tools/phone_session.py <session folder> --plot     # also show the alignment (needs matplotlib)

The session folder comes from the TennisCamera app (Files > On My iPhone > TennisCamera > sessions). It holds
frames.bin, detections.bin, racket.bin, events.csv, meta.json and optionally video.mov with video_frames.bin
(the capture time of each frame in video.mov, in file order). Every phone-side time is
nanoseconds on the phone's host clock; every racket sample carries the racket's own micros() clock.

Alignment has two stages:
  1. Lower-envelope fit. A BLE packet can only arrive later than it was sent, so the smallest
     (arrival - racket time) values trace the clock offset plus the minimum link latency. A line through those
     minima gives offset and drift (the racket crystal drifts by tens of ppm).
  2. Contact refinement. A ball contact is a high-g jump in the IMU and a sudden velocity change in the ball's
     image track. The median gap between the two removes the remaining constant (the minimum latency).

Writes <session>/sync.json, imu_aligned.npz (t_phone_s plus accel/gyro/high-g in g, rad/s, g) and ball_track.csv.
"""
import argparse
import json
import os
import struct

import numpy as np

ACCEL_LSB_PER_G = 2048.0
GYRO_LSB_PER_DPS = 16.4            # halved when the packet carries the +-4000 dps flag
FLAG_GYRO_4000 = 1 << 3
IMU, STATUS, SHOT, TAP = 1, 2, 3, 4


# ---------------------------------------------------------------- loading

def _h3lis_g_per_count(range_code):
    return {0: 0.049, 3: 0.195}.get(range_code, 0.098)


def load_session(folder):
    """Returns dict: meta, frames (s), det (structured: t,u,v,r,conf), imu (aligned arrays, racket clock), racket records."""
    def path(name):
        return os.path.join(folder, name)

    with open(path("meta.json")) as fh:
        meta = json.load(fh)
    frames = np.fromfile(path("frames.bin"), dtype="<u8").astype(np.float64) / 1e9
    det = np.fromfile(path("detections.bin"),
                      dtype=np.dtype([("t", "<u8"), ("u", "<f4"), ("v", "<f4"), ("r", "<f4"), ("conf", "<f4")]))
    det_t = det["t"].astype(np.float64) / 1e9

    data = open(path("racket.bin"), "rb").read()
    pos, status_range = 0, 1
    seq, t0, count, flags, arrival, raw, gain_g = [], [], [], [], [], [], []
    shots, taps, statuses = [], [], []
    head = struct.Struct("<QBH")
    while pos + head.size <= len(data):
        t_ns, kind, n = head.unpack_from(data, pos)
        pos += head.size
        payload = data[pos:pos + n]
        pos += n
        if len(payload) < n:
            break                                   # truncated tail (app killed mid-write)
        t = t_ns / 1e9
        if kind == STATUS and n >= 8:
            status_range = payload[5]
            statuses.append((t, struct.unpack_from("<HBBBBH", payload)))
        elif kind == SHOT:
            shots.append((t, payload))
        elif kind == TAP:
            taps.append((t, payload))
        elif kind == IMU and n >= 8:
            s, t0_us, c, f = struct.unpack_from("<HIBB", payload)
            c = min(c, (n - 8) // 18)
            if c == 0:
                continue
            seq.append(s); t0.append(t0_us); count.append(c); flags.append(f); arrival.append(t)
            raw.append(np.frombuffer(payload, dtype="<i2", count=c * 9, offset=8).reshape(c, 9))
            gain_g.append(_h3lis_g_per_count(status_range))

    vf = path("video_frames.bin")
    video_t = np.fromfile(vf, dtype="<u8").astype(np.float64) / 1e9 if os.path.exists(vf) else np.zeros(0)
    out = {"meta": meta, "frames": frames, "det_t": det_t, "det": det, "video_t": video_t,
           "shots": shots, "taps": taps, "statuses": statuses}
    if not seq:
        out["packets"] = None
        return out
    seq = np.array(seq); t0 = np.array(t0, dtype=np.float64); count = np.array(count)
    t0_s = np.unwrap(t0, period=2.0 ** 32) / 1e6
    out["packets"] = {"seq": seq, "t0_s": t0_s, "count": count, "flags": np.array(flags),
                      "arrival_s": np.array(arrival), "raw": raw, "high_g_per_count": np.array(gain_g)}
    return out


def imu_samples(packets):
    """Flatten packets into per-sample arrays in physical units on the racket clock."""
    t, acc, gyr, hi = [], [], [], []
    for i, raw in enumerate(packets["raw"]):
        c = len(raw)
        t.append(packets["t0_s"][i] + np.arange(c) * 1e-3)
        acc.append(raw[:, 0:3] / ACCEL_LSB_PER_G)
        lsb = GYRO_LSB_PER_DPS / (2 if packets["flags"][i] & FLAG_GYRO_4000 else 1)
        gyr.append(np.radians(raw[:, 3:6] / lsb))
        hi.append((raw[:, 6:9] >> 4) * packets["high_g_per_count"][i])
    return np.concatenate(t), np.concatenate(acc), np.concatenate(gyr), np.concatenate(hi)


# ---------------------------------------------------------------- stage 1: clock fit

def fit_clock(packets, window_s=2.0):
    """Fit phone_time = racket_time + a + b * (racket_time - r0) from the lower envelope of the packet delays.

    Racket time of a packet is its last sample's time (the packet cannot be sent earlier than that).
    """
    last = packets["t0_s"] + (packets["count"] - 1) * 1e-3
    delay = packets["arrival_s"] - last
    r0 = float(last[0])
    x = last - r0
    # One minimum per window: the least-delayed packet in each window.
    idx = np.floor(x / window_s).astype(int)
    pick = [np.flatnonzero(idx == k)[np.argmin(delay[idx == k])] for k in np.unique(idx)]
    xs, ys = x[pick], delay[pick]
    keep = np.ones(len(xs), bool)
    a, b = float(np.min(ys)), 0.0
    for _ in range(4):
        if keep.sum() >= 3:
            b, a = np.polyfit(xs[keep], ys[keep], 1)
        else:
            a, b = float(np.median(ys[keep])), 0.0
        resid = ys - (a + b * xs)
        keep = resid <= np.percentile(resid[keep], 70) if keep.sum() > 4 else keep
    resid = ys - (a + b * xs)
    return {"r0_s": r0, "offset_s": float(a), "drift_ppm": float(b * 1e6),
            "envelope_resid_ms": float(np.std(resid[keep]) * 1e3) if keep.sum() > 1 else 0.0,
            "windows": int(len(xs)), "mean_delay_ms": float(np.mean(delay - (a + b * x)) * 1e3),
            "lost_packets": int(np.sum(np.clip(np.diff(packets["seq"].astype(np.int64)) % 65536 - 1, 0, 999)))}


def racket_to_phone(t_racket, clock):
    return t_racket + clock["offset_s"] + clock["drift_ppm"] * 1e-6 * (t_racket - clock["r0_s"])


# ---------------------------------------------------------------- stage 2: contact events

def imu_impacts(t, hi, threshold_g=10.0, jump_samples=3, min_gap_s=0.4):
    """Times (racket clock) where |high-g| jumps by more than threshold_g within jump_samples ms."""
    mag = np.linalg.norm(hi, axis=1)
    jump = np.abs(mag[jump_samples:] - mag[:-jump_samples])
    out, last = [], -1e9
    for i in np.flatnonzero(jump > threshold_g):
        if t[i] - last > min_gap_s:
            # onset: first sample in the neighbourhood that has already left the baseline
            j = max(0, i - jump_samples)
            out.append(t[j + jump_samples // 2 + 1])
            last = t[i]
    return np.array(out)


def ball_track(det_t, det):
    """One detection per frame: the most confident one."""
    order = np.lexsort((-det["conf"], det_t))
    t, u, v, r = det_t[order], det["u"][order], det["v"][order], det["r"][order]
    first = np.concatenate(([True], np.diff(t) > 1e-6))
    return t[first], u[first].astype(float), v[first].astype(float), r[first].astype(float)


def ball_kinks(t, u, v, min_change_px_s=1500.0, k=5, max_gap_s=0.02, min_sep_s=0.3):
    """Contact times from sudden velocity changes in the image track (sub-frame, by line intersection)."""
    kinks, scores = [], []
    for i in range(k, len(t) - k):
        b, a = slice(i - k, i + 1), slice(i, i + k + 1)
        if (np.diff(t[b]) > max_gap_s).any() or (np.diff(t[a]) > max_gap_s).any():
            continue
        tb, ta = t[b] - t[i], t[a] - t[i]
        pb = [np.polyfit(tb, q[b], 1) for q in (u, v)]      # (slope, intercept) per axis
        pa = [np.polyfit(ta, q[a], 1) for q in (u, v)]
        dv = np.array([pa[0][0] - pb[0][0], pa[1][0] - pb[1][0]])
        change = float(np.linalg.norm(dv))
        if change < min_change_px_s:
            continue
        dc = np.array([pb[0][1] - pa[0][1], pb[1][1] - pa[1][1]])   # intercept difference
        # |dc - dv * s|^2 is smallest at s = dc.dv / dv.dv  (lines meet)
        s = float(dc @ dv / (dv @ dv))
        kinks.append(t[i] + np.clip(s, -1 / 120, 1 / 120)); scores.append(change)
    # keep the strongest kink per cluster
    out = []
    for tk, sc in sorted(zip(kinks, scores), key=lambda z: -z[1]):
        if all(abs(tk - o) > min_sep_s for o, _ in out):
            out.append((tk, sc))
    return np.array(sorted(o for o, _ in out))


def refine(clock, t_imp_racket, kinks, window_s=0.15):
    """Median (kink - mapped impact) over matched pairs."""
    mapped = racket_to_phone(t_imp_racket, clock)
    gaps = []
    for tm in mapped:
        if len(kinks):
            j = np.argmin(np.abs(kinks - tm))
            if abs(kinks[j] - tm) <= window_s:
                gaps.append(kinks[j] - tm)
    gaps = np.array(gaps)
    if len(gaps) == 0:
        return {"pairs": 0, "residual_ms": None, "mad_ms": None}, 0.0
    med = float(np.median(gaps))
    return {"pairs": int(len(gaps)), "residual_ms": med * 1e3,
            "mad_ms": float(np.median(np.abs(gaps - med)) * 1e3)}, med


# ---------------------------------------------------------------- driver

def analyze(folder, impact_threshold_g=10.0, kink_px_s=1500.0):
    s = load_session(folder)
    if s["packets"] is None:
        raise SystemExit("racket.bin has no IMU packets: was the racket connected during the session?")
    clock = fit_clock(s["packets"])
    t_r, acc, gyr, hi = imu_samples(s["packets"])
    imp_r = imu_impacts(t_r, hi, impact_threshold_g)
    bt, bu, bv, br = ball_track(s["det_t"], s["det"])
    kinks = ball_kinks(bt, bu, bv, kink_px_s)
    event, shift = refine(clock, imp_r, kinks)
    clock["offset_s"] += shift
    clock["refined_by_contacts"] = event["pairs"] >= 3
    if not clock["refined_by_contacts"]:
        clock["offset_s"] -= shift                  # too few pairs to trust: keep the envelope fit alone
    t_phone = racket_to_phone(t_r, clock)
    imp_phone = racket_to_phone(imp_r, clock)
    report = {"clock": clock, "contacts": event, "imu_impacts": int(len(imp_r)), "ball_kinks": int(len(kinks)),
              "imu_samples": int(len(t_r)), "frames": int(len(s["frames"])), "ball_detections": int(len(bt)),
              "frame_gaps_over_6ms": int(np.sum(np.diff(s["frames"]) > 0.006))}
    np.savez(os.path.join(folder, "imu_aligned.npz"), t_phone_s=t_phone, accel_g=acc, gyro_rad_s=gyr, high_g=hi,
             impacts_phone_s=imp_phone, ball_kinks_phone_s=kinks)
    np.savetxt(os.path.join(folder, "ball_track.csv"), np.column_stack([bt, bu, bv, br]), delimiter=",",
               header="t_phone_s,u_px,v_px,radius_px", comments="")
    with open(os.path.join(folder, "sync.json"), "w") as fh:
        json.dump(report, fh, indent=2)
    return report, (t_phone, hi, imp_phone, bt, bu, kinks)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session")
    ap.add_argument("--threshold", type=float, default=10.0, help="high-g jump (g over 3 ms) that counts as an impact")
    ap.add_argument("--kink", type=float, default=1500.0, help="ball velocity change (px/s) that counts as a contact")
    ap.add_argument("--plot", action="store_true")
    a = ap.parse_args()
    report, (t, hi, imp, bt, bu, kinks) = analyze(a.session, a.threshold, a.kink)
    print(json.dumps(report, indent=2))
    c = report["contacts"]
    if c["pairs"] < 3:
        print("\nFewer than 3 IMU impacts matched ball kinks: only the lower-envelope fit was applied (expect the"
              "\nconstant BLE latency, a few ms, as error). Check --threshold / --kink or the ball detections.")
    if a.plot:
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(2, 1, sharex=True, figsize=(12, 6))
        ax[0].plot(t, np.linalg.norm(hi, axis=1)); ax[0].set_ylabel("|high-g| g")
        ax[1].plot(bt, bu, ".", ms=2); ax[1].set_ylabel("ball u px")
        for x in imp:
            ax[0].axvline(x, color="k", alpha=.3)
        for x in kinks:
            ax[1].axvline(x, color="r", alpha=.3)
        ax[1].set_xlabel("phone time s")
        plt.show()


if __name__ == "__main__":
    main()
