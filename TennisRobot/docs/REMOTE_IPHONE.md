# Windows PC receiver for the iPhone camera

This is the PC half of the iPhone camera path. The iPhone 16 runs the
`ios/TennisCamera` app, captures 1080p240 and detects the ball. The Windows PC
receives only 2D observations, runs the 3D estimator, planner, safety monitor
and arm client, and keeps the recording/replay path.

```text
iPhone 16 (TennisCamera)
  1080p240 capture + detector
        │  40-byte TCP packets
        │  USB-C via iproxy, or Ethernet
        ▼
Windows PC (this repository)
  RemoteObservationSource → estimator → planner → safety → EpsonArm/MockArm
```

The phone does **not** run the 3D fit and does **not** command the arm. The PC
owns the camera calibration, strike plane, racket model, safety envelope and
the Epson protocol. The observation stream is tiny; it carries `(t_capture, u,
v, radius, confidence)` and a status packet, not video.

> **Status:** the receiver, fake iPhone server, diagnostic and tests are
> implemented. They have been exercised end to end with the fake server on
> Windows. A real iPhone 16 over USB-C/`iproxy` has not been measured on this PC
> yet; the live check below is the first test to run.

## 1. Prerequisites

On the Windows PC:

- Python 3.11 or newer.
- This repository, with the package installed:

  ```powershell
  py -3.11 -m venv .venv
  .\.venv\Scripts\Activate.ps1
  python -m pip install -e .
  ```

  The remote path needs only NumPy. OpenCV is not needed on the PC because the
  iPhone does the detection.

- Apple Devices (the Microsoft Store app) or iTunes, which installs the Apple
  Mobile Device Service used by the USB tunnel.
- A Windows `libimobiledevice` build that includes `iproxy`. There is no
  package in this repository that supplies it; install a current Windows build
  (for example the `L1ghtmann/libimobiledevice` releases) and check that
  `iproxy --help` runs. Keep `iproxy` on `PATH`.
- A data-capable USB-C cable. A charge-only cable will pair but will not carry
  the tunnel.

On the Mac (build machine only):

- Xcode and XcodeGen.
- The iPhone 16, with developer mode enabled and the app signed for your team.

## 2. Build and run the iPhone app

The app source is in [`ios/TennisCamera`](../ios/TennisCamera). It listens on TCP
port **5000**, accepts one client at a time, and keeps capturing if the client
disconnects.

```bash
cd ios/TennisCamera
brew install xcodegen        # once
xcodegen generate
open TennisCamera.xcodeproj
```

In Xcode, select the app target, set your development team and a unique bundle
identifier, choose the iPhone 16, and run. Keep the app in the foreground with
the screen unlocked; iOS suspends capture when the app goes to the background.

Check the app's own display before involving the PC:

- selected format is **1920×1080 at 240 fps** (120 fps is the documented
  fallback; 30/60 fps is not sufficient for a real ball);
- measured capture rate is close to 240 fps;
- detector median is under roughly 4 ms;
- thermal state stays nominal or fair.

If the app reports a fallback resolution, either make the app select 1920×1080
again or change `camera.width`/`camera.height` in `config/iphone.toml`. The PC
rejects observations whose frame size does not match the config.

## 3. USB-C with iproxy

1. Connect the iPhone to the PC with the data cable, unlock it, and tap
   **Trust**.
2. Confirm the Apple Mobile Device Service is running (`services.msc`).
3. In PowerShell, start the tunnel and leave it running:

   ```powershell
   iproxy 5000 5000
   ```

   The first number is the PC's local port; the second is the port the iPhone
   app listens on. `iproxy` forwards a TCP connection made to
   `127.0.0.1:5000` over the USB cable to the phone.

4. Do not test the port with a tool that opens and closes a connection.
   `Test-NetConnection` and similar probes count as the app's one client and
   can make the real client look disconnected. Use the receiver check instead.

The iPhone app's status packet proves the link is alive. The PC does not need a
special USB driver beyond the Apple service and `iproxy`.

## 4. Diagnostic check

With the app running and `iproxy` active:

```powershell
python tools/iphone_check.py --config config/iphone.toml --duration 10
```

The check connects, prints one line per second, and exits non-zero on a
connection or protocol failure. A healthy idle stream looks like:

