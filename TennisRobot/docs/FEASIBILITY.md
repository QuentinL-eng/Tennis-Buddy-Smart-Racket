# Feasibility and error budget

**Short version.** This architecture is viable for a **slow ball-machine feed**
(roughly 8–12 m/s at the strike plane) with a **global-shutter camera at
≥240 fps** and a well-calibrated cell. It is **not** viable for a 25–30 m/s serve
with the same camera, racket and arm. The limits are measured below, not guessed.

The defaults are a 9.2 m/s ball at the strike plane, a 240 fps camera, a 2.19 m/s
racket sweep and a 10 cm contact tolerance. In simulation the pipeline hits 4/4
balls with a 6.0 cm median total error.

## Camera: what a frame buys you

At the default 240 fps the frame interval is 4.17 ms. A ball moves:

| Ball speed | 30 fps (33.3 ms) | 120 fps (8.3 ms) | 240 fps (4.17 ms) | 600 fps (1.67 ms) |
|---:|---:|---:|---:|---:|
| 10 m/s | 33 cm | 8.3 cm | 4.2 cm | 1.7 cm |
| 20 m/s | 67 cm | 17 cm | 8.3 cm | 3.3 cm |
| 30 m/s | 100 cm | 25 cm | 12.5 cm | 5.0 cm |

A useful rule of thumb is **≤5 cm of ball travel per frame** for a detector and
tracker that are not relying on pure prediction. At 240 fps that ceiling is
**12 m/s**. For 30 m/s you need ~600 fps. A conventional 30 fps webcam is not a
starting point; it is a different problem.

Exposure matters as much as frame rate:

- At 10 m/s, a 0.2 ms exposure smears the ball by 2 mm.
- At 30 m/s, the same exposure smears it by 6 mm, about 9 % of a 67 mm ball.
- For ≤2 mm of blur at 30 m/s, use ~67 µs.

A **global shutter** keeps the geometry consistent; a rolling shutter reads rows
at different times and skews a fast ball. Manual exposure and stable illumination
are required: auto-exposure will fight a fluorescent ball against a changing
background.

The UNO Q exposes a USB-C port; a UVC camera works through a hub, and the board
can run OpenCV (Arduino's docs; a field test reports Python 3.13 and V4L2/OpenCV
capture). A published UNO Q demo runs a small YOLOv5 Pico model at ~17 fps at
640×480, and a Bridge RPC round trip has been reported around 8 ms. Those are
demonstrations, not guarantees for 720p at 240 fps: **measure the actual capture
rate and bandwidth on the board** with [`tools/camera_check.py`](../tools/camera_check.py).
A raw 720p stream at 240 fps is far beyond a typical USB 2 link; MJPG or a smaller
ROI is usually necessary. Compression artifacts can also damage a small ball, so
check the detector on real frames.

## Timing budget at the default feed

`python -m tennisrobot feasibility --config config/default.toml` prints:

```
flight to strike plane: 661 ms, speed 9.2 m/s, height 0.90 m
ball travel in 1 ms: 9 mm; in one camera frame: 3.8 cm

effective racket speed: 2.19 m/s
required lead: 201 ms
decision deadline: 280 ms
allowed window: 280-400 ms
hit tolerance 10 cm -> ~10.9 ms of timing budget
configured timing jitter 4.0 ms -> 37 mm of ball travel
```

Read that last pair carefully. A 10 cm contact tolerance sounds generous, but at
9.2 m/s it is only **10.9 ms** of ball travel. The mock arm's 4 ms timing jitter
alone consumes 37 mm of it. The arm's **positional** repeatability (±0.03 mm on a
C8-B901S) says nothing about its **temporal** repeatability; those are different
specifications.

## Prediction error vs. how early you commit

From 14 simulated shots with 0.25 px centre noise, 0.4 px radius noise and a
48-observation fit (the default), measured at the strike plane:

| Lead at decision | Median position error | 90th percentile |
|---:|---:|---:|
| 0.42 s | 2.9 cm | 6.0 cm |
| 0.38 s | 1.6 cm | 4.1 cm |
| 0.35 s | 1.7 cm | 3.0 cm |

That is why `max_lead_s` is 0.40 s rather than "commit as soon as possible". In
an earlier sweep, a shorter 0.15 s fit window at a 0.50 s lead gave ~12 cm median
error — enough to miss before the arm had moved.

The default **full-loop** simulation (4 shots, seed 7) reports:

```
hits=4/4
median execution error: 3.8 cm
median perception error: 2.7 cm
median total error: 6.0 cm
```

Execution error is dominated by the configured 4 ms timing jitter; perception
error is the monocular fit. Across seeds 1, 2, 3, 7 and 11 the full loop produced
19 strikes, 18 hits and no faults.

