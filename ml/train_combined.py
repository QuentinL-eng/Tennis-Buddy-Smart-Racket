"""Build an audited real-data model and evaluate a separate decay-window candidate.

python ml/train_combined.py --sessions data/sessions/<old> data/sessions/<new>

Source sessions are never edited. Reviewed rejects are archived, not treated as
off-centre hits. The deployed candidate uses the shared initial 512 samples.
The separate decay experiment uses only recordings with a complete 128 ms tail.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import shutil

import numpy as np

from features import N, PRE, extract, extract_window
from synth import labels_from_dist
from train import export_header, forward_q, quantize, sigmoid, train

ROOT = Path(__file__).resolve().parents[1]
SEED = 20261028


def read_csv(path):
    with path.open(newline="") as fh:
        return list(csv.DictReader(fh))


def write_csv(path, rows, columns):
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def split_indices(sessions, sweet):
    """Stratify by source session and target; never repeat a clip across splits."""
    rng = np.random.default_rng(SEED)
    parts = {key: [] for key in ("train", "validation", "test")}
    for session in sorted(set(sessions)):
        for target in (0, 1):
            indices = np.flatnonzero((sessions == session) & (sweet == target))
            rng.shuffle(indices)
            if len(indices) < 5:
                raise ValueError(f"Not enough examples of target {target} in {session}")
            ntest = max(1, round(len(indices) * 0.2))
            nval = max(1, round((len(indices) - ntest) * 0.2))
            parts["test"].extend(indices[:ntest])
            parts["validation"].extend(indices[ntest:ntest + nval])
            parts["train"].extend(indices[ntest + nval:])
    return {k: np.array(sorted(v), dtype=int) for k, v in parts.items()}


def fit(x, dist, indices, epochs, weight_decay=0.0):
    sweet, pct = labels_from_dist(dist)
    mean = x[indices].mean(0)
    std = x[indices].std(0) + 1e-6
    weights = train((x[indices] - mean) / std, sweet[indices], pct[indices] / 100,
                    epochs=epochs, seed=0, weight_decay=weight_decay)
    return quantize(weights), mean, std


def fit_linear(x, dist, indices, alpha):
    """Two ridge outputs represented exactly by signed ReLU pairs in the firmware MLP."""
    mean = x[indices].mean(0)
    std = x[indices].std(0) + 1e-6
    xn = (x[indices] - mean) / std
    sweet, pct = labels_from_dist(dist[indices])
    target = np.column_stack([2 * sweet - 1, pct / 100])
    bias = target.mean(0)
    beta = np.linalg.solve(xn.T @ xn + alpha * np.eye(x.shape[1]), xn.T @ (target - bias)).astype(np.float32)
    identity = np.eye(x.shape[1], dtype=np.float32)
    width = 2 * x.shape[1]
    weights = [np.hstack([identity, -identity]), np.zeros(width, np.float32),
               np.eye(width, dtype=np.float32), np.zeros(width, np.float32),
               np.vstack([beta, -beta]), bias.astype(np.float32)]
    return quantize(weights), mean, std


def predict(model, x):
    q, mean, std = model
    return forward_q(q, (x - mean) / std)


def metrics(out, distances):
    actual = distances <= 4
    predicted = sigmoid(out[:, 0]) > 0.5
    tp = int(np.sum(predicted & actual))
    fn = int(np.sum(~predicted & actual))
    tn = int(np.sum(~predicted & ~actual))
    fp = int(np.sum(predicted & ~actual))
    recalls = [tp / (tp + fn) if tp + fn else None, tn / (tn + fp) if tn + fp else None]
    # Firmware clamps distance output to [0,100] and forces 0 on a sweet prediction.
    off = np.clip(out[:, 1] * 100, 0, 100)
    off = np.where(predicted, 0, np.maximum(off, 100 * 4 / 12))
    target = np.minimum(distances / 12, 1) * 100
    return {
        "n": len(distances), "accuracy": float(np.mean(predicted == actual)),
        "balanced_accuracy": float(np.mean([v for v in recalls if v is not None])),
        "sweet_recall": recalls[0], "off_centre_recall": recalls[1],
        "tp": tp, "fn": fn, "tn": tn, "fp": fp,
        "majority_baseline_accuracy": float(max(np.mean(actual), np.mean(~actual))),
        "off_centre_mae_percentage_points": float(np.mean(np.abs(off[~actual] - target[~actual])))
            if np.any(~actual) else None,
    }


def save_model(path, model):
    q, mean, std = model
    np.savez(path, mean=mean, std=std,
             **{f"w{k}": w for k, (w, _, _) in enumerate(q, 1)},
             **{f"s{k}": s for k, (_, s, _) in enumerate(q, 1)},
             **{f"b{k}": b for k, (_, _, b) in enumerate(q, 1)})


def verify_export(path, model, x):
    """Verify firmware's decimal header values, including int8 weights, against NPZ inference."""
    import re
    text = path.read_text()
    array = lambda name: np.fromstring(re.search(rf"{name}\[[^]]+\] = \{{([^}}]+)\}}", text)[1].replace("f", ""), sep=",")
    q, _, _ = model
    restored = []
    for k, (w, _, _) in enumerate(q, 1):
        scale = float(re.search(rf"SS_S{k} = ([^;]+)", text)[1].removesuffix("f"))
        restored.append((array(f"SS_W{k}").astype(np.int8).reshape(w.shape), scale,
                         array(f"SS_B{k}").astype(np.float32)))
    rounded = (restored, array("SS_MEAN").astype(np.float32), array("SS_STD").astype(np.float32))
    error = float(np.max(np.abs(predict(model, x) - predict(rounded, x))))
    if error > 0.005:
        raise ValueError(f"Header round-trip error {error} exceeds tolerance")
    return error


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sessions", nargs="+", type=Path, required=True)
    ap.add_argument("--run-dir", type=Path, default=ROOT / "ml/runs/20261028-combined")
    ap.add_argument("--promote", action="store_true", help="replace active generated model only if validation and test beat baseline")
    args = ap.parse_args()
    run = args.run_dir.resolve()
    run.mkdir(parents=True, exist_ok=False)
    dataset = run / "dataset"
    dataset.mkdir()
    # Retain the previous generated files before replacing either one.
    for source in (ROOT / "ml/model.npz", ROOT / "firmware/src/sweetspot_model.h"):
        if source.exists():
            shutil.copy2(source, run / ("previous_" + source.name))
    examples, rejected, excluded, sessions_report = [], [], [], []
    seen = set()
    for session in args.sessions:
        session = session.resolve()
        labels = read_csv(session / "labels.csv")
        recordings = read_csv(session / "clips.csv")
        by_file = {r["file"]: r for r in recordings}
        if len(by_file) != len(recordings) or len({r["file"] for r in labels}) != len(labels):
            raise ValueError(f"Duplicate filenames in {session}")
        discards = set((session / "discarded.txt").read_text().split()) if (session / "discarded.txt").exists() else set()
        accepted = {r["file"] for r in labels}
        if accepted & discards:
            raise ValueError(f"Accepted/rejected overlap in {session}")
        if (accepted | discards) - by_file.keys():
            raise ValueError(f"Labels/rejections lack a recording entry in {session}")
        for name in ("labels.csv", "positions.csv", "discarded.txt", "unscaled.txt", "calibration.json"):
            source = session / name
            if source.exists():
                target = run / "source_review" / session.name / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        for label in labels:
            raw = session / label["file"]
            clip = np.fromfile(raw, dtype="<i2")
            dist = float(label["dist_cm"])
            if not np.isfinite(dist) or dist < 0 or len(clip) < N:
                raise ValueError(f"Invalid label or short clip: {raw}")
            sha = digest(raw)
            if sha in seen:
                raise ValueError(f"Duplicate accepted audio content: {raw}")
            seen.add(sha)
            relative = Path("clips") / session.name / raw.name
            target = dataset / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(raw, target)
            examples.append({"file": relative.as_posix(), "dist_cm": dist,
                             "source_session": session.name, "source_file": label["file"],
                             "sha256": sha, "samples": len(clip), "clip": clip})
        for r in recordings:
            if r["file"] in accepted:
                continue
            row = {"source_session": session.name, "source_file": r["file"],
                   "status": "review_rejected" if r["file"] in discards else "not_in_final_labels",
                   "reason": "false_positive_or_unusable_reason_not_separately_recorded" if r["file"] in discards
                             else "excluded_from_final_labels_not_assumed_false_positive",
                   "impact_t_s": r.get("impact_t_s", ""), "receive_t_s": r["t_s"],
                   "sha256": digest(session / r["file"])}
            (rejected if r["file"] in discards else excluded).append(row)
            target = run / "excluded_clips" / session.name / Path(r["file"]).name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(session / r["file"], target)
        sessions_report.append({"session": session.name, "accepted": len(labels), "review_rejected": len(discards),
                                "scaled": (session / "labels_unscaled.csv").exists(),
                                "labels_sha256": digest(session / "labels.csv")})
    distances = np.array([r["dist_cm"] for r in examples], dtype=np.float32)
    sources = np.array([r["source_session"] for r in examples])
    sweet, _ = labels_from_dist(distances)
    split = split_indices(sources, sweet)
    split_name = {int(i): k for k, indices in split.items() for i in indices}
    manifest = [{k: v for k, v in r.items() if k != "clip"} | {"split": split_name[i]}
                for i, r in enumerate(examples)]
    write_csv(dataset / "labels.csv", [{"file": r["file"], "dist_cm": r["dist_cm"]} for r in examples], ["file", "dist_cm"])
    write_csv(run / "manifest.csv", manifest, list(manifest[0]))
    columns = ["source_session", "source_file", "status", "reason", "impact_t_s", "receive_t_s", "sha256"]
    write_csv(run / "rejected_detections.csv", rejected, columns)
    write_csv(run / "other_exclusions.csv", excluded, columns)
    print(f"Accepted {len(examples)}, reviewed rejects {len(rejected)}, other exclusions {len(excluded)}", flush=True)
    x = np.stack([extract(r["clip"][:N]) for r in examples])
    # Tune epoch count only on validation; normalization is fitted on training rows only.
    candidates = []
    validation_candidates = []
    for epochs, decay in [(e, d) for e in (100, 200, 400) for d in (0.0, 0.01, 0.1)] + [(800, 0.0)]:
        candidate = fit(x, distances, split["train"], epochs, decay)
        score = metrics(predict(candidate, x[split["validation"]]), distances[split["validation"]])
        config = {"kind": "mlp", "epochs": epochs, "weight_decay": decay}
        validation_candidates.append({"config": config, "metrics": score})
        candidates.append((score["balanced_accuracy"], -score["off_centre_mae_percentage_points"], -epochs, candidate, config))
    for alpha in (0.1, 1.0, 10.0, 100.0):
        candidate = fit_linear(x, distances, split["train"], alpha)
        score = metrics(predict(candidate, x[split["validation"]]), distances[split["validation"]])
        config = {"kind": "ridge", "alpha": alpha}
        validation_candidates.append({"config": config, "metrics": score})
        candidates.append((score["balanced_accuracy"], -score["off_centre_mae_percentage_points"], 0, candidate, config))
    chosen = max(candidates, key=lambda r: r[:3])
    model, config = chosen[3:]
    result = {"seed": SEED, "sessions": sessions_report, "accepted": len(examples), "review_rejected": len(rejected),
              "other_excluded": len(excluded), "sweet": int(sweet.sum()), "off_centre": int((1-sweet).sum()),
              "selected_config": config, "validation_candidates": validation_candidates,
              "window": "initial 512 samples, 32 ms at 16 kHz", "synthetic": 0,
              "split_metrics": {key: metrics(predict(model, x[ids]), distances[ids]) for key, ids in split.items()}}
    # Cross-session checks use a fixed epoch count and fresh session-only normalization.
    result["cross_session"] = []
    for source in sorted(set(sources)):
        train_ids = np.flatnonzero(sources == source)
        test_ids = np.flatnonzero(sources != source)
        cross = fit(x, distances, train_ids, 400)
        result["cross_session"].append({"trained_session": source,
                                         **metrics(predict(cross, x[test_ids]), distances[test_ids])})
    # Compare initial audio and the full 128-ms post-clipping tail on identical splits.
    long_ids, tail_features = [], []
    for i, r in enumerate(examples):
        clip = r["clip"]
        sat = np.flatnonzero(np.abs(clip.astype(np.int32)) >= 30000)
        start = int(sat[-1]) + 1 if sat.size else PRE
        if len(clip) - start >= 2048:
            long_ids.append(i)
            tail_features.append(extract_window(clip[start:start + 2048]))
    if long_ids:
        ids = np.array(long_ids)
        tail_x = np.stack(tail_features)
        local_split = {key: np.flatnonzero(np.isin(ids, selected)) for key, selected in split.items()}
        decay_report = {"eligible": len(ids), "window": "2048 samples after last abs(sample)>=30000, else trigger",
                        "offline_only": True}
        for name, features in (("initial_32ms", x[ids]), ("decay_128ms", tail_x)):
            candidate = fit(features, distances[ids], local_split["train"], 400)
            decay_report[name] = {key: metrics(predict(candidate, features[sub]), distances[ids[sub]])
                                  for key, sub in local_split.items()}
            save_model(run / f"{name}_experiment.npz", candidate)
        result["decay_comparison"] = decay_report
    header = run / "sweetspot_model.h"
    export_header(*model, header, f"{len(examples)} real reviewed clips; train {len(split['train'])}, validation {len(split['validation'])}, test {len(split['test'])}; {config}; seed {SEED}; initial 32ms")
    result["header_roundtrip_max_logit_error"] = verify_export(header, model, x)
    save_model(run / "model.npz", model)
    test_predictions = predict(model, x[split["test"]])
    write_csv(run / "test_predictions.csv", [
        {"source_session": sources[i], "source_file": examples[i]["source_file"], "dist_cm": float(distances[i]),
         "p_sweet": float(sigmoid(pred[0])), "predicted_sweet": bool(pred[0] > 0)}
        for i, pred in zip(split["test"], test_predictions)],
        ["source_session", "source_file", "dist_cm", "p_sweet", "predicted_sweet"])
    checks = [result["split_metrics"][key] for key in ("validation", "test")]
    ready = all(m["accuracy"] > m["majority_baseline_accuracy"] and m["balanced_accuracy"] > 0.5
                and m["sweet_recall"] > 0 and m["off_centre_recall"] > 0 for m in checks)
    result["passes_baseline_gate"] = ready
    result["promoted"] = bool(args.promote and ready)
    (run / "metrics.json").write_text(json.dumps(result, indent=2) + "\n")
    limitations = [
        "Reviewed rejects are preserved for future event detection analysis, not used as off-centre labels or automatically assumed to be no-contact sounds.",
        "Discard files do not distinguish false triggers, duplicates, and unclear impacts. No finer reasons are inferred.",
        "The combined model uses the initial 32 ms because old recordings have no longer tail.",
        "The decay model is an offline candidate only and is not loaded by the current firmware.",
        "Per-impact splits include both sessions; they do not prove generalization to other sessions or rackets.",
        "Cross-session checks are separate fixed-configuration models, not metrics of the exported combined weights.",
        "Labels use each session's saved calibration/scaling; new labels have not been SAM-rescaled if scaled=false.",
        "C++/Python runtime parity and ESP32 compilation must be verified separately before flashing.",
    ]
    (run / "README.md").write_text("# Combined training run\n\n" + "\n".join("- " + s for s in limitations) + "\n\nSee metrics.json, manifest.csv, and rejected_detections.csv. Source sessions were not changed.\n")
    # A weak model is still saved for review, but cannot silently replace the active one.
    if result["promoted"]:
        shutil.copy2(header, ROOT / "firmware/src/sweetspot_model.h")
        shutil.copy2(run / "model.npz", ROOT / "ml/model.npz")
    print(json.dumps({key: result[key] for key in ("accepted", "review_rejected", "selected_config", "split_metrics", "passes_baseline_gate", "promoted")}, indent=2), flush=True)
    print(f"Saved {run}. Not flashed.", flush=True)


if __name__ == "__main__":
    main()
