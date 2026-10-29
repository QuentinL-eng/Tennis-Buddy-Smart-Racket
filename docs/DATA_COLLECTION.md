# Sweet-spot data collection (for Codex and humans)

Goal: labelled impact-sound clips for the on-device sweet-spot model (`ml/`). A webcam films the racket from below
while balls are thrown onto the strings; the racket mic's clips and the video share one PC clock; the ball's landing
spot is read off the video afterwards. Run everything from the repo root on the Windows PC.

## Setup (once)

```bash
pip install pyserial opencv-python numpy openai meta-sam-parser pygrabber
```

* Racket flashed with the current firmware (`firmware/`), plugged in over USB. The scripts find its serial port
  and the external USB webcam (not the laptop camera) on their own; override with `--port COMx` / `--camera N`.
* Optional SAM pre-fill and scaling: put `MUSE_API_KEY=...` in the repo-root `.env` (git-ignored). SAM calls upload
  video frames (including faces) to Meta and cost money (about $2.50 per 1,000 images); the scripts print the
  cost and ask first. Do not print or commit the key.
* Racket held horizontal, head up, still in frame; balls thrown down onto the strings; webcam below looking up.
  Do not handle the racket while recording.

### Adaptive decay capture (new firmware)

Flash the updated firmware before collecting new samples (`pio run -e xiao_esp32c3 -t upload` in `firmware/`).
Collection retains 4 ms before the trigger and continues for 128 ms after the last sample whose absolute
value is at least 30000 (near full scale). If no sample reaches that level, it retains 128 ms after the trigger.
Recording stops at 1 second after the trigger even if clipping continues. The threshold is a conservative
clipping indicator; it does not prove that the microphone has recovered from all distortion.

First record five test impacts. Leave at least two seconds between drops during this check. The terminal
shows each clip's duration. Inspect the tail before collecting the full batch:

```powershell
python tools/listen_clip.py data/sessions/<session>/clips/clip-0001.i16 --tail-only
```

Open the resulting `.tail.wav` to hear the decay after the final near-full-scale sample. The tool also prints
how much tail remains. If it reports less than 128 ms, the recording reached the limit (or used older firmware).
Do not collect the full batch until the test confirms a usable decay recording.

`clips.csv` now includes `impact_t_s` and `samples`. The impact time is estimated from the firmware's trigger
age when it sends metadata, before the audio payload. SAM and the labeller use this estimate so longer clips
do not shift their initial video frame. USB buffering can still introduce timing error; check contact manually.
Older sessions retain the previous timing estimate.

The existing deployed model still uses the initial 512 samples (32 ms). Training accepts extended recordings
but explicitly reports that it uses only this initial window. The complete tail stays in the source clip for
decay analysis and a later model change. Old 32 ms clips cannot supply the missing decay tail.

## 1. Record a session

```bash
python3 tools/collect_session.py --name <note>
```

Writes `data/sessions/<time>-<note>/`: `video.avi`, `frames.csv`, `clips.csv`, `clips/*.i16`. Press `q` in the
preview window to stop. The preview flashes green on each impact; the terminal marks `** CLIPPED` when the mic
saturated (most throws do; the clips are still saved).

## 2. Label from the video

```bash
python3 tools/label_video.py data/sessions/<session>
```

* First run: calibrate. Scrub (`a`/`d` 1 frame, `w`/`s` 5, `j`/`k` 60) to a frame with the racket clear, click the
  string-bed centre, click a point toward the tip, type its distance in cm in the terminal. Press `c` to redo.
* Per impact: step to the frame the ball touches the strings; click the ball, then the string-bed centre (marks are
  cleared when you step frames); Enter accepts, `x` discards (handling noise, bounces, double triggers), `b` or
  Ctrl+Z goes back, `q` saves and quits. Progress is saved after every label; `--redo` relabels everything.
