# Combined racket model: reviewed recordings

The combined model was trained and saved. It did not beat the majority-class baseline, so it was not promoted or flashed. The active generated model files match the pre-training backup.

## Data and rejection record

| Source | Accepted | Review rejected | Other excluded |
|---|---:|---:|---:|
| 20261027-224032-long-1 | 97 | 3 | 1 |
| 20261028-155849-long-run2 | 177 | 11 | 0 |
| Total | 274 | 14 | 1 |

There are 108 sweet-spot labels (distance <= 4 cm) and 166 off-centre labels. No synthetic clips were used.

All 14 rejected recordings are copied to excluded_clips and listed in rejected_detections.csv with their source filename, session, timestamp and SHA-256. They are not trained as off-centre hits. The review tool did not store separate reasons for duplicates, false triggers and unclear impacts, so the archive preserves that uncertainty. The additional excluded clip is listed separately; it was removed during the earlier scaling step.

Original session recordings and review files were not edited. source_review contains copies of the saved label, position, calibration and rejection files. manifest.csv links every accepted clip to its source, hash and training split. dataset contains the complete accepted raw recordings, including all decay tails.

## Combined model

The common input is the initial 512 samples (32 ms at 16 kHz). The earlier session has no long decay recordings. The model has 12 features and 16/8 hidden units with int8 weights. Validation selected 800 epochs without weight decay from the documented candidates. Normalization was fitted only on the training split. Raw audio is not duplicated across splits.

| Split | Clips | Accuracy | Balanced accuracy |
|---|---:|---:|---:|
| Training | 175 | 100.0% | 100.0% |
| Validation | 45 | 55.6% | 50.9% |
| Test | 54 | 57.4% | 55.6% |

Always predicting off-centre scores 61.1% on the test set. The model correctly found 10 of 21 sweet hits and 21 of 33 off-centre hits. The large training/validation gap shows overfitting. This is a saved candidate, not a validated product model.

Per-impact splits include both sessions. They do not test a new racket. Separate fixed-configuration session-to-session checks scored 47.5% (earlier to later) and 50.5% (later to earlier); see metrics.json for class balance and confusion counts. These are different models from the combined candidate.

## Longer-decay experiment

Only the 177 accepted recordings from the later session have complete 128 ms tails. A separate model used 2048 samples after the final abs(sample) >= 30000, or after the trigger when no sample reached that level. Both experimental models use the same 113 training, 29 validation and 35 test examples from that session.

| Input window | Validation accuracy | Test accuracy |
|---|---:|---:|
| Initial 32 ms | 31.0% | 42.9% |
| Post-clipping 128 ms | 65.5% | 48.6% |

The tail result does not establish an improvement in prediction. The test majority baseline is 51.4%. Neither experimental model was promoted. The saved decay checkpoint requires a separate inference implementation and cannot be dropped into the current firmware.

## Verification and limits

- Twelve host regression tests passed, covering recording timing, partial serial reads, old/long recordings, split integrity, metric calculation and serialized-model export.
- The initial 32 ms feature extractor matched the previous Python implementation exactly on 20 random clips.
- The firmware-header decimal values round-trip to the NPZ predictions within 0.000175 maximum logit error.
- C++/Python runtime parity could not run: the host C++ compiler is unavailable. No successful firmware build is claimed for this candidate.
- Earlier labels have SAM scaling; later labels still use manual calibration. The racket's actual head area was not supplied. No automatic re-scaling or label changes were made.
- The initial fit was checked before the regularization experiment. The saved test split was reused for reporting, so it is not a fresh independent replication.

Next: audit contact-frame alignment and label scaling across sessions before collecting more data or changing the firmware classifier. The current data do not show that additional recordings alone will solve the problem.

## Reproduce

From the repository root, use a new run directory:

```powershell
python ml/train_combined.py --sessions data/sessions/20261027-224032-long-1 data/sessions/20261028-155849-long-run2 --run-dir ml/runs/another-run
```

The default saves candidates only. --promote can replace active generated files only when validation and test both pass the baseline gate. It never flashes the racket.
