"""Compile the active ridge model on a host and compare all reviewed clips to Python."""
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import numpy as np
from compare_models import audio_features

ROOT = Path(__file__).resolve().parents[1]


def main():
    compiler = os.environ.get("CXX") or shutil.which("c++") or shutil.which("g++") or shutil.which("clang++")
    if not compiler:
        print("BLOCKED: a host C++ compiler is required for firmware/Python parity. No parity pass is claimed.")
        return 2
    run = ROOT / "ml/runs/20261028-reviewed-combined"
    with (run / "manifest.csv").open(newline="") as fh:
        manifest = list(csv.DictReader(fh))
    clips = [np.fromfile(run / "dataset" / r["file"], dtype="<i2")[:512] for r in manifest]
    rng = np.random.default_rng(7)
    clips += list(rng.integers(-32768, 32768, size=(20, 512), dtype=np.int16))
    clips += [np.zeros(512, np.int16), np.full(512, 32767, np.int16)]
    clips = np.stack(clips)
    expected_features = np.stack([audio_features(c)[1] for c in clips])
    model = json.loads((ROOT / "ml/runs/20261028-classical-ml/distance_model.json").read_text())
    expected_distance = np.maximum(0, expected_features @ np.array(model["coefficients"]) + model["intercept"])
    with tempfile.TemporaryDirectory() as tmp:
        exe = Path(tmp) / ("parity.exe" if os.name == "nt" else "parity")
        subprocess.run([compiler, "-O2", "-std=c++17", "-o", str(exe), str(ROOT / "ml/c_parity_main.cpp"), str(ROOT / "firmware/src/sweetspot.cpp")], check=True)
        output = subprocess.run([str(exe)], input=clips.astype("<i2").tobytes(), capture_output=True, check=True).stdout
    actual = np.array([[float(v) for v in line.split()] for line in output.decode().splitlines()])
    assert actual.shape == (len(clips), 160), actual.shape
    feature_error = float(np.max(np.abs(actual[:, :156] - expected_features)))
    distance_error = float(np.max(np.abs(actual[:, 156] - expected_distance)))
    agree = float(np.mean((actual[:, 157] > .5) == (expected_distance <= 4)))
    passed = feature_error < .0005 and distance_error < .005 and agree == 1
    print(f"{len(clips)} clips; max feature error {feature_error:.3g}; max distance error {distance_error:.3g} cm; decisions agree {agree:.1%}")
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