```text
target: 127.0.0.1:5000  frame 1920x1080  expected 240 fps
t=  1.0s  packets    2.0/s  obs    0.0/s  gaps  0  clock offset  84123.4 ms  phone 240.0 fps  det  1.4 ms  drop 0  thermal nominal  source ok
t=  2.0s  packets  241.0/s  obs  238.0/s  gaps  0  clock offset  84123.4 ms  phone 240.0 fps  det  1.5 ms  drop 0  thermal nominal  source ok
```

- `packets` includes observations and status packets. With no ball, expect
  about 2 status packets per second; while a ball is visible, expect roughly
  240 observation packets per second.
- `obs` counts observations handed to the estimator.
- `gaps` counts sequence gaps, which indicate lost or dropped packets.
- `clock offset` is the estimated phone-to-PC clock offset, taken from the
  minimum `arrival − capture` difference. The two devices have unrelated clock
  epochs, so this number can be large or negative; it is **not** network
  latency. The receiver uses it to map capture timestamps onto the PC clock.
- `phone` comes from the status packet: capture fps, detector median, dropped
  frames and thermal state.
- `source` is `ok` while a packet has arrived within
  `safety.source_timeout_s` (2 s in `config/iphone.toml`).

Acceptance before running the pipeline:

- the check reports `OK` and exits 0;
- status shows 240 fps (or a documented 120 fps fallback);
- detector median is under roughly 4 ms;
- `gaps` stays 0 during a throw;
- the clock offset stays stable;
- the source stays `ok`.

Without an iPhone, exercise the whole receiver with the fake server:

```powershell
python tools/iphone_check.py --fake --duration 10
```

The fake server sends the same 40-byte packets from the existing simulator. It
is a transport/receiver test, not a camera test.

## 5. Run the PC pipeline

With the iPhone stream healthy:

```powershell
# Monitor only: fits and intercepts, no strike authority.
python -m tennisrobot run --config config/iphone.toml --monitor --duration 10

# Mock arm: strikes are planned and simulated; no hardware moves.
python -m tennisrobot run --config config/iphone.toml --arm --duration 10
```

`config/iphone.toml` keeps `[arm] kind = "mock"` on purpose. The mock arm
reports a strike at the planned time with the configured jitter; it does not
provide ground truth for the hit, so the summary will show strikes as
`UNVERIFIED`. That is expected for the remote path with a mock arm.

The same configuration can be run against the fake server in two terminals:

```powershell
# Terminal 1
python tools/fake_iphone.py --config config/iphone.toml --duration 30

# Terminal 2
python -m tennisrobot run --config config/iphone.toml --arm --duration 10
```

The fake server accepts one client. The check and the pipeline cannot both be
connected at the same time; stop the check before starting the pipeline.

## 6. Ethernet instead of USB-C

The same app and packet format work over Ethernet. The PC connects directly to
the phone's IP instead of `127.0.0.1`:

```toml
[camera]
kind = "remote"
remote_host = "192.168.1.42"   # the iPhone's address
remote_port = 5000
```

- The PC and phone must be on the same network.
- The iPhone app must have local-network permission. If the listener is
  unreachable, check **Settings → Privacy & Security → Local Network**.
- Windows Firewall usually allows the outbound connection; no inbound rule is
  required for the PC as the client.
- Ethernet avoids `iproxy`, but a USB-C Ethernet adapter is still a dongle and a
  cable. USB-C through `iproxy` is the shortest physical path for the desk.

## 7. Configuration and calibration

[`config/iphone.toml`](../config/iphone.toml) is the remote-camera profile. The
values that matter first:

| Key | Meaning |
|---|---|
| `camera.width`, `camera.height` | Must match the iPhone capture format exactly. |
| `camera.remote_host`, `camera.remote_port` | `127.0.0.1:5000` for `iproxy`; the phone IP and 5000 for Ethernet. |
| `camera.fps` | The expected rate. The app's status packet is authoritative for the actual rate. |
| `camera.horizontal_fov_deg` | **Placeholder** for the iPhone wide camera. Calibrate it. |
| `camera.distortion` | **Placeholder** `[k1, k2, p1, p2]`. Calibrate it. |
| `camera.look_at` | **Placeholder** camera mount pose. Measure it. |
| `camera.latency_s` | Leave 0 until you measure a residual capture-to-observation bias. The receiver subtracts this value from each observation timestamp. |
| `safety.source_timeout_s` | 2 s here because the app sends a status about once per second. |
| `run.fit_every_n_frames` | 12 at 240 fps gives a 20 Hz fit cadence. |
| `[arm] kind` | Stay `"mock"` until the Epson and the cell are validated. |

