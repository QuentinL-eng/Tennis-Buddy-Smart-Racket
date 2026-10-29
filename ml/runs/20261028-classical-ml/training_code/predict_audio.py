"""Predict distance and sweet-spot status from a saved raw racket clip.

python ml/predict_audio.py data/sessions/<session>/clips/clip-0001.i16
python ml/predict_audio.py <clip.i16> --model ml/runs/20261028-classical-ml/decay_model.pkl
"""
import argparse
import json
from pathlib import Path
import pickle

import numpy as np

from compare_models import audio_features
from features import extract

ROOT = Path(__file__).resolve().parents[1]


def feature_row(checkpoint, clip, name):
    count = checkpoint["sample_count"]
    start = 0
    if count == 2048:
        near_full = np.flatnonzero(np.abs(clip.astype(np.int32)) >= 30000)
        start = int(near_full[-1]) + 1 if len(near_full) else 64
    if len(clip) - start < count:
        raise ValueError(f"Model needs {count} samples in its input window; only {len(clip)-start} remain")
    window = clip[start:start+count]
    if name == "legacy12":
        return extract(window)[None, :]
    spectral, envelope = audio_features(window)
    return (spectral if name == "spectrum" else envelope)[None, :]


def predict_clip(checkpoint, clip):
    row = feature_row(checkpoint, clip, checkpoint["regression_features"])
    distance = max(0.0, float(checkpoint["regressor"].predict(row)[0]))
    return {"distance_cm": distance, "sweet": distance <= 4.0, "sweet_radius_cm": 4.0,
            "window_samples": checkpoint["sample_count"]}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("clip", type=Path)
    ap.add_argument("--model", type=Path, default=ROOT / "ml/runs/20261028-classical-ml/combined_model.pkl")
    args = ap.parse_args()
    # Load only checkpoints generated locally by our training workflow.
    with args.model.open("rb") as fh:
        checkpoint = pickle.load(fh)
    result = predict_clip(checkpoint, np.fromfile(args.clip, dtype="<i2"))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
