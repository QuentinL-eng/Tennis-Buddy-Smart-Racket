# Sweet-spot model (open-source, on-device ML)

A ~370-parameter neural network that runs **on the racket's ESP32-C3**, listens to the impact sound from the
INMP441 microphone and answers two questions for every hit:

1. **Did we hit the sweet spot?** (yes/no, within 4 cm of the string-bed centre, same radius as the app's `ShotMetrics.sweetSpotRadiusCm`)
2. **If not, roughly how far off?** A percentage, 0 % = sweet spot, 100 % = at the frame (12 cm from centre).

Everything is open: the architecture, training code, synthetic-data generator, data-collection tool and the trained
weights (`firmware/src/sweetspot_model.h`) are all in this repository under the project's MIT license. No cloud, no
runtime library, no proprietary tooling: training is plain numpy.

> **Status.** The shipped weights are trained on *synthetic* impact sounds (`synth.py`) because real labelled data
> does not exist yet. The whole pipeline is real and tested end to end, but the accuracy numbers below are
> synthetic-data numbers. **Retrain on real clips as soon as you have ~100 (`tools/collect_clips.py`, below).**

## How it works

```
INMP441 mic ──I2S 16 kHz──► impact trigger ──► 32 ms clip (512 samples, 64 before the hit)
        ──► 12 features ──► MLP 12→16→8→2 (int8 weights) ──► { sweet?, off-centre % } ──► BLE + serial
```

**Why sound?** A ball hitting the sweet spot makes a short, bright "pop". Hits toward the frame are duller and
excite the racket frame, which rings at low frequencies for tens of milliseconds. Those differences are
visible in a few spectral and timing numbers, so a tiny model is enough.

**Features** (`features.py` is the spec, `firmware/src/sweetspot.cpp` the C++ copy). All are level-invariant, so
a hard hit and a soft hit at the same spot look alike:

| # | Feature | Meaning |
|---|---|---|
| 0–7 | log relative energy at 250, 500, 800, 1200, 1800, 2600, 3800, 5500 Hz | spectral shape (Goertzel filters, cheaper than an FFT) |
| 8 | decay | how long the sound takes to fall to 25 % of its peak (frame ringing is long) |
| 9 | attack share | fraction of energy in the first 8 ms (pop vs. ring) |
| 10 | zero-crossing rate | rough pitch / brightness |
| 11 | crest factor | peak vs. RMS, sharpness of the hit |

**Model.** 12 → 16 (ReLU) → 8 (ReLU) → 2. Output 0 is a sweet-spot logit (binary cross-entropy), output 1 is the
off-centre amount (mean squared error). Weights are quantised to **int8** (symmetric, one scale per layer):
the model is under 0.5 KB of flash and inference takes well under a millisecond of compute plus a few ms for
features on the C3's 160 MHz RISC-V core (it has no FPU; the firmware prints `inference=…us` for every shot so
you can measure it). If the model says "not sweet" the percentage is floored at 33 % (the edge of the sweet
disc) so the two answers never contradict each other. Confidence is the model's probability for its chosen call.

**Impact trigger.** `firmware/src/mic.cpp` runs a 64-sample pre-trigger ring buffer and fires when the signal
exceeds max(1500, 8 × the running noise floor), with a 250 ms refractory period. Clips are classified in a
low-priority task so the 1 kHz IMU sampler is never delayed.

## Results so far (synthetic data only)

From `ml/last_training_run.txt` (`python3 ml/train.py`):

| Set | Sweet/not accuracy | Off-centre error (on misses) |
|---|---|---|
| Validation, float | 86.7 % | 10.8 percentage points |
| Validation, int8 (what runs on the racket) | 86.7 % | 14.1 points |
| Unseen simulated rackets, int8 (wider mode/mic spread) | 84.0 % | 16.7 points |

The C++ firmware code and the Python reference agree (`python3 ml/test_parity.py`: feature error 2e-4,
100 % identical decisions). Errors cluster at the 4 cm boundary, which is expected: a ball 3.5 cm and 4.5 cm
from centre sound nearly identical. **These numbers say the pipeline works, not how well the racket will
do. Do not quote them as real-world accuracy.**

## Getting real data and retraining (the important bit)

1. Flash the firmware. Wire the INMP441 as in `docs/PLAN.md` (SCK D6, WS D7, SD D10, L/R to GND).
2. `pip install pyserial` then `python3 tools/collect_clips.py --port /dev/cu.usbmodemXXXX`
3. Drop or hit a ball on a known spot (the app's drop-grid calibration gives you the positions). Each impact
   prints a `SHOT` line and a clip is captured. Type the distance from the sweet-spot centre in cm
   (0 = centre, 12+ = frame). Aim for ~50 % within 4 cm and the rest spread to the frame, across hits at several
   speeds, and ideally with two or three different rackets/strings.
4. `python3 ml/train.py --real data/impacts` blends the real clips (up-weighted) into the synthetic set;
   `--real-only` ignores synthetic data once you have ~300+ real clips.
5. The trainer rewrites `firmware/src/sweetspot_model.h`. Rebuild and flash (`pio run -t upload`). Run
   `python3 ml/test_parity.py` to confirm the firmware code still matches.

## Files

| File | Purpose |
|---|---|
| `features.py` | Feature spec (Python reference) |
| `synth.py` | Physics-inspired synthetic impact sounds + labels |
| `train.py` | numpy trainer, int8 quantiser, header exporter, accuracy report |
| `test_parity.py`, `c_parity_main.cpp` | Compiles the firmware C++ on a laptop and compares with Python |
| `model.npz` | Trained weights for the parity test |
| `last_training_run.txt` | Output of the last training run |
| `../firmware/src/sweetspot.{h,cpp}` | On-device features + inference (no Arduino dependencies) |
| `../firmware/src/sweetspot_model.h` | **Generated** weights |
| `../firmware/src/mic.{h,cpp}` | I2S capture, impact trigger, runs the model |
| `../tools/collect_clips.py` | Labelled data collection over USB serial |

## Output paths

* **USB serial:** `SHOT SWEET off=0% conf=91% p=0.91 peak=… inference=…us` per impact.
* **BLE:** characteristic `7E5B0005-…` (notify), 6-byte `TBShot` (`firmware/include/protocol.h`):
  `u16 seq, u8 sweet, u8 off_pct, u8 confidence, u8 level`. Decoder: `RacketProtocol.decodeShotVerdict` in RacketKit.

## Limitations (be upfront with judges)

* Trained on simulated sound so far; real accuracy is unknown until retrained on real clips.
* Sound depends on string tension, racket model and mic placement. Retrain per racket for best results.
* The mic is inside the handle: a very loud impact may clip (`level` near 255); features are robust to mild clipping, not severe.
* Court noise (other balls, voices) can false-trigger; the 1 kHz IMU stream could be used to gate triggers (not done).
* Mishits that sound alike (symmetric positions) cannot be told apart: it estimates distance, not direction.