The camera intrinsics, camera pose and strike plane are not measured by the
receiver. Follow [`CALIBRATION.md`](CALIBRATION.md), then replace the
placeholders. A frame-size mismatch is rejected at the protocol boundary; a
pose or intrinsics error will show up as high fit RMS and bad intercepts.

`camera.latency_s` is a calibration adjustment, not a substitute for measuring
the link. The receiver maps the phone's capture clock to the PC clock using the
minimum observed `arrival − capture` delay. That estimate absorbs the constant
phone clock offset plus the minimum detector/transport delay, so observation
timestamps carry a small constant late bias. Measure it with a known event
(flashing LED, photogate, or a recorded high-speed reference) and set
`camera.latency_s` to the residual you want to remove. Do not guess a value.

## 8. Protocol and clock details

The wire format is fixed and little-endian:

```python
PACKET = struct.Struct("<I B B H I Q f f f f H H")  # 40 bytes
```

Fields: magic `0x424F5254`, version 1, kind (0 observation / 1 status),
header size 40, sequence, capture timestamp in nanoseconds, `u`, `v`, `radius`,
`confidence`, width, height. A status packet reuses `u` for measured fps, `v`
for detector median ms, `radius` for dropped frames and `confidence` for the
thermal index. The full contract and the Swift encoder are in
[`MACBOOK_AI_PROMPT.md`](MACBOOK_AI_PROMPT.md) and
[`ObservationPacket.swift`](../ios/TennisCamera/Sources/ObservationPacket.swift).

The iPhone's presentation timestamp and the PC's clock have different epochs.
The receiver estimates the offset from the minimum arrival−capture delay and
maps every observation onto the PC's monotonic clock. It ignores a zero
timestamp rather than poisoning the offset, and it accepts a startup status
packet whose frame size is still 0×0.

All PC timing uses [`clock.py`](../src/tennisrobot/clock.py), which is
`time.perf_counter()`/`perf_counter_ns()`. Do not replace it with
`time.monotonic()` on Windows: `monotonic()` has roughly 15.6 ms granularity
there, which is four frames at 240 fps. The source, pipeline and arm must share
this clock.

The receiver does not currently reconnect automatically after `iproxy` or the
app drops. The pipeline faults on a camera loss in armed mode; monitor mode
simply waits. Restart `iproxy` and the pipeline if the link drops. A reconnect
loop is a later addition; it must not hide a camera outage from the safety
monitor.

## 9. Troubleshooting

| Symptom | Check |
|---|---|
| `cannot connect ... within 5.0s` | App running? `iproxy 5000 5000` running? iPhone trusted and unlocked? Port already used (`netstat -ano | findstr :5000`)? |
| `iPhone frame is 1280x720, but camera.width/height is 1920x1080` | The app fell back to 720p or the config is wrong. Fix the app format or the config; the PC will not silently rescale. |
| `unsupported packet version` / `bad packet magic` | Wrong app build or a non-TennisCamera process on the port. Restart the app and `iproxy`. |
| `camera stopped delivering frames` | The source went longer than `source_timeout_s` without any packet. App backgrounded, thermal stop, cable pulled, or `iproxy` died. |
| `protocol error` in the check | A malformed stream or a frame-size mismatch. The check prints the exact reason and exits non-zero. |
| `gaps` increasing | Packets are being lost. Check the cable/hub, close other clients, and watch the phone's dropped-frames status. |
| Status says `serious`/`critical` thermal | Stop; cool the phone, reduce resolution or use the 120 fps fallback. Thermal throttling will ruin timing. |
| Pipeline says `too early` repeatedly | Normal while the estimator is collecting a flight; also check `max_lead_s` and the feed timing. It is not a transport error. |
| Strikes are `UNVERIFIED` | Expected with `MockArm`: it has no ground-truth ball position. Use the simulation for hit statistics. |
| Fit RMS is high | Calibration placeholders, detector thresholds, or the ball not being a clean yellow blob in the ROI. Use a recording and `python -m tennisrobot replay runs/<file>.jsonl`. |

## 10. Safety

The Windows PC is a motion-planning host, not a safety system. Do not enable a
real Epson arm from this path until the camera and arm calibration, the physical
E-stop, guarding and the restricted work envelope have been verified. The
`[arm] kind = "mock"` default is deliberate. Read [`SAFETY.md`](SAFETY.md) and
[`BRINGUP.md`](BRINGUP.md) before changing it.
