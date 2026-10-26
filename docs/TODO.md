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
- [ ] **Mic impact sensing (stretch, firmware):** read the INMP441 over I2S (SCK D6, WS D7, SD D10), send a short
      impact-sound feature (peak level + ring energy) in the status/IMU packet, and use it to sharpen impact timing
      and frame-hit detection.
- [ ] **Run on the real devices:** install on the iPhone and Watch from Xcode, load Gemma on the iPhone over good
      Wi-Fi, and check iCloud sync from iPhone → Mac.
- [ ] **Record a backup demo session** (and a short screen recording) in case Bluetooth misbehaves on stage.
