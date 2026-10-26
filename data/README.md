# Data

Calibration and test recordings from the racket.

- `*.tbrec`: raw 1 kHz sensor recordings from the app's recorder (Racket tab → Record raw data). Share them from the
  app and drop them here. Inspect with `python3 tools/analyze_recording.py <file> --plot`.
- `calibration/drops-*.json`: labeled ball drops from the calibration grid (the app saves them in its
  Documents/Calibration folder).
