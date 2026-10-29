# Full scattering and small multi-task model test

## Outcome

Both requested approaches were implemented and evaluated. No candidate has shown a consistent enough improvement to replace the current ridge firmware. The source recordings, labels, 14 rejection records, app and firmware were not changed.

| Grouped evaluation on all 274 clips | Accuracy | Balanced accuracy | Mean radial-distance error |
|---|---:|---:|---:|
| Fixed current ridge recipe | 67.2% | 63.3% | 1.832 cm |
| Select by inner distance error from new/current candidates | 69.3% | 65.5% | 1.823 cm |
| Small multi-task family, selected for balanced classification | 65.0% | 65.7% | 1.801 cm |
| Scattering-based classical family, selected for balanced classification | 67.2% | 63.3% | 1.979 cm |
| Multi-task family with scattering inputs | 59.9% | 60.4% | 2.019 cm |

The 69.3% result describes a model-selection procedure across outer folds, not an independent accuracy measurement of the final all-data checkpoint. Four outer folds selected small multi-task networks and one selected PLS for distance prediction. The final all-data candidate is the small multi-task model using the current 156 inputs, 150 epochs and L2 penalty 0.1, chosen by pooled inner-fold distance error.

## What was implemented

### Actual first- and second-order wavelet scattering

Used the official Kymatio 0.3.0 NumPy implementation of Scattering1D with Q=4 and max_order=2. This is distinct from the earlier Haar packet experiment. For the shared 512-sample window, J=6 produced 22 first-order and 44 second-order paths. For the 2048-sample tail, J=8 produced 30 first-order and 90 second-order paths. The zero-order signed signal path was excluded.

Input audio was centred and RMS-normalized. Features pool the mean, standard deviation, early mean and late mean along each scattering path, with a log transform. That yields 264 scattering features for 32 ms and 480 for 128 ms. Tests also combined these with the existing 156 inputs. No filters were learned during feature extraction. [Official mathematical/API reference](https://www.kymat.io/codereference.html).

The two small, pure-Python dependency wheels were obtained directly from PyPI, checked against the published SHA-256 hashes, and extracted locally without running setup scripts. The package names, versions and hashes are retained in verified_wheels.json. No recordings were uploaded.

### A compact shared multi-task model

The network uses training-only standardization and PCA to 16 components, followed by an 8-unit tanh layer shared by six outputs. It jointly predicts radius, absolute horizontal position and absolute vertical position, plus three region logits: radius <=4 cm, 4<radius<=8 cm, and radius>8 cm.

Regression uses Huber loss with a 1.5 cm transition, weighted toward radial distance. Region classification uses class-balanced cross-entropy. Four fixed training recipes test 150 or 400 epochs and L2 penalties 0.01 or 0.1. The shared network has approximately 190 learned parameters, excluding the fitted PCA transform. It uses a deterministic seed and full-batch Adam. Region probabilities are not calibrated confidence estimates.

This is a small feature-based shared network, not a reproduction of the larger multi-expert CNN from the research paper. It uses the exact saved placements as targets; no labels were changed to fit the network.

## Test design

Twenty-seven configurations were evaluated on the 274 shared-window recordings and separately on the 177 complete tails. Five outer folds hold out whole eight-trigger chronological blocks. Three inner folds select feature set, model, regularization, epochs and decision head. This is 810 inner-fold fits plus outer refits and final all-data fits. Every scaler, PCA and network sees only its fold's training examples.

Two decisions are retained separately: the distance head's fixed 4 cm threshold and the region head's most likely class. Head selection uses the inner folds. Region-head sweet recall can increase while off-centre specificity falls; those trade-offs are not counted as an unconditional accuracy gain.

These are development-data tests on the same two sessions already used in earlier research. Grouped/nested testing reduces leakage and tuning bias, but does not create an independent club session or verify another racket. The earlier 76% from one 54-clip split remains a different and narrower diagnostic.

## Is the small improvement stable?

The new distance-selected procedure correctly changed 27 old errors but made 21 previously correct cases wrong: six additional correct decisions out of 274. Accuracy improved in four of the five outer folds; distance error improved in three.

A descriptive paired chronological-group bootstrap gave a 2.5-to-97.5 percentile range of approximately **-3.8 to +7.9 percentage points** for the accuracy difference. The corresponding radial-error difference ranged from **-0.109 to +0.096 cm**. Both ranges cross zero. These are descriptive resampling ranges, not independently calibrated field confidence intervals. The observed 2.2-point gain and 0.008 cm error reduction are too small to call a reliable replacement.

## Longer-tail results

The following results all use the same 177 long recordings and grouped folds:

| Procedure | Accuracy | Mean radial-distance error |
|---|---:|---:|
| Fixed ridge on the 128 ms tail | 61.6% | 1.792 cm |
| New/current candidate selection for distance | 55.9% | 1.922 cm |
| New/current selection for balanced classification | 58.2% | 1.863 cm |
| Multi-task family with current tail features | 57.6% | 2.028 cm |
| Multi-task family with scattering inputs | 57.6% | 1.940 cm |

Neither full scattering nor this small joint model improves the tail baseline. These 177-clip figures must not be compared directly with all-274 results as though only one processing step changed.

## Saved candidates and verification

- combined_candidate.pkl: final small joint model, fitted on all 274 accepted clips; current features, 150 epochs, decay 0.1. It is an offline research candidate, not installed firmware.
- tail_candidate.pkl: final tail candidate selected by pooled inner error. No independent score is claimed for this full-data fit.
- combined_results.json and tail_results.json: every inner score and outer selection.
- *_oof.npz: outer-fold predictions, targets and group identifiers.
- *_features.npz: input feature arrays and targets.
- stability.json: paired-group resampling and per-fold differences.
- rejected_detections.csv: copy of the preserved 14 review rejections.
- verified_wheels.json: dependency provenance and hashes.
- training_code: scripts used for the work.

Five tests passed: finite-difference checks of the joint regression/classification gradients, exact 4/8 cm region boundaries, learning on a known synthetic relationship and checkpoint round-trip, constant-input numerical stability, and official second-order scattering with gain-invariance checks. The maximum checked gradient error was below 7e-11. All 274 source audio hashes were verified.

No C++ port or new firmware binary was produced for these candidates. The current ridge firmware was left in place because the improvement was not consistent.

## Offline trial

From the project root:

```powershell
python ml/predict_multitask_audio.py data/sessions/20261028-155849-long-run2/clips/clip-0001.i16
```

The output separates distance-threshold and region-head decisions. It does not silently switch between them. Load only the checkpoints generated by this trusted training workflow. On a fresh machine, the NumPy/SciPy environment and matching Kymatio dependency must be prepared first.

To reproduce training into a new directory:

```powershell
python ml/train_scattering_multitask.py --out ml/runs/another-scattering-run
```