* Output: `labels.csv` (`file,dist_cm`, what `ml/train.py` reads), `positions.csv`, `discarded.txt`.

## 3. Optional: SAM pre-fill (before step 2) and scaling (after)

```bash
python3 tools/sam_prefill.py data/sessions/<session> --probe     # one frame, check the boxes in sam_probe.jpg
python3 tools/sam_prefill.py data/sessions/<session>             # all impacts, asks before uploading
python3 tools/sam_scale.py   data/sessions/<session>             # after labelling
```

`sam_prefill.py` pre-fills the ball and racket-head clicks in the labeller. `sam_scale.py` rescales every label from
the racket's string-bed area (set to 100 in^2, change with `--head-area`) so racket movement toward or away from
the camera is accounted for. It supersedes `tools/sam_refine.py`. Originals stay in `labels_unscaled.csv`.

## 4. Train

```bash
python3 ml/train.py --real data/sessions/<session>
```

`ml/train.py --real` reads one folder (`labels.csv` plus the clips it names). To combine sessions, copy clips and
labels into one folder first. Use `--real-only` once there are roughly 300 or more real clips. Then rebuild and flash
the firmware (`pio run -t upload` in `firmware/`) and run `python3 ml/test_parity.py`. Keep one whole session
out of training as a test set.

## Known issues

* The mic (INMP441) saturates on most throws. Check `** CLIPPED` and the `peak=` values; attenuating the mic
  mechanically would help. Decay and attack features are unreliable on clipped clips.
* The firmware prints samples big-endian; the scripts convert them to little-endian `.i16`. Clips recorded earlier on
  2026-10-27 were byte-swapped and repaired in place (a `byteswap_fixed` marker file in a session folder shows it).
* Only the first ~100 labelled impacts exist so far; expect to need about 300 to 500 for a useful model.

## Phone + racket sessions (IMU swing data, ball ground truth)

For the IMU swing model: the iPhone app `TennisRobot/ios/TennisCamera` films at 240 fps, detects the ball, and
connects to the racket over BLE itself, so the camera frames and racket IMU packets are stamped on one clock.

1. Build the app (`xcodegen generate` in `TennisRobot/ios/TennisCamera`, new files were added; then run it on the
   phone). Allow camera and Bluetooth. Power the racket; the app finds it by its service UUID.
2. Phone on a tripod to the side, about 3 m from you, square to the swing plane, ball and racket in frame.
3. **Start capture**, wait for `racket: connected` and `imu` near 125 pkt/s (1 kHz samples, 8 per packet) with few lost, then **Record session**. Press **Mark** while knocking the racket on something in view (a sync point).
   **Stop recording** when done. Keep "Save 240 fps video" on unless frames drop; it needs about 2 GB per 10 minutes.
4. Copy `Files > On My iPhone > TennisCamera > sessions/<stamp>` to `data/phone/<stamp>` on the PC.
5. `python tools/phone_session.py data/phone/<stamp>` fits the racket-to-phone clock (offset, drift) and refines it
   from ball contacts; it writes `sync.json`, `imu_aligned.npz` and `ball_track.csv`. `--plot` shows the alignment.
   `python tools/test_phone_session.py` checks the aligner on synthetic data.

Hit gently into the blanket: a soft ball may not reach the 10 g impact threshold (use `--threshold 4`).

## In-app sweet-spot check (no PC needed)

Racket tab → **Calibrate racket…** ends with an optional sweet-spot check: tape a 3×3 grid on the strings (5 cm
across, 6 cm along), tap a square in the app, drop a ball on it. The center square is the sweet spot. The app pairs
each drop with the racket's on-device verdict and its own motion-sensor estimate, shows how often the model was right
(sweet and off-center separately), and saves `Calibration/sweetspot-check-<time>.csv` (Files app on iPhone, or the
share button). `dist_cm` matches `labels.csv`. It holds no audio, so it measures the deployed model on hardware but
cannot train it; use the webcam flow above for training clips.