### Why monocular depth is the bottleneck

For a ball of radius `R` at camera-frame depth `z`, the projected radius is

```
r_px ≈ fx · R / z
```

so a one-pixel radius error becomes a depth error

```
δz ≈ z² · δr / (fx · R).
```

With `fx = 1229 px`, `R = 33.5 mm` and `δr = 0.4 px`: at 3 m, `δz ≈ 9 cm`; at
6 m, `δz ≈ 35 cm`. Averaging 48 observations and constraining them with the drag
model reduces the error, but the quadratic growth is why the system commits late
and why a second camera is the single biggest accuracy upgrade available.

Equivalently: at 3 m the ball is ~14 px in radius; at 6 m it is ~7 px. A small,
fast, blurred ball is a hard depth measurement.

## What these numbers assume

- The simulation uses the **same physics model** for truth and estimation. Real
  drag and spin differ; the fit assumes constant configured spin.
- Pixel noise is Gaussian (0.25 px centre, 0.4 px radius) with 1 % outliers. Real
  blur, compression, background clutter and exposure changes are worse.
- Calibration is exact and `camera.latency_s` is zero. An unmodelled 20 ms
  capture delay is 18 cm of ball travel at 9.2 m/s, so measure it.
- Camera pose errors translate directly into world-space error.
- The arm executes the commanded sweep with 4 ms timing jitter. The RC700-E's
  real timing distribution has not been measured.
- The ball hits the designated point within a 10 cm tolerance. A smaller target
  demands proportionally better timing.

Treat the simulation as a **relative** design tool: it is useful for comparing
camera rates, lead windows and jitter, not as a promise of centimetre accuracy on
court.

## Could it return a serve?

Not with this rig. A 30 m/s ball covers 30 mm every millisecond and crosses a
~10 cm contact window in about 3 ms. The arm's own sweep is 2.2 m/s, and the
prediction error even at 0.35 s lead is centimetres. The ball also spends less
than one frame in the strike zone at 240 fps. Hitting a serve requires a
different sensor and arm budget (multi-camera high-speed tracking, a specialised
fast manipulator, and a much tighter timing loop).

## What would widen the envelope

1. **A second camera (stereo).** Triangulation removes the size-depth ambiguity.
   This is the highest-value change.
2. **A known launch point/trigger from the ball machine.** If the ball starts at a
   known point at a known time, depth is far better constrained by the trajectory
   and many fewer parameters are free.
3. **Higher frame rate / shorter exposure.** 400–600 fps with a global shutter and
   enough light.
4. **Commit later with a faster pipeline.** The estimator fit is ~12 ms on the
   development laptop but ~140 ms on the UNO Q with the default 48-observation
   window. The board needs a lower-latency fit, or a faster compute module,
   before the commit can move from 0.4 s to 0.3 s.
5. **A longer swing runway or a faster arm.** The current 2.19 m/s is limited by
   the 0.20 m post-swing runway, not by the C8's top speed.
6. **A slower feed and a larger tolerance.** The honest v1 target.
7. **A proper spin/rebound model.** Needed for aiming and for real spin, not for
   merely making contact.

## Sources

- [Arduino UNO Q hardware](https://docs.arduino.cc/hardware/uno-q) — dual-brain
  board, Debian Linux side, USB-C/hub guidance.
- [UNO Q camera field test](https://prahari.net/blog/giving-my-robot-eyes-hp-w300-camera-on-arduino-uno-q-s-linux-side)
  — UVC, V4L2, OpenCV and unstable `/dev/videoN` indexes.
- [UNO Q YOLOv5 Pico demo](https://www.foundries.io/insights/blog/elf-detector-real-time-object-detection/)
  — ~17 fps at 640×480 for a small model, a throughput reference rather than a
  guarantee.
- [Epson C8-B901S / RC700-E product page](https://www.epson.eu/en_EU/products/robots/6-axis-robots/epson-prosix-c8-b901s-rc700-e-rc%2B-8/p/45807)
  — 901 mm reach, 3 kg nominal / 8 kg maximum payload, ±0.03 mm repeatability,
  RC+ 7/8, SPEL+.
- [Tennis ball aerodynamics](https://twu.tennis-warehouse.com/learning_center/aerodynamics2.php)
  — diameter, drag coefficient ~0.507, lift variation with spin, high-speed
  trajectory capture.
- [Rolling vs global shutter](https://www.teledynevisionsolutions.com/learn/learning-center/imaging-fundamentals/rolling-vs-global-shutter/).
- [Monocular ball trajectory estimation](https://arxiv.org/html/2506.05763v1) —
  the 2D-to-3D ambiguity and the sensitivity of physics-based fitting.
