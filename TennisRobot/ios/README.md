# TennisCamera — iPhone 16 high-speed ball camera

The iPhone is a **sensor**. It captures 1920x1080 at 240 fps, finds the tennis
ball with a threshold-and-centroid detector, and streams one fixed 40-byte
observation packet per detection over TCP. The USB-C cable carries those
packets through Apple's `usbmuxd` to a host running `iproxy`.

The phone does **not** estimate 3D flight, plan a swing, or talk to the Epson
controller. That all stays in the Python pipeline
([`../src/tennisrobot`](../src/tennisrobot)) and on the robot PC.

```
iPhone 16                          USB-C / usbmuxd            host
AVCaptureSession 1920x1080@240
  -> AVCaptureVideoDataOutput (420f)
  -> BallDetector -> FlightTracker (3D fit + intercept)
                             -> ObservationServer :5000  ->  iproxy 5000 5000
                                                              -> tools/iproxy_receiver.py
                                                              -> PC RemoteObservationSource (later)
```

## Status

Verified on an **iPhone 16 (iPhone17,3), iOS 27.2**, built with Xcode 27.0 and
driven from a MacBook over Wi-Fi:

| Check | Result |
|---|---|
| Builds for iOS simulator (Release) | pass |
| Builds for `generic/platform=iOS` (arm64) and signs | pass |
| Installed and launched on the device | pass |
| Unit tests (15) | pass |
| Detector on a synthetic 1080p frame | centroid and radius within 1 px |
| `CVPixelBuffer` → detector → TCP socket (end-to-end test) | pass, packet validated byte-for-byte |
| **Selects 1920x1080 at 240 fps on the device** | pass — measured 239.49 fps |
| **Sustained 240 fps capture** | pass — 45 s run, 0 dropped frames after the first |
| **Detector time per frame** | 1.73 ms median, budget 4.17 ms |
| **Real tennis ball tracked** | pass — 315 observation packets/s, 0 sequence gaps |
| **Status packet cadence** | 1.002 s, driven by the capture clock |
| Thermal state at 240 fps | nominal throughout, including a 45 s run |
| Python receiver parses a fake 240 Hz stream over a real socket | pass |
| **Phone-side 3D tracker** | fits real detections on the device and refuses a still ball; see [3D flight tracking](#3d-flight-tracking) |
| **Live thrown-ball intercept on the device** | **not observed** — no recording caught a real flight |

The packet path was exercised over Wi-Fi rather than the USB-C tunnel, so
`iproxy` itself is still untested end to end; the app is indifferent to how the
client arrives. See [Limitations](#limitations).

## Build and run

Prerequisites: Xcode 15.3 or newer (built and tested with Xcode 27.0), an iPhone
with iOS 17+, a developer team for signing, and a Lightning/USB-C cable.

The Xcode project is generated from [`project.yml`](project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is committed, so you can
open it directly. Regenerate after adding or removing source files:

```bash
cd ios/TennisCamera
xcodegen generate          # brew install xcodegen
open TennisCamera.xcodeproj
```

Select the **TennisCamera** target → *Signing & Capabilities* → pick your team.
The bundle identifier is the placeholder `com.tennisrobot.camera`; change it if
it collides with something in your account.

Command line:

```bash
cd ios/TennisCamera
xcodebuild -project TennisCamera.xcodeproj -scheme TennisCamera \
  -destination 'platform=iOS,name=<iPhone name>' build
```

The scheme's **Run** and **Test** actions use the **Release** configuration,
because this app exists to measure milliseconds and an unoptimised Debug build
of the detector is roughly ten times slower. Debug remains available for
stepping through the detector.

Run it from Xcode, grant camera access, and press **Start capture**.

### Installing without an Xcode account

`xcodebuild` needs an Apple ID signed into *Xcode → Settings → Accounts* to
create a profile. If that is not set up but a development identity and a team
wildcard profile already exist on the Mac, installing still works:

```bash
cd ios/TennisCamera
xcodebuild -project TennisCamera.xcodeproj -scheme TennisCamera \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/tc-device CODE_SIGNING_ALLOWED=NO build

APP=/tmp/tc-device/Build/Products/Release-iphoneos/TennisCamera.app
cp "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/<uuid>.mobileprovision" \
   "$APP/embedded.mobileprovision"
codesign --force --sign "Apple Development: <you>" --entitlements entitlements.plist "$APP"

xcrun devicectl device install  --device <id> "$APP"
xcrun devicectl device process launch --device <id> com.tennisrobot.camera
```

taking the entitlements from the profile itself
(`security cms -D -i <profile>` → `Entitlements`, with `application-identifier`
set to `<TEAM>.com.tennisrobot.camera`). `devicectl` works over Wi-Fi once the
device is paired, so no cable is involved after the first pairing.

The simulator has no camera, so there it only exercises layout and the error
path. Use the simulator for the unit tests.

## On-screen readout

| Field | Meaning |
|---|---|
| capture | capture rate measured from sample-buffer presentation timestamps over the last 240 frames |
| detector | median and p95 detector time over the last 240 frames, milliseconds |
| packets | packets sent per second over the last 480 packets |
| dropped | frames the capture system discarded because a frame was late |
| thermal | `ProcessInfo.thermalState`. At **critical** the session stops by itself |
| sequence | next sequence number |
| detections | total accepted detections since Start |
| latest u,v | most recent detection, full-frame pixels |
| client / listening | whether a TCP client is attached |
| format | selected dimensions, frame rate and whether the format is SDR |
| 3D flight | `tracking` once a fit passes the gates, with position, speed, the predicted intercept and its time, and the fit RMS |
| gravity | whether gravity came from CoreMotion (`measured`) or is the level assumption |

The toggles:

- **Ball detector** — runs the detector or not. Capture rate and dropped frames
  are still measured with the detector off, which separates a capture problem
  from a detector problem.
- **Strike-zone ROI** — scans the middle 70% x 60% instead of the whole frame.
  Coordinates stay full-frame; the ROI only limits the scan.

**Snapshot** grabs the current frame at capture resolution; **Save to Photos**
writes it to the library (needs add-only photo permission). See
[Calibration snapshot](#calibration-snapshot).

## The USB-C link

`iproxy` is the supported developer path. iOS does not expose a raw USB or
serial endpoint to third-party apps, and this app does not try to open one.

```bash
brew install libimobiledevice     # macOS; Windows uses libimobiledevice + Apple Mobile Device Service
iproxy 5000 5000
```

`iproxy LOCAL_PORT DEVICE_PORT` **listens on the host** and forwards into the
phone's port 5000. The app is the listener on the phone; on the host, the
tunnel is the listener. That means only one process can own host port 5000, so
the receiver must *connect* to it rather than bind it:

```bash
python3 tools/iproxy_receiver.py --connect              # through the tunnel
python3 tools/iproxy_receiver.py --listen --port 5000   # only if nothing else owns the port
```

Both modes in one step:

```bash
./tools/run_iphone_test.sh
```

That starts `iproxy`, connects the receiver, writes `runs/iphone_<timestamp>.jsonl`,
and kills the tunnel on exit. Override `PORT`, `DEVICE_PORT` or `JSONL` from the
environment.

The app itself does not care how the client arrives. It listens on TCP 5000 and
sends to whoever connected; `NSLocalNetworkUsageDescription` is present so an
Ethernet test later does not hit a surprise permission prompt.

Over Wi-Fi the tunnel is unnecessary: point the receiver at the phone directly.
This is how the device measurements below were taken, and it is the quickest
loop while bringing the hardware up.

```bash
dns-sd -G v4 <iPhone-name>.local        # or the phone's address, e.g. 192.168.1.2
python3 tools/iproxy_receiver.py --connect --host 192.168.1.2 --port 5000
```

Wi-Fi adds jitter and a real chance of dropped packets under load. For the robot
run, use the cable.

The tunnel can drop without the app noticing — the app keeps capturing and
accepts the next connection. The receiver reconnects in `--connect` mode.

## 3D flight tracking

[`Sources/FlightTracker.swift`](TennisCamera/Sources/FlightTracker.swift) turns the
2D detections into a 3D flight and predicts where it crosses a plane in front of
the camera. It is a re-expression of
[`../src/tennisrobot/estimator.py`](../src/tennisrobot/estimator.py) with the
frame changed from world to camera, and it runs on its own queue: a fit never
spends time inside the 4.17 ms frame budget.

**Camera model.** `fx = (width/2) / tan(hFOV/2)` using the format's own
`videoFieldOfView`, not the marketing numbers. For this phone at 1920 wide that
is ~67° and `fx ≈ 1450 px`, which agrees with the 26 mm-equivalent spec (≈67°, the
same 1450 px) — so no calibration board is needed to get the *scale* right. A
checkerboard is still the only way to find the residual distortion and the true
principal point to sub-pixel accuracy.

**Depth comes from radius.** `z = fx * R / r` with `R = 33.5 mm`. At the 18 px
radius of a ball a couple of metres away, one pixel of radius error is **5.7 % of
the depth**, so depth is the weakest number the tracker produces and the reason
the fit keeps the radius in its residuals instead of trusting the back-projection.

**Gravity is measured, not assumed.** `CMDeviceMotion.gravity` is rotated from
device axes into the delivered image frame (`x` right, `y` down, `z` forward),
including the connection's rotation angle. Over a 0.2 s window the fall is only
centimetres, which is small enough to look like noise and large enough to bias a
fit — so it is not fitted, it is read from the accelerometer.

**The fit.** Six parameters (position and velocity at the newest detection) are
solved by Gauss-Newton with Levenberg damping against three residuals per
observation: pixel centre and projected radius, weighted by 0.7 px and 1.0 px.
The trajectory is integrated with RK4 through the actual observation times with
the same drag model the PC uses (`Cd 0.507`, `rho 1.225`, `m 57.5 g`, `R 33.5 mm`,
no spin or wind). The state is carried backwards from the newest sample, so the
parameters are always "where the ball is now", and the next fit starts from the
previous one propagated forward.

**What it refuses.** These gates exist because each one was a real failure:

| Gate | Value | Why |
|---|---|---|
| observation span | ≥ 0.18 s (~43 samples) | at 42 ms and 0.5 px of noise the fit predicted a crossing **2.5 m** from the truth while passing every other check |
| centre RMS | ≤ 3.0 px | real flights fit at 0.7–0.9 px; a held ball cannot follow a ballistic path and lands near 6 px |
| speed | 3–45 m/s | a ball on a string is not a flight |
| depth | 0.3–10 m | outside that, radius-derived depth is meaningless |
| association | ≤ 80 px and radius ratio 0.5–2.0 | keeps the track on one blob frame to frame |
| track start | a candidate must have moved 1.5–80 px since the previous frame | a bright static object would otherwise own the track from the first frame |

**Prediction.** The fitted state is integrated forward at 1 ms until it crosses
`z = 1.0 m` (configurable), and the crossing point, time and residual are
published. In court coordinates that plane is wherever the phone happens to
point: the phone does not know where the court is, so the PC still has to apply
the camera pose.

### Measured accuracy

Simulated flights with noise of 0.5 px on the centre and 0.6 px on the radius —
about what the detector produces — checking the prediction against the truth it
was generated from:

| Prediction horizon | Position error | Intercept point error | Intercept time error |
|---|---:|---:|---:|
| 267 ms before the plane | 48 mm | **6.0 mm** | 1.8 ms |
| 233 ms | 38 mm | 8.1 mm | 1.2 ms |
| 196 ms | 31 mm | 7.5 mm | 4.4 ms |
| 146 ms | 11 mm | 3.5 mm | 1.3 ms |

A slower loft (6.3 m/s) gives 3–28 mm at 0.15–0.20 s, and the noiseless case is
exact to well under a millimetre. The pattern is the one to expect from a
monocular fit: the *current* position carries the depth bias, while the crossing
time and lateral point stay tight because they depend on where the ball is going
rather than how far away it is right now.

### On the device

At the time of writing the tracker runs on the iPhone, fits the live detector
output, and correctly refuses a ball that is not moving:

```
TennisCamera tracker: speed 0.2 m/s outside 3.0..45.0
TennisCamera tracker: rms 20.9 px > 3.0 (43 obs, span 0.18 s)
```

Those lines are the diagnostic channel (two per second at most). **No recording
captured a thrown ball**, so a live 3D intercept has not been demonstrated —
see [Limitations](#limitations). The obvious test is a ball dropped from about a
metre in front of the camera: it reaches 4 m/s in 0.2 s.

## Packet format

Fixed 40 bytes, little-endian, no JSON, no framing beyond the record itself.
Python: `struct.Struct("<I B B H I Q f f f f H H")`.

| offset | size | field | notes |
|---:|---:|---|---|
| 0 | 4 | `magic` | `0x424F5254`, the bytes `TROB` |
| 4 | 1 | `version` | 1 |
| 5 | 1 | `kind` | 0 observation, 1 status, 2 flight state, 3 intercept |
| 6 | 2 | `header_size` | 40 |
| 8 | 4 | `sequence` | increments per packet, wrapping |
| 12 | 8 | `t_capture_ns` | sample-buffer presentation timestamp, nanoseconds |
| 20 | 4 | `u` | float32, full-frame pixels |
| 24 | 4 | `v` | float32, full-frame pixels |
| 28 | 4 | `radius` | float32, full-frame pixels, `sqrt(area/pi)` |
| 32 | 4 | `confidence` | float32, 0..1 |
| 36 | 2 | `width` | frame width |
| 38 | 2 | `height` | frame height |

`sequence` counts **every** packet, observations and status alike, so a receiver
can see any gap.

### Status packets

Once per second, kind 1, same layout with different meanings. The tick is
driven by the capture clock, not the UI timer, so the cadence is 1.00 s of
capture time however busy the main thread is (measured 1.002 s between
packets):

| field | meaning |
|---|---|
| `u` | measured capture fps |
| `v` | median detector time, ms |
| `radius` | cumulative dropped frames since Start |
| `confidence` | thermal state: 0 nominal, 1 fair, 2 serious, 3 critical |
| `width`/`height` | delivered frame size |

The test receiver prints them; the PC should ignore them.

### 3D packets

Kinds 2 and 3 keep the same 40-byte layout and repurpose the four float slots, so
a receiver written for kinds 0 and 1 keeps working and simply skips them. Both
are sent at the refit rate (60 Hz), not per frame, and both carry the capture
time of the newest observation in the fit.

| slot | kind 2 (state) | kind 3 (intercept) |
|---|---|---|
| `u`, `v`, `radius` | ball `x, y, z` in **metres, camera frame** | crossing `x, y, z` at the plane |
| `confidence` | centre residual RMS, px | time from `t_capture_ns` to the crossing, s |

The camera frame is `x` right, `y` down, `z` forward, origin at the optical
centre. Rotating that into court coordinates needs the camera pose, which the
phone does not know.

### Transport rules

- TCP only, `TCP_NODELAY` on, one client at a time. A new connection replaces
  the old one.
- `t_capture_ns` is the sample-buffer presentation timestamp, converted through
  `CMTimeConvertScale` so no `Double` seconds round-trip loses precision. It is
  **not** the callback time and not the wall clock at send.
- No detection in a frame means no packet for that frame. The receiver infers
  the frame rate from packet arrivals, so a lane with no ball shows as a low
  packet rate rather than an error.

## Detector

[`Sources/BallDetector.swift`](TennisCamera/Sources/BallDetector.swift) is a
re-expression of `ColorBlobDetector` in
[`../src/tennisrobot/vision.py`](../src/tennisrobot/vision.py) for a 4.17 ms
budget. It is not a port: OpenCV is unavailable on the phone, and per-pixel HSV
conversion of two megapixels does not fit.

Thresholds are the Python defaults and are configurable in one struct:

```text
hsv_lower = [25, 70, 70]      hsv_upper = [50, 255, 255]
min_area_px = 40              min_radius_px = 3        max_radius_px = 80
min_circularity = 0.55        max_candidates = 3        min_confidence = 0.25
```

How it fits the budget:

1. **Hue and saturation depend only on chroma.** For full-range BT.601, the
   channel differences are fixed by `Cb`/`Cr` alone, so hue and `max-min` are
   precomputed into a 64x64 lookup table. Per pixel the test is a table read
   plus integer comparisons, and it stays exact rather than approximating HSV.
2. **2x2 groups share one chroma sample**, so the decode and table read happen
   once per four pixels.
3. **Connectivity runs on a 16x16 cell grid** with union-find, while area,
   centroid and bounding box are accumulated at pixel resolution in the same
   pass. No morphology, no contour pass, no second sweep.

The one deliberate departure from Python is the shape test. Real circularity
needs contour tracing, which is most of the OpenCV cost. Instead `confidence`
is `min(bounding-box fill, bounding-box aspect ratio)`: a disc scores ~1.0, a
long yellow stripe scores near zero. It gates the same `min_circularity` value.
It is a coarser test than perimeter circularity and will accept a filled square
as a disc.

Measured accuracy on a synthetic 1080p frame with a radius-40 disc: centroid
within 0.1 px, radius +0.24 px. The small radius bias comes from 4:2:0 chroma
being averaged across the ball's edge, which lets partly-covered edge blocks
pass the saturation test; it is bounded by about one chroma pixel and is worth
knowing about because the estimator derives depth from radius.

### Coordinates and orientation

- `u`/`v` are **pixel indices in the full frame**, pixel (0,0) top-left, `u`
  right and `v` down. This matches OpenCV and `PinholeCamera`'s `cx`/`cy`.
- The ROI is expressed in normalised full-frame coordinates and the offset is
  added back before the packet is built.
- The UI is locked to landscape and the connection is rotated to match the
  window scene: `videoRotationAngle` 0 for landscape-right, 180 for
  landscape-left. Which one you get depends on how the phone is held, so the
  calibration frame records it. If the saved snapshot is upside down, turn the
  phone 180 degrees.
- `videoStabilizationMode` is off, mirroring is off, HDR is avoided by selecting
  an sRGB format and setting `activeColorSpace = .sRGB`. The format line shows
  `HDR?` if no SDR 1080p format was found.
- Full-range 4:2:0 (`420f`) is required. If the capture system delivers anything
  else the app says so instead of silently detecting nothing.

## Calibration snapshot

The 240 fps mode may crop the sensor relative to 60 fps, and intrinsics do not
transfer across formats. Calibrate with frames captured at the runtime format:

1. Start capture at 1920x1080 240 fps.
2. Press **Snapshot**, then **Save to Photos**.
3. Repeat for 15–30 checkerboard poses covering the corners, at the same focus
   and zoom as the runtime run. Do not change focus afterwards.
4. Move the images to the PC and run
   [`../tools/calibrate.py`](../tools/calibrate.py) intrinsics with the board's
   measured square size, then pose, as in
   [`../docs/CALIBRATION.md`](../docs/CALIBRATION.md).

The snapshot is the full delivered frame, not a scaled preview.

## Measurements

**iPhone 16 (iPhone17,3), iOS 27.2, Release build, packets received over Wi-Fi.**
Indoor lighting, a tennis ball held 1–3 m from the phone.

| What | Value |
|---|---|
| Selected format | 1920x1080, sRGB, 240 fps supported range |
| Measured capture rate | **239.49 fps**, identical in every status packet over a 45 s run |
| Inter-frame interval (from `t_capture_ns`) | median 4.1756 ms, p95 4.1758 ms at 240 fps |
| Detector time | **1.73 ms** median across status samples, 1.64–1.95 ms range (the wire carries the median; p95 is on-screen only) |
| Frames with a detection (ball in view) | 233–240 per second |
| Observation packets | **315/s** (45 s run), 344/s (6 s run) |
| Dropped frames (`alwaysDiscardsLateVideoFrames`) | 0 after warm-up; 1 over a 45 s run |
| Thermal state | nominal for every packet, including a 45 s run |
| Status cadence | 1.002 s, min and max identical |
| Sequence gaps / parse errors | 0 / 0 |
| Failed connection recovery | app kept capturing; three successive receiver sessions connected mid-run |

Packet rate exceeds frame rate because up to `max_candidates` (3) packets are
sent per frame. A second, smaller yellow region in the corner of the test scene
produced genuine extra candidates — the PC gates by geometry, so this is the
intended behaviour, not a fault.

Superseded measurements, kept because they bound the detector without a camera
competing for the cores:

| What | Where | Value |
|---|---|---|
| Detector, 1920x1080 full frame, median | MacBook (Apple silicon), `swiftc -O` | 0.35 ms (p95 0.45) |
| Detector, warm background (more pixels pass hue) | MacBook, `swiftc -O` | 0.97 ms |
| Detector, same frame | iPhone 16 simulator, Release | 1.4–2.9 ms |
| Synthetic disc centroid / radius | simulator test | 899.93, 519.93 / 40.24 px for truth 900, 520 / 40 |
| Packet encode vs Python `struct` | simulator test | byte-identical |

Detection coverage is scene dependent, not pipeline dependent: in a later run
where the ball had drifted out of frame and only the corner blob remained, the
frame rate stayed at 239.5 fps with zero drops, but detections fell to 177/s and
observation packets to 245/s. A ball the detector cannot see produces no
packets, which is why the receiver's packet rate is the honest end-to-end
number and the capture rate is not.

## Limitations

- **`iproxy` is untested.** The device run above went over Wi-Fi, straight to
  the phone's port 5000, so the USB-C tunnel and its port ownership rules are
  documented but not verified. The app cannot tell the difference; the tunnel is
  the part that differs.
- **One device, one scene.** 239.49 fps and 1.73 ms were measured on one iPhone
  16 in indoor light. Thermal headroom beyond 45 s, sunlight, and 120 fps
  fallback devices are unmeasured. A colder or hotter room will move the
  detector number.
- **No live 3D flight was captured.** The tracker is verified in simulation (clean,
half-pixel noise, a static decoy, a stationary ball, a too-short baseline) and on
the device it fits the live detector output, but no recording contained a thrown
ball, so a published intercept on real motion is unproven. The growth of that
risk is not subtle: at 42 ms of baseline the same code predicted metres wrong,
which is why the gates above exist.
- **The phone predicts in its own frame.** The intercept is the crossing of
  `z = 1.0 m` along the optical axis. A real strike plane is a plane in the court
  or arm frame; turning one into the other needs the camera pose from
  [`../docs/CALIBRATION.md`](../docs/CALIBRATION.md).
- **One track at a time.** Association follows the nearest moving candidate. Two
  balls in flight, or a decoy that also moves, will confuse it — the PC's
  `ObservationGate` has the same class of problem and more context to solve it.
- **Depth is the weak axis.** Radius sets depth, so the position error (tens of
  millimetres) is much larger than the intercept-point error (a few millimetres).
  Do not read the published position as a distance measurement.
- **Signing was done by hand.** `xcodebuild` could not provision because no
  Apple ID was signed into Xcode on the build Mac; the app was signed against an
  existing team wildcard profile. See [Installing without an Xcode
  account](#installing-without-an-xcode-account).
- **No live viewfinder.** Rendering the stream would compete with the capture
  path for the frame budget, so framing is checked with **Snapshot** instead.
  A preview can be added behind a toggle later.
- **4:2:0 chroma edge.** Ball radius is biased by roughly a pixel on the
  boundary because chroma is subsampled. Radius feeds the estimator's depth, so
  this is a systematic term worth watching in the fit residuals.
- **No clock synchronisation.** `t_capture_ns` is on the phone's clock. The
  receiver's `arrival - capture` figure is dominated by the offset between the
  two clocks and is reported, but must not be read as latency.
- **One client, no authentication.** Anyone who can reach port 5000 receives
  observations. Keep the cable or an isolated network; this is not a service to
  expose.
- **No compression and no reconnect protocol.** A dropped connection is
  detected by the reader seeing a short read; the app simply waits for the next
  client.
- **Shape test is not circularity.** See the detector section.
- **Status packets carry no frame counter** beyond `sequence`; dropped frames
  are cumulative since Start.

## What the Windows PC needs

If your checkout already has `src/tennisrobot/remote.py`, the PC half is
written: it decodes these packets and maps the phone clock onto the PC's. Its
wire contract was checked against this app in both directions — its decoder
accepts the exact bytes `ObservationPacketTests` pins, and its encoder
reproduces them. That file is outside this task's scope and may still be
changing.

Otherwise, the PC side is unchanged until you add a `RemoteObservationSource`:

1. Open a TCP connection to `127.0.0.1:<local iproxy port>` (or to the phone
   directly on a direct network) and read exactly 40 bytes at a time.
2. Validate magic, version, `header_size` and `kind`; drop everything that fails
   before it reaches the gate.
3. For `kind = 0`, build `BallObservation(time_s, u_px, v_px, radius_px,
   confidence)` from the packet. `time_s` needs a phone→PC clock mapping — the
   packet carries the phone clock, so estimate the offset (for example from the
   smallest observed `arrival - t_capture` over a window) and apply it, rather
   than assuming the clocks agree.
4. Feed the existing `ObservationGate` and estimator. Nothing about the detector
   contract changes: full-frame `u`/`v` and full-frame `radius` in pixels.
5. Ignore `kind = 1`, or log it as link health.
6. Do not assume every frame produces a packet; the estimator already handles a
   sparse observation stream.

Calibrate the PC's camera model against the phone's 1920x1080 240 fps format, not
against the old UVC camera.

## Files

```text
ios/TennisCamera/project.yml              XcodeGen definition (the project is generated)
ios/TennisCamera/TennisCamera.xcodeproj   generated, committed
ios/TennisCamera/Sources/
  TennisCameraApp.swift                   @main
  ContentView.swift                       status panel and controls
  CameraController.swift                  session, format selection, FrameProcessor
  BallDetector.swift                      YCbCr threshold + centroid detector
  ObservationPacket.swift                 40-byte wire format
  ObservationServer.swift                 TCP listener, NODELAY, one client
  CaptureStats.swift                      lock-protected rolling counters
  Info.plist                              permissions, landscape lock
ios/TennisCamera/Tests/
  BallDetectorTests.swift                 synthetic disc, negatives, ROI, timing
  ObservationPacketTests.swift            byte-for-byte Python `struct` contract
  CapturePipelineTests.swift              CVPixelBuffer -> detector -> TCP socket
tools/iproxy_receiver.py                  dependency-free receiver (stdlib only)
tools/run_iphone_test.sh                  iproxy + receiver in one command
```

`src/`, `tests/` and `config/` are untouched.
