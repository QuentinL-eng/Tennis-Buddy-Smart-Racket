"""Compare classical ML models on the reviewed audio without changing firmware.

python ml/compare_models.py
Uses local NumPy/SciPy models; no network access is required.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


import pickle
import numpy as np
from scipy.fft import dct
from classical_models import (clone, accuracy_score, balanced_accuracy_score,
    confusion_matrix, mean_absolute_error, Standardized, KernelRidge, Neighbors,
    Forest, BoostedTrees)

from features import extract
from train import forward_q, sigmoid

SEED = 20261028


def audio_features(clip):
    """No labels, timestamps, filenames, session IDs, or camera measurements are inputs."""
    raw = np.asarray(clip, dtype=np.float64)
    if raw.ndim != 1 or len(raw) < 192 or len(raw) % 32:
        raise ValueError("Audio window must be 1-D, at least 192 samples and divisible by 32")
    centered = raw - raw.mean()
    rms = np.sqrt(np.mean(centered ** 2))
    x = centered / max(rms, 1)

    def spectrum(segment, bands):
        nfft = 1 << (len(segment) - 1).bit_length()
        power = np.abs(np.fft.rfft(segment * np.hanning(len(segment)), n=nfft)) ** 2
        power = power[1:]
        power /= max(float(power.sum()), 1e-20)
        grouped = np.array([part.sum() for part in np.array_split(power, bands)])
        return np.log10(grouped + 1e-8), power

    full, power = spectrum(x, 64)
    later, _ = spectrum(x[len(x) // 2:], 32)
    cepstrum = dct(full, type=2, norm="ortho")[1:17]
    freq = np.fft.rfftfreq(2 * len(power), 1 / 16000)[1:]
    centroid = float(np.sum(freq * power)) / 8000
    bandwidth = float(np.sqrt(np.sum((freq / 8000 - centroid) ** 2 * power)))
    cumulative = np.cumsum(power)
    rolloffs = [float(freq[min(np.searchsorted(cumulative, p), len(freq) - 1)] / 8000) for p in (.5, .85, .95)]
    stats = [centroid, bandwidth, *rolloffs, float(np.sum(power ** 2)),
             float(np.mean(np.abs(np.diff(x)))), float(np.mean(x ** 4)),
             float(np.mean(np.abs(raw) >= 30000)), float(np.log10(rms + 1))]
    spectral = np.concatenate([full, later, cepstrum, stats]).astype(np.float32)
    env = np.sqrt(np.mean(x.reshape(32, -1) ** 2, axis=1))
    normalized_env = env / max(float(env.sum()), 1e-12)
    rich = np.concatenate([spectral, np.log10(normalized_env + 1e-8),
                           [np.mean(x[:-1] * x[1:]), np.mean(x[:-16] * x[16:])]]).astype(np.float32)
    return spectral, rich


def classifier_candidates():
    models = {}
    for alpha in (.1, 1, 10):
        models[f"RBF_kernel_ridge_alpha{alpha}"] = Standardized(KernelRidge(alpha=alpha, gamma=1, classifier=True))
    for gamma in (.1, 10):
        models[f"RBF_kernel_ridge_gamma{gamma}"] = Standardized(KernelRidge(alpha=1, gamma=gamma, classifier=True))
    models["linear_ridge"] = Standardized(KernelRidge(alpha=1, classifier=True, linear=True))
    for k in (5, 11):
        models[f"neighbors_k{k}"] = Standardized(Neighbors(k=k, classifier=True))
    for leaf in (3, 8):
        models[f"random_forest_leaf{leaf}"] = Forest(leaf=leaf, classifier=True)
        models[f"extra_trees_leaf{leaf}"] = Forest(leaf=leaf, classifier=True, extra=True)
    models["boosted_trees"] = BoostedTrees(classifier=True)
    return models


def regressor_candidates():
    return {
        "linear_ridge": Standardized(KernelRidge(alpha=1, linear=True)),
        "RBF_kernel_ridge_alpha1": Standardized(KernelRidge(alpha=1)),
        "RBF_kernel_ridge_alpha10": Standardized(KernelRidge(alpha=10)),
        "neighbors_k11": Standardized(Neighbors(k=11)),
        "random_forest": Forest(leaf=5),
        "extra_trees": Forest(leaf=5, extra=True),
        "boosted_trees": BoostedTrees(),
    }


def classification_metrics(actual, predicted):
    tn, fp, fn, tp = confusion_matrix(actual, predicted, labels=[0, 1]).ravel()
    return {"n": len(actual), "accuracy": float(accuracy_score(actual, predicted)),
            "balanced_accuracy": float(balanced_accuracy_score(actual, predicted)),
            "sweet_recall": float(tp / (tp + fn)), "off_centre_recall": float(tn / (tn + fp)),
            "tp": int(tp), "tn": int(tn), "fp": int(fp), "fn": int(fn)}


def select_models(features, distances, sessions, split):
    """Choose on validation only; train-only cross-validation is also retained."""
    y = (distances <= 4).astype(int)
    tr, va, te = (split[k] for k in ("train", "validation", "test"))
    # Stratification includes recording session and class, preventing empty minority folds.
    strata = np.array([f"{s}:{v}" for s, v in zip(sessions[tr], y[tr])])
    rng = np.random.default_rng(SEED)
    folds = [[] for _ in range(3)]
    for group in sorted(set(strata)):
        members = np.flatnonzero(strata == group)
        rng.shuffle(members)
        for i, member in enumerate(members):
            folds[i % 3].append(member)
    cv = [(np.setdiff1d(np.arange(len(tr)), held), np.array(held, dtype=int)) for held in folds]
    leaderboard, fitted = [], []
    for feature_name, x in features.items():
        for name, estimator in classifier_candidates().items():
            fold_scores = []
            for fit_ids, held_ids in cv:
                model = clone(estimator).fit(x[tr[fit_ids]], y[tr[fit_ids]])
                fold_scores.append(float(balanced_accuracy_score(y[tr[held_ids]], model.predict(x[tr[held_ids]]))))
            model = clone(estimator).fit(x[tr], y[tr])
            score = classification_metrics(y[va], model.predict(x[va]))
            row = {"features": feature_name, "model": name, "train_cv_balanced_accuracy": float(np.mean(fold_scores)),
                   "train_cv_folds": fold_scores, "validation": score}
            leaderboard.append(row)
            fitted.append((score["balanced_accuracy"], float(np.mean(fold_scores)), score["accuracy"], model, feature_name, row))
        print(f"Completed classifiers: {feature_name}", flush=True)
    selected = max(fitted, key=lambda v: v[:3])
    classifier, classifier_features, classifier_info = selected[3:]
    # Independent regression selection uses physical distance MAE, not sweet-spot classification.
    regression_board, regression_models = [], []
    for feature_name, x in features.items():
        for name, estimator in regressor_candidates().items():
            model = clone(estimator).fit(x[tr], distances[tr])
            error = float(mean_absolute_error(distances[va], np.clip(model.predict(x[va]), 0, None)))
            row = {"features": feature_name, "model": name, "validation_mae_cm": error}
            regression_board.append(row)
            regression_models.append((error, model, feature_name, row))
    selected_reg = min(regression_models, key=lambda v: v[0])
    regressor, regression_features, regression_info = selected_reg[1:]
    test_class = classifier.predict(features[classifier_features][te])
    test_dist = np.clip(regressor.predict(features[regression_features][te]), 0, None)
    # Test was reused by an earlier experiment. Report as a fixed diagnostic, not a fresh test.
    result = {
        "selected_classifier": classifier_info,
        "classifier_test": classification_metrics(y[te], test_class),
        "classifier_train": classification_metrics(y[tr], classifier.predict(features[classifier_features][tr])),
        "selected_regressor": regression_info,
        "regressor_test_mae_cm": float(mean_absolute_error(distances[te], test_dist)),
        "regressor_test_median_absolute_error_cm": float(np.median(np.abs(distances[te] - test_dist))),
        "regressor_threshold_test": classification_metrics(y[te], test_dist <= 4),
        "median_distance_baseline_test_mae_cm": float(mean_absolute_error(distances[te], np.full(len(te), np.median(distances[tr])))),
        "majority_baseline_test": classification_metrics(y[te], np.full(len(te), int(np.mean(y[tr]) > .5))),
        "classifier_leaderboard": leaderboard, "regressor_leaderboard": regression_board,
    }
    # Additional cross-session check of the validation-selected model configuration.
    result["cross_session"] = []
    for session in sorted(set(sessions)) if len(set(sessions)) > 1 else []:
        fit_ids, test_ids = np.flatnonzero(sessions == session), np.flatnonzero(sessions != session)
        cross = clone(classifier).fit(features[classifier_features][fit_ids], y[fit_ids])
        result["cross_session"].append({"trained_session": session,
                   **classification_metrics(y[test_ids], cross.predict(features[classifier_features][test_ids]))})
    return result, {"classifier": classifier, "classifier_features": classifier_features,
                    "regressor": regressor, "regression_features": regression_features,
                    "sample_rate": 16000, "sample_count": 512,
                    "class_definition": "distance <= 4 cm is sweet"}, test_class, test_dist


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source-run", type=Path, default=ROOT / "ml/runs/20261028-reviewed-combined")
    ap.add_argument("--out", type=Path, default=ROOT / "ml/runs/20261028-classical-ml")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=False)
    with (a.source_run / "manifest.csv").open(newline="") as fh:
        manifest = list(csv.DictReader(fh))
    clips = []
    for r in manifest:
        raw = (a.source_run / "dataset" / r["file"]).read_bytes()
        if hashlib.sha256(raw).hexdigest() != r["sha256"]:
            raise ValueError(f"Changed recording {r['file']}")
        clips.append(np.frombuffer(raw, dtype="<i2"))
    dist = np.array([float(r["dist_cm"]) for r in manifest])
    sessions = np.array([r["source_session"] for r in manifest])
    split = {k: np.array([i for i, r in enumerate(manifest) if r["split"] == k]) for k in ("train", "validation", "test")}
    legacy = np.stack([extract(c[:512]) for c in clips])
    spectra, rich = zip(*(audio_features(c[:512]) for c in clips))
    features = {"legacy12": legacy, "spectrum": np.stack(spectra), "spectrum_envelope": np.stack(rich)}
    print(f"Comparing {len(clips)} reviewed clips; feature dimensions {[(k,v.shape[1]) for k,v in features.items()]}", flush=True)
    result, checkpoint, test_class, test_dist = select_models(features, dist, sessions, split)
    # Synthetic and earlier real MLP on the identical 54 test rows.
    te = split["test"]
    for name, path in (("synthetic_model", a.source_run / "previous_model.npz"),
                       ("previous_real_mlp", a.source_run / "model.npz")):
        m = np.load(path)
        q = [(m[f"w{k}"], float(m[f"s{k}"]), m[f"b{k}"]) for k in (1, 2, 3)]
        logits = forward_q(q, (legacy[te] - m["mean"]) / m["std"])
        result[name] = classification_metrics(dist[te] <= 4, sigmoid(logits[:, 0]) > .5)
    # Today's complete tail data: same audio features, same original split membership.
    tail_ids, tails = [], []
    for i, c in enumerate(clips):
        sat = np.flatnonzero(np.abs(c.astype(np.int32)) >= 30000)
        start = int(sat[-1]) + 1 if len(sat) else 64
        if len(c) - start >= 2048:
            tail_ids.append(i)
            tails.append(c[start:start + 2048])
    ids = np.array(tail_ids)
    spectra, envelopes = zip(*(audio_features(c) for c in tails))
    tail_features = {"spectrum": np.stack(spectra), "spectrum_envelope": np.stack(envelopes)}
    tail_split = {k: np.flatnonzero(np.isin(ids, group)) for k, group in split.items()}
    # This experiment has only one source session; no cross-session test is possible.
    tail_result, tail_checkpoint, _, _ = select_models(tail_features, dist[ids], sessions[ids], tail_split)
    tail_checkpoint["sample_count"] = 2048
    tail_checkpoint["window"] = "after last abs(sample)>=30000 or trigger when absent"
    tail_checkpoint["eligible_source_indices"] = ids
    result["decay_only"] = tail_result
    result["counts"] = {k: len(v) for k, v in split.items()}
    result["notes"] = ["Selection uses validation only; cross-validation uses training rows only.",
        "All scalers are fitted inside each training fold.", "The fixed test set was already used by earlier experiments; a new session is needed for independent confirmation.",
        "Rejected detections remain excluded; no source recordings or labels were changed.",
        "Checkpoints are Python models, not ESP32 firmware binaries. No firmware is changed or flashed."]
    with (a.out / "combined_model.pkl").open("wb") as fh:
        pickle.dump(checkpoint, fh)
    with (a.out / "decay_model.pkl").open("wb") as fh:
        pickle.dump(tail_checkpoint, fh)
    np.savez(a.out / "features.npz", **features, distances=dist, **{f"split_{k}": v for k, v in split.items()})
    with (a.out / "predictions.csv").open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["source_session", "source_file", "distance_cm", "predicted_sweet", "predicted_distance_cm"])
        writer.writeheader()
        for i, c, d in zip(te, test_class, test_dist):
            writer.writerow({"source_session": manifest[i]["source_session"], "source_file": manifest[i]["source_file"],
                             "distance_cm": dist[i], "predicted_sweet": bool(c), "predicted_distance_cm": float(d)})
    (a.out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k not in ("classifier_leaderboard", "regressor_leaderboard", "decay_only")}, indent=2), flush=True)
    print('Decay summary:', json.dumps({k: tail_result[k] for k in ("selected_classifier", "classifier_test", "regressor_test_mae_cm")}))


if __name__ == "__main__":
    main()
