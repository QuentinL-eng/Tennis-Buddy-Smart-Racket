# 🎾 TennisRobot

A camera on an **Arduino UNO Q** — or an **iPhone 16 feeding a Windows PC** —
watches a tennis ball, predicts where its flight will cross a chosen strike
plane, and tells an **Epson C8 / RC700-E** where to sweep a racket so that a
**specific point on the string bed** meets the ball.

This is the initial framework, not a finished robot. The Python pipeline,
monocular estimator, swing planner, safety gates and simulated loop are
implemented and tested. The UNO Q Linux side has run the test suite and the
simulation; **no camera, arm or Epson controller has been run yet.** The Epson
SPEL+ program is a reference skeleton that must be compiled and validated on the
controller. The iPhone 16 path has a PC receiver, fake server and diagnostic;
its real USB-C/Ethernet link is not measured yet.

> **Simulation status:** 49 tests pass on the development laptop. The UNO Q
> Linux side has run the earlier 37-test suite and the simulation; the new
> remote/clock tests have not been run on the board yet. On the default slow
> feed (9.2 m/s at the strike plane, 240 fps simulated
> camera) the pipeline hits 4/4 balls with a median total error of 6.0 cm (2.7 cm
> perception + 3.8 cm execution). Across seeds 1, 2, 3, 7 and 11: 19 strikes, 18
> hits, no faults. These are simulation numbers with an optimistic noise model,
> not a hardware guarantee. The UNO Q's measured 48-observation fit is about
> 140 ms, so the board does not sustain the default 240 fps live cadence yet.

## How it works

```
USB camera ──► UNO Q Linux side (Debian, Python)
                  │  HSV detection → gated observations
                  │  drag-aware 6-state flight fit
                  │  strike-plane intercept
                  │  racket impact-point + swing plan + safety envelope
                  ▼
             Ethernet (TCP, three poses + speed + lead time)
                  ▼
            Epson RC700-E / SPEL+  ←── hardwired E-stop, guarding
                  ▼
            C8 arm ──► racket at impact_point_m
```

The UNO Q owns perception and prediction. **All real-time motion stays on the
Epson controller**: the Linux side never streams servo targets. It sends a
pre-swing pose, a strike pose, a post-swing pose, a speed and a lead time, then
waits for `DONE`. If the UNO Q stops or the network fails, no *new* motion is
queued, but a motion already executing on the controller continues. The
hardwired E-stop on the controller's safety circuit is the only reliable stop.

### The point on the racket

The racket frame is defined with its origin at the butt cap, **+Z up the shaft**,
**+Y out of the string bed**, and **+X across the strings**. The designated
contact point is `racket.impact_point_m` in that frame (default
`[0, 0, 0.52]`, the 52 cm string-bed centre used by the Tennis Buddy racket).
The planner solves for the **flange pose** that puts *that point* on the ball:

```
T_world_racket = [R | p_impact − R · p_impact_local]
T_world_flange = T_world_racket · inverse(T_flange_racket)
```

`T_flange_racket` (`racket.mount_pose`) is the measured physical mount. Change
the mount or the contact point and the commanded arm pose changes accordingly;
the arm is never commanded to put the flange on the ball.

## Quickstart

```bash
python -m venv .venv
# Linux / UNO Q:
source .venv/bin/activate
# Windows:
# .venv\Scripts\activate

python -m pip install -e ".[vision,dev]"

python -m tennisrobot simulate --shots 4
python -m tennisrobot feasibility --config config/default.toml
python -m tennisrobot replay runs/<recording>.jsonl
python -m pytest
```

Without installing, prefix commands with `PYTHONPATH=src`:

```bash
PYTHONPATH=src python -m tennisrobot simulate --shots 4
```

### iPhone camera + Windows PC

The iPhone 16 runs [`ios/TennisCamera`](ios/TennisCamera), which captures
1080p240 and sends 2D observations over TCP. The Windows PC runs the existing
3D estimator, planner, safety and arm code:

```powershell
# With the iPhone app running and iproxy forwarding USB-C port 5000:
iproxy 5000 5000
python tools/iphone_check.py --config config/iphone.toml --duration 10
python -m tennisrobot run --config config/iphone.toml --arm --duration 10
```

`config/iphone.toml` keeps the arm mocked. Without an iPhone, test the whole
receiver with `python tools/fake_iphone.py --config config/iphone.toml` in one
terminal and the pipeline in another. See
[`docs/REMOTE_IPHONE.md`](docs/REMOTE_IPHONE.md) for USB-C/`iproxy`, Ethernet,
calibration placeholders and troubleshooting.

`simulate` writes a JSONL recording to `runs/` by default (gitignored); use
`--no-record` to keep a run in memory only. `replay` re-fits a recording without a
camera or arm, which is the fastest way to tune thresholds and inspect a shot.

## Repository layout

