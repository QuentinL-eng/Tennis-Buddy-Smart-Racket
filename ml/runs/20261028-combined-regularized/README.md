# Combined training run

- Reviewed rejects are preserved as negatives for future event detection, not used as off-centre labels.
- Discard files do not distinguish false triggers, duplicates, and unclear impacts. No finer reasons are inferred.
- The combined model uses the initial 32 ms because old recordings have no longer tail.
- The decay model is an offline candidate only and is not loaded by the current firmware.
- Per-impact splits include both sessions; they do not prove generalization to other sessions or rackets.
- Cross-session checks are separate fixed-configuration models, not metrics of the exported combined weights.
- Labels use each session's saved calibration/scaling; new labels have not been SAM-rescaled if scaled=false.
- C++/Python runtime parity and ESP32 compilation must be verified separately before flashing.

See metrics.json, manifest.csv, and rejected_detections.csv. Source sessions were not changed.
