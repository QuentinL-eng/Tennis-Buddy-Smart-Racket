#!/usr/bin/env python3
"""Train the tiny sweet-spot MLP (numpy only) and export it to firmware/src/sweetspot_model.h.

    python3 ml/train.py                         # synthetic data only (works today)
    python3 ml/train.py --real data/impacts     # blend in real labelled clips (see ml/README.md)
    python3 ml/train.py --real data/impacts --real-only

Model: 12 features -> 16 (ReLU) -> 8 (ReLU) -> 2 outputs
  out[0] = logit "was this a sweet-spot hit"        (binary cross-entropy)
  out[1] = off-centre amount 0..1 (x100 = percent)  (mean squared error)
~370 parameters, int8 weights = under 0.5 KB of flash.
"""
import argparse
import glob
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from features import FEATURE_NAMES, N, N_FEATURES, extract  # noqa: E402
from synth import SWEET_RADIUS_CM, labels_from_dist, make_dataset  # noqa: E402

H1, H2 = 16, 8
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def featurize(clips):
    return np.stack([extract(c) for c in clips]).astype(np.float32)


def load_real(folder):
    """Load legacy or extended clips; the current model uses the first 512 samples."""
    with open(os.path.join(folder, "labels.csv")) as fh:
        rows = [l.strip().split(",") for l in fh if l.strip()]
    rows = [r for r in rows if r[0] != "file"]
    clips, dist = [], []
    extended = 0
    for name, d in rows:
        c = np.fromfile(os.path.join(folder, name), dtype="<i2")
        if c.size < N:
            raise ValueError(f"{name}: expected at least {N} samples, got {c.size}")
        extended += c.size > N
        clips.append(c[:N])
        dist.append(float(d))
    if extended:
        print(f"{extended} extended clips: current model uses only the first {N} samples; decay tails remain on disk.")
    return np.array(clips, dtype=np.int16), np.array(dist, dtype=np.float32)


def init(rng):
    def layer(i, o):
        return rng.normal(0, np.sqrt(2.0 / i), (i, o)).astype(np.float32), np.zeros(o, np.float32)
    return [*layer(N_FEATURES, H1), *layer(H1, H2), *layer(H2, 2)]


def forward(p, x, keep=False):
    w1, b1, w2, b2, w3, b3 = p
    z1 = x @ w1 + b1; a1 = np.maximum(z1, 0)
    z2 = a1 @ w2 + b2; a2 = np.maximum(z2, 0)
    out = a2 @ w3 + b3
    return (out, (x, z1, a1, z2, a2)) if keep else out


def sigmoid(z):
    return 1 / (1 + np.exp(-z))


def train(xtr, sweet, pct, epochs=400, lr=3e-3, seed=0, weight_decay=0.0):
    rng = np.random.default_rng(seed)
    p = init(rng)
    m = [np.zeros_like(a) for a in p]; v = [np.zeros_like(a) for a in p]
    n = len(xtr); bs = 128; step = 0
    for ep in range(epochs):
        idx = rng.permutation(n)
        for s in range(0, n, bs):
            b = idx[s:s + bs]
            out, (x, z1, a1, z2, a2) = forward(p, xtr[b], keep=True)
            ps = sigmoid(out[:, 0])
            # gradients of  BCE(sweet) + 4 * MSE(pct)
            d_out = np.empty_like(out)
            d_out[:, 0] = (ps - sweet[b]) / len(b)
            d_out[:, 1] = 4 * 2 * (out[:, 1] - pct[b]) / len(b)
            w1, b1, w2, b2, w3, b3 = p
            g3 = a2.T @ d_out; gb3 = d_out.sum(0)
            d2 = (d_out @ w3.T) * (z2 > 0)
            g2 = a1.T @ d2; gb2 = d2.sum(0)
            d1 = (d2 @ w2.T) * (z1 > 0)
            g1 = x.T @ d1; gb1 = d1.sum(0)
            grads = [g1, gb1, g2, gb2, g3, gb3]
            for i in (0, 2, 4):
                grads[i] += weight_decay * p[i]
            step += 1
            cur = lr * (0.5 * (1 + np.cos(np.pi * ep / epochs)) * 0.95 + 0.05)
            for i, g in enumerate(grads):
                m[i] = 0.9 * m[i] + 0.1 * g
                v[i] = 0.999 * v[i] + 0.001 * g * g
                mh = m[i] / (1 - 0.9 ** step); vh = v[i] / (1 - 0.999 ** step)
                p[i] -= cur * mh / (np.sqrt(vh) + 1e-8)
    return p


def quantize(p):
    """Symmetric per-tensor int8 for weights; biases stay float."""
    q = []
    for i in range(0, 6, 2):
        w, b = p[i], p[i + 1]
        scale = float(np.max(np.abs(w)) / 127.0)
        q.append((np.round(w / scale).astype(np.int8), scale, b.astype(np.float32)))
    return q


