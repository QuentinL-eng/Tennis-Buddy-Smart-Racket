#!/usr/bin/env python3
"""Checks that the C++ firmware code (compiled for this computer) matches the Python reference.

    python3 ml/test_parity.py
"""
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from features import N_FEATURES, extract  # noqa: E402
from synth import make_dataset  # noqa: E402
from train import forward_q, sigmoid  # noqa: E402


def main():
    exe = os.path.join(tempfile.mkdtemp(), "parity")
    subprocess.run(["c++", "-O2", "-std=c++17", "-o", exe, os.path.join(HERE, "c_parity_main.cpp"),
                    os.path.join(HERE, "..", "firmware", "src", "sweetspot.cpp")], check=True)
    clips, _ = make_dataset(200, seed=5)
    out = subprocess.run([exe], input=clips.astype("<i2").tobytes(), capture_output=True, check=True).stdout
    rows = np.array([[float(v) for v in l.split()] for l in out.decode().splitlines()])

    m = np.load(os.path.join(HERE, "model.npz"))
    q = [(m[f"w{k}"], float(m[f"s{k}"]), m[f"b{k}"]) for k in (1, 2, 3)]
    py_feats = np.stack([extract(c) for c in clips])
    feat_err = np.abs(rows[:, :N_FEATURES] - py_feats).max(axis=0)
    py_p = sigmoid(forward_q(q, (py_feats - m["mean"]) / m["std"])[:, 0])
    p_err = np.abs(rows[:, N_FEATURES] - py_p).max()
    agree = np.mean((rows[:, N_FEATURES + 1] > 0.5) == (py_p > 0.5))
    print(f"max feature error {feat_err.max():.2e}   max probability error {p_err:.2e}   decision agreement {agree*100:.1f}%")
    ok = feat_err.max() < 5e-3 and p_err < 5e-3 and agree > 0.99
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
