# To do once the racket is streaming real data

Don't skip these: they're what make the demo numbers believable.

- [ ] **Tune shot detection on real recordings.** Record shadow swings and blanket hits (Racket tab → Record raw
      data), commit them to `data/`, then check with `python3 tools/analyze_recording.py <file> --plot`. Adjust
      the impact threshold (10 g jump) and swing gate (290 °/s) in `RacketEngine.detect` if hits are missed or
      doubled.
- [ ] **Tune the stats against slow-mo.** Compare app swing/ball speed with 240 fps video and set
      `effectiveRadiusM` (Racket tab → Swing radius). Check spin with a marked ball (rpm = 14,400 ÷ frames per turn)
      and adjust `ImpactModel.spinGain`.
- [ ] **Calibrate hit location** with the ball-drop grid (Racket tab → Calibrate racket…) and check the heat map
      matches where balls actually landed.
- [ ] **Accuracy slide helper:** a small script that lines up app numbers with slow-mo measurements and prints
      the error table for the demo slide.
- [x] **Mic impact sensing + on-device ML:** the INMP441 is read over I2S and a tiny int8 neural network on the
      ESP32-C3 answers "sweet spot?" and "how far off (%)". Firmware, trainer and docs are done: see [ml/README.md](../ml/README.md).
- [ ] **Flash the mic firmware** (`pio run -t upload`; it compiles for the ESP32-C3 but has never run on hardware)
      and confirm `SHOT …` lines appear on a hit. Check the trigger thresholds in `mic.cpp` and the `inference=…us` time.
- [ ] **Collect ~100+ labelled clips and retrain** (`tools/collect_clips.py`, then `python3 ml/train.py --real data/impacts`).
      The shipped weights are trained on synthetic sound only.
- [ ] **App:** subscribe to the new `shotUUID` characteristic in `RacketBLE` and show/log `ShotVerdict` (decoder exists).
- [ ] **Run on the real devices:** install on the iPhone and Watch from Xcode, load Gemma on the iPhone over good
      Wi-Fi, and check iCloud sync from iPhone → Mac.
- [ ] **Record a backup demo session** (and a short screen recording) in case Bluetooth misbehaves on stage.