| Path | Contents |
|---|---|
| [`src/tennisrobot/`](src/tennisrobot/) | Python package: camera model, detector, estimator, racket, planner, safety, arm clients, remote iPhone receiver, pipeline, CLI |
| [`config/`](config/) | [`default.toml`](config/default.toml) simulation, [`uno_q.toml`](config/uno_q.toml) hardware, [`camera_only.toml`](config/camera_only.toml) camera bring-up, [`iphone.toml`](config/iphone.toml) iPhone receiver |
| [`ios/`](ios/) | [`TennisCamera`](ios/TennisCamera) iPhone 16 capture/detector app and its Swift sources |
| [`tests/`](tests/) | 49 tests: geometry, physics, estimator, planner, arm protocol, remote packet/source and the full simulated loop |
| [`tools/`](tools/) | [`iphone_check.py`](tools/iphone_check.py), [`fake_iphone.py`](tools/fake_iphone.py), [`camera_check.py`](tools/camera_check.py), [`calibrate.py`](tools/calibrate.py), [`fake_arm.py`](tools/fake_arm.py) |
| [`epson/`](epson/) | [`strike_server.prg`](epson/strike_server.prg) reference SPEL+ server and its validator notes |
| [`docs/`](docs/) | Architecture, feasibility, calibration, safety, protocol, iPhone receiver and staged bring-up |

## Hardware assumed

| Part | Role in this framework |
|---|---|
| **Arduino UNO Q** | Runs the Linux/Python pipeline. The camera plugs into its USB-C port through a hub. The STM32 MCU is unused in v1; the hard E-stop belongs on the controller, not the UNO Q. |
| **Camera** | A UVC camera with manual exposure, or an iPhone 16 running the bundled app. For a real ball, aim for **global shutter, ≥240 fps, short exposure**, and at least ~5 px of ball radius at the commit point. A 30 fps webcam cannot see a 10 m/s ball clearly enough; see [`docs/FEASIBILITY.md`](docs/FEASIBILITY.md). |
| **iPhone 16 + Windows PC** | Alternative sensor/host for the iPhone path. The phone captures and detects; the PC runs the 3D pipeline. USB-C is tunnelled with `iproxy`; Ethernet is also supported. See [`docs/REMOTE_IPHONE.md`](docs/REMOTE_IPHONE.md). |
| **Epson C8 + RC700-E** | Executes the swing. The C8-B901S has 901 mm reach and a 3 kg nominal / 8 kg maximum payload (per Epson's page); check your exact model, payload and inertia with the racket and mount. RC+ 7/8 and SPEL+ are used for the socket server. |
| **Racket + mount** | Defaults match the Tennis Buddy racket (686 mm, 325 g, string-bed centre 520 mm from the butt). The mount and the designated impact point must be measured. |
| **E-stop, guarding, ball machine** | Required before any powered test. See [`docs/SAFETY.md`](docs/SAFETY.md). |

## Run against hardware

```bash
# 1. Camera only, simulated strikes: tune the detector and estimator.
python -m tennisrobot run --config config/camera_only.toml --arm

# 2. Camera + Epson, read-only: heartbeats and tracking, no strike commands.
python -m tennisrobot run --config config/uno_q.toml --monitor

# 3. Only after calibration and a cleared cell: real strike commands.
python -m tennisrobot run --config config/uno_q.toml --arm
```

Step 2 requires the SPEL+ server to be running. Step 3 is a robot motion command:
read [`docs/SAFETY.md`](docs/SAFETY.md) and [`docs/BRINGUP.md`](docs/BRINGUP.md)
first. `config/uno_q.toml` ships with placeholder calibration values; do not
trust them.

For the iPhone path, use `config/iphone.toml` instead. Its arm is mocked and its
camera calibration is a placeholder; the receiver and packet tests do not make
the camera calibrated. See [`docs/REMOTE_IPHONE.md`](docs/REMOTE_IPHONE.md).

## What this framework does not do yet

- **No measured calibration values.** Camera intrinsics/pose, arm base pose,
  racket mount and impact point are placeholders.
- **No hardware validation** of the camera, network latency, Epson server or
  motion timing. The iPhone USB-C/Ethernet link and its real clock offset have
  not been measured on the Windows PC yet.
- **Monocular depth is weak.** Spin is not observed and is configured, not
  estimated; there is no bounce, spin or rebound model.
- **No full swept-volume check.** The software envelope checks the impact point
  and three flange poses, not every point on the racket.
- **The SPEL+ reference is unverified.** Its `SetNet`/`OpenNet`, input parsing and
  `U,V,W` conventions must be checked against the RC+ manual for your version.

## Safety

The software watchdog, envelope and `ABORT` message are **not safety-rated**.
They do not replace the RC700-E safety circuit, a hardwired E-stop, guarding or a
restricted work envelope. The socket `ABORT` is best-effort: a single-task SPEL+
server cannot read it while a motion is executing. Do not enable `--arm` with a
person inside the reach of the arm or the racket. Read
[`docs/SAFETY.md`](docs/SAFETY.md) in full.

## License

MIT, as part of the Smart Racket / Tennis Buddy repository. See the repository
root `LICENSE.md`.