def forward_q(q, x):
    a = x
    for k, (wq, scale, b) in enumerate(q):
        a = (a @ wq.astype(np.float32)) * scale + b
        if k < 2:
            a = np.maximum(a, 0)
    return a


def report(name, out, sweet, pct):
    pred = sigmoid(out[:, 0]) > 0.5
    acc = np.mean(pred == (sweet > 0.5))
    tp = np.sum(pred & (sweet > 0.5)); fp = np.sum(pred & (sweet < 0.5))
    fn = np.sum(~pred & (sweet > 0.5)); tn = np.sum(~pred & (sweet < 0.5))
    off = sweet < 0.5
    mae = np.mean(np.abs(out[off, 1] - pct[off])) * 100
    print(f"{name:22s} sweet/not accuracy {acc*100:5.1f}%  (TP {tp} FP {fp} FN {fn} TN {tn})  "
          f"off-centre MAE {mae:4.1f} percentage points (misses only)")


def export_header(q, mean, std, path, meta):
    def arr(a, fmt):
        return ", ".join(fmt(v) for v in a.ravel())
    def cpp_float(v, precision=6):
        value = f"{v:.{precision}g}"
        if "." not in value and "e" not in value.lower():
            value += ".0"
        return value + "f"
    lines = [
        "// GENERATED by ml/train.py. Do not edit; re-run the trainer.",
        f"// {meta}",
        "#pragma once",
        "#include <stdint.h>",
        "",
        f"#define SS_N_FEATURES {N_FEATURES}",
        f"#define SS_H1 {q[0][0].shape[1]}",
        f"#define SS_H2 {q[1][0].shape[1]}",
        "",
        f"static const float SS_MEAN[SS_N_FEATURES] = {{{arr(mean, cpp_float)}}};",
        f"static const float SS_STD[SS_N_FEATURES] = {{{arr(std, cpp_float)}}};",
    ]
    for k, (wq, scale, b) in enumerate(q, 1):
        lines += [
            f"// layer {k}: {wq.shape[0]} -> {wq.shape[1]}, weights row-major [in][out]",
            f"static const int8_t SS_W{k}[{wq.size}] = {{{arr(wq, lambda v: str(int(v)))}}};",
            f"static const float SS_S{k} = {cpp_float(scale, 8)};",
            f"static const float SS_B{k}[{b.size}] = {{{arr(b, cpp_float)}}};",
        ]
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-synth", type=int, default=6000)
    ap.add_argument("--real", help="folder with labels.csv + raw int16 clips")
    ap.add_argument("--real-only", action="store_true")
    ap.add_argument("--epochs", type=int, default=400)
    ap.add_argument("--out", default=os.path.join(ROOT, "firmware", "src", "sweetspot_model.h"))
    a = ap.parse_args()

    xs, ys = [], []
    src = []
    if not a.real_only:
        c, d = make_dataset(a.n_synth, seed=1)
        xs.append(featurize(c)); ys.append(d); src.append(f"{len(d)} synthetic")
    if a.real:
        c, d = load_real(a.real)
        reps = 1 if a.real_only else max(1, int(0.5 * a.n_synth / max(len(d), 1)))   # upweight real
        xs += [featurize(c)] * reps; ys += [d] * reps; src.append(f"{len(d)} real (x{reps})")
    x = np.concatenate(xs); dist = np.concatenate(ys)
    sweet, pct = labels_from_dist(dist)
    pct = pct / 100.0

    mean = x.mean(0); std = x.std(0) + 1e-6
    xn = (x - mean) / std
    rng = np.random.default_rng(7)
    perm = rng.permutation(len(xn)); cut = int(0.85 * len(xn))
    tr, va = perm[:cut], perm[cut:]
    p = train(xn[tr], sweet[tr], pct[tr], epochs=a.epochs)
    report("train", forward(p, xn[tr]), sweet[tr], pct[tr])
    report("validation", forward(p, xn[va]), sweet[va], pct[va])

    q = quantize(p)
    report("validation (int8)", forward_q(q, xn[va]), sweet[va], pct[va])
    if not a.real_only and not a.real:
        # unseen rackets: different seeds and a wider spread of mode frequencies / mic coloring
        c, d = make_dataset(1500, seed=99, spread=1.6)
        s2, p2 = labels_from_dist(d)
        report("unseen rackets (int8)", forward_q(q, (featurize(c) - mean) / std), s2, p2 / 100)

    export_header(q, mean, std, a.out, "trained on: " + " + ".join(src))
    print("wrote", os.path.relpath(a.out, ROOT))
    np.savez(os.path.join(os.path.dirname(__file__), "model.npz"), mean=mean, std=std,
             **{f"w{k}": wq for k, (wq, _, _) in enumerate(q, 1)},
             **{f"s{k}": s for k, (_, s, _) in enumerate(q, 1)},
             **{f"b{k}": b for k, (_, _, b) in enumerate(q, 1)})


if __name__ == "__main__":
    main()
