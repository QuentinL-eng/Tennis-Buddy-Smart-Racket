# Bring-up

Bring the system up in stages. Each stage has a gate; do not skip a gate because
the previous one "looked fine once".

```text
0. Simulation (no hardware)
1. UNO Q + camera (no arm)
2. Calibration (no ball)
3. Camera + mock arm (no robot motion)
4. Epson link, monitor only (no strikes)
5. Slow real strikes (robot motion!)
6. Slow feeds and tuning
```

Read [`SAFETY.md`](SAFETY.md) before stage 4. Stages 0–3 are safe to do at a desk.

## Stage 0 — Simulation

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
python -m pip install -e ".[vision,dev]"
python -m pytest
python -m tennisrobot simulate --shots 4
python -m tennisrobot feasibility --config config/default.toml
```

Gate: tests pass, the simulation strikes every shot, and the feasibility numbers
match your expectations. If 4/4 is not happening, do not proceed to hardware;
check the seed, the fit window and the lead window.

## Stage 1 — UNO Q and camera

The UNO Q is a dual-board: a Qualcomm Linux side (Debian) and an STM32 MCU. This
project runs on the **Linux side**. The MCU is unused in v1; do not put the
E-stop on it.

1. Boot the board, connect it to the network, and open a shell (SSH is the most
   practical; Arduino App Lab is optional). Verify:

   ```bash
   cat /etc/os-release
   python3 --version
   python3 -c "import cv2, numpy; print(cv2.__version__, numpy.__version__)"
   ```

   If OpenCV is missing, install the project extra in a venv (below). The research
   on the board reports Python 3.13 on a current image; check your own image.

2. Create a venv and install:

   ```bash
   cd ~/TennisRobot        # copy or clone the project here
   python3 -m venv .venv
   source .venv/bin/activate
   python -m pip install --upgrade pip
   python -m pip install -e ".[vision]"
   ```

   If `pip install opencv-python` is slow or fails on the board, use the distro
   package (`sudo apt install python3-opencv`) inside a venv created with
   `--system-site-packages`, or build a smaller OpenCV. Do not block the whole
   project on the full wheel.

3. Identify the camera. Do not hard-code `/dev/video0`: indexes move.

   ```bash
   v4l2-ctl --list-devices
   ls -l /dev/v4l/by-id/
   python tools/camera_check.py --device /dev/v4l/by-id/<camera>-video-index0
   ```

   Put the stable `/dev/v4l/by-id/...` path in `camera.device`. Add your user to
   the `video` group if needed and log in again. Close any other program using
   the camera; V4L2 devices are usually exclusive.

   On the UNO Q, connect the camera through a USB-C hub with its own Power
   Delivery supply. The board's USB-C port does not power downstream devices.
   If the camera does not appear, force host mode and re-check:

   ```bash
   sudo sh -c 'echo host > /sys/kernel/debug/usb/4e00000.usb/mode'
   ```

   This drops the USB link to the laptop, so configure Wi-Fi/SSH first.

4. Check the negotiated mode **and the real rate**. A camera that reports 240 fps
   but delivers 30 fps will silently ruin the timing. Try MJPG, a smaller
   resolution, a powered hub and a short cable. Record the measured rate.

   On the UNO Q's UVC driver, `buffersize = 1` halves the delivered rate
   (30 -> ~15 fps) while the driver still reports 30. Keep at least two buffers;
   `camera_check.py` defaults to two for this reason.

Gate: `camera_check.py` shows the intended resolution and a stable measured rate;
a saved frame is sharp enough to see the ball, and the ball is at least ~5 px in
radius at the commit distance. A 30 fps webcam passes the capture check but is a
detector/tracking bring-up only: the 240 fps timing design needs a high-speed
camera before any real strike.

## Stage 2 — Calibration

Follow [`CALIBRATION.md`](CALIBRATION.md) in full. The output is a set of values
in `config/uno_q.toml`, not a runtime calibration step. Keep the record.

Gate: a known world point projects onto its recorded pixel; the computed flange
pose touches a physical target at the marked string-bed point under RC+ manual
control at slow speed.

## Stage 3 — Camera and mock arm

No robot communication. The mock arm simulates strikes, but the camera, detector,
estimator, planner and safety run for real.

```bash
python -m tennisrobot run --config config/camera_only.toml --arm
```

- Watch the status lines: frame count, observations, fit RMS, predicted intercept.
- Tune `vision.hsv_lower/upper` for your ball, lighting and floor. Test against a
  white wall and a dark background; a black-and-white ball is easier than a
  fluorescent one in poor light.
- Confirm the predicted intercept is stable, not jumping by tens of centimetres
  between fits.
- Record a session and replay it:

  ```bash
  python -m tennisrobot replay runs/<file>.jsonl
  ```

Gate: with a ball machine at low speed, the detector holds the ball through the
flight and the fit residual stays below the safety limit. No real motion has
occurred.

## Stage 4 — Epson link, monitor only

1. Open [`epson/strike_server.prg`](../epson/strike_server.prg) in RC+, fix it
   against your SPEL+ reference, compile, and run it in a safe cell or the RC+
   simulator. Confirm the TCP port.
2. Test the protocol with the test double first:

   ```bash
   python tools/fake_arm.py --port 12000 --verbose
   ```

   Point `config/uno_q.toml` at the test double and run monitor mode. Confirm RTT
   and heartbeats. Then point it at the real controller.

3. Put the controller in a safe state, enable drives only as your procedure
   requires, and run:

   ```bash
   python -m tennisrobot run --config config/uno_q.toml --monitor --duration 60
   ```

   The Epson client is read-only in this mode: it sends `PING`, never `STRIKE`.
   Verify `rtt` is stable (wired network), no `FAULT`, and the camera watchdog
   does not trip.

Gate: 60 s of monitor mode with heartbeats, stable RTT and no fault; a deliberate
network unplug produces a fault, not a strike.

## Stage 5 — Slow real strikes

This is the first stage that moves the robot. Full safety procedure applies.

1. Set conservative values in `config/uno_q.toml`:

   ```toml
   [planner]
   swing_speed_m_s = 1.2
   min_swing_speed_m_s = 0.5
   max_lead_s = 0.40
   min_lead_s = 0.28

   [arm]
   max_tcp_speed_m_s = 1.5
   max_accel_m_s2 = 12.0
   response_timeout_s = 2.0
   max_misses_before_fault = 1
   ```

   Check the feasibility report after changing them:
   `python -m tennisrobot feasibility --config config/uno_q.toml`. The required
   lead must stay below `max_lead_s`; otherwise the planner can never commit.
2. Ball machine at its **lowest** speed, aimed at the strike zone. Use a soft or
   foam ball for the first attempts if you have one. Clear the cell.
3. One operator at the E-stop, one at the machine/PC. Start monitor mode first,
   then arm:

   ```bash
   python -m tennisrobot run --config config/uno_q.toml --arm
   ```

4. Observe the first strike. If anything is unexpected, E-stop. Do not "let it
   finish" to collect data.
5. Review the recording and the controller log. Compare planned vs. actual
   timing. If the arm is consistently early/late, stop and fix the controller
   timing (or `camera.latency_s` / `approach_ms`), not the tolerance.

Gate: repeated slow strikes with no fault, the racket point visibly near the
ball, and a recording that explains every miss.

## Stage 6 — Slow feeds and tuning

Only after stage 5 is boring. Increase ball speed in small steps, one variable at
a time:

1. Ball speed.
2. Swing speed.
3. Envelope size.

Watch the error split in the summary:

- **perception error** large → camera calibration, exposure, detection, fit
  window, spin.
- **execution error** large → timing jitter, network, controller timing, latency.
- **total error** large with both small → ground-truth evaluation is wrong, or
  the tolerance is being compared against the wrong point.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Camera not found | wrong device index, permissions, another process | `/dev/v4l/by-id`, `video` group, close other apps |
| Measured fps far below request | USB bandwidth, MJPG, hub/power, driver mode | `camera_check.py`, smaller ROI, powered hub |
| Ball not detected | HSV thresholds, exposure, blur, background | save a frame, tune HSV, short exposure, more light |
| Ball detected but fit fails | no radius, occlusion, camera pose wrong, few observations | detection radius, frame timing, calibration |
| Always "too early" | `max_lead_s` below the arm deadline, or late first detection | feasibility, camera view, max_lead |
| Always "too late" | camera latency, fit cadence, deadline, slow network | latency, fit interval, lead window |
| Arm refuses | not ready, read-only, fault, lead too short | arm status, RTT, controller log |
| No `DONE` | server not running, motion longer than timeout, parse error | fake arm, response_timeout, controller log |
| Systematic miss in one direction | base pose, mount, Euler convention, camera pose | calibration; do not shim the tolerance |
| Random misses | timing jitter, monocular depth, spin, ball feed | recording, error split, slower feed |
| Two strikes on one ball | buffer reset/cooldown, sequence handling | recording, state transitions |

## Rollback

If anything is uncertain: stop the pipeline, disable the controller drives, and
put the arm in a safe pose under manual control. Do not debug an armed system
with a ball machine running.

Keep a written record of the config and calibration used for every session.
Recordings in `runs/` are the evidence; a summary without a recording is not
reproducible.
