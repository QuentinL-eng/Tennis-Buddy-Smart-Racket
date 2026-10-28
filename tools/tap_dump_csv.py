#!/usr/bin/env python3
"""Convert saved tap captures (.npz) to the plain text the detector test reads.

    python3 tools/tap_dump_csv.py data/taps/grip_60/*.npz --out /tmp/csv
    g++ -std=c++17 -O2 -Ifirmware/src -o /tmp/tap_test tools/tap_detect_test.cpp \\
        firmware/src/tap.cpp firmware/src/tap_classify.cpp
    /tmp/tap_test /tmp/csv/*.txt

One line per sample: t_us ax ay az (mg).
"""
import argparse
import os

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--out", default="/tmp/tap_csv")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    n = 0
    for p in a.paths:
        d = np.load(p, allow_pickle=False)
        t = d["imu_us"]
        a3 = d["imu_mg"]
        name = os.path.splitext(os.path.basename(p))[0] + ".txt"
        with open(os.path.join(a.out, name), "w") as f:
            for i in range(len(t)):
                f.write(f"{int(t[i])} {int(a3[i,0])} {int(a3[i,1])} {int(a3[i,2])}\n")
        n += 1
    print(f"wrote {n} file(s) to {a.out}")


if __name__ == "__main__":
    main()
