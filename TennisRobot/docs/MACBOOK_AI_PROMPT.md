# MacBook AI task: iPhone 16 240 fps ball camera

You are working on a MacBook with Xcode and an iPhone 16. Build the iPhone-side
half of the TennisRobot vision pipeline described below. The iPhone runs the
detector; the Windows PC runs the 3D estimator, planner, safety monitor and Epson
arm client. Do not move those robot-side parts onto the phone.

If the `TennisRobot` repository is not already on this Mac, ask for it before
implementing. The reference files listed at the end are the source of truth for
the detector contract.

## Goal

A working iOS app named **TennisCamera** that:

1. Captures the back wide camera at **1920x1080, 240 fps** when the device
   supports it, falling back to 120 fps and reporting the fallback.
2. Detects a yellow/green tennis ball in a configurable ROI using a simple
   threshold-and-centroid detector, not OpenCV and not Python.
3. Sends one 40-byte observation packet per detection over a TCP socket.
4. Runs over the **USB-C cable** using Apple's `usbmuxd`/`iproxy` tunnel. The
   app listens; the Mac or PC runs `iproxy`. No Wi-Fi, Ethernet or Mac server is
   in the runtime path.
5. Shows capture rate, detector time, packet rate, dropped frames, selected
   format and thermal state in the app.
6. Includes a Python test receiver and a README so the Windows PC can integrate
   the same packets later.

The phone does **not** compute the 3D trajectory, intercept, racket pose or arm
command. It sends image-space observations only.

## Deliverables

Add these to the repository:

```text
ios/TennisCamera/                  Xcode project or XcodeGen project.yml + sources
ios/README.md                      build, run, permissions, iproxy, protocol, limits
tools/iproxy_receiver.py           dependency-free Python 3 test receiver
tools/run_iphone_test.sh           optional: start iproxy + receiver
```

Do not modify `src/`, `tests/` or `config/`. The iOS app and test harness are
additive.

Suggested source files:

```text
TennisCameraApp.swift
ContentView.swift
CameraController.swift
BallDetector.swift
ObservationPacket.swift
ObservationServer.swift
CaptureStats.swift
Info.plist
```

Use a placeholder bundle identifier such as `com.tennisrobot.camera`; the user
will select their development team in Xcode.

## Architecture

```text
iPhone 16
  AVCaptureSession 1080p240
        |
  AVCaptureVideoDataOutput (BGRA or 420YpCbCr8BiPlanarFullRange)
        |
  BallDetector (ROI threshold + centroid + radius)
        |
  ObservationServer (TCP listener on port 5000)
        |
  USB-C cable through usbmuxd
        |
PC or Mac: iproxy 5000 5000
        |
  tools/iproxy_receiver.py  (test)
  or the Windows PC's RemoteObservationSource (later)
```

The app must not assume it knows whether the client arrived over USB or
Ethernet. It simply listens on TCP port 5000 and sends packets to the connected
client. `iproxy` makes the USB-C connection look like a local TCP connection on
the host.

## iOS capture requirements

- Request camera permission with `NSCameraUsageDescription`.
- Select the back wide-angle camera.
- Iterate `AVCaptureDevice.formats` and choose a format whose dimensions are
  1920x1080 and whose `videoSupportedFrameRateRanges` includes 240 fps.
- Set:

```swift
session.sessionPreset = .inputPriority
device.activeFormat = selectedFormat
device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 240)
device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 240)
```

- If 240 fps is unavailable, choose 120 fps, then 60 fps, and clearly report the
  actual choice. Never silently run at 30 fps while claiming 240.
- Use `AVCaptureVideoDataOutput` with a dedicated serial queue.
- Set `alwaysDiscardsLateVideoFrames = true`; a late frame is worse than a
  dropped frame.
- Set `videoStabilizationMode = .off` on the connection.
- Disable HDR for the capture format; HDR processing adds latency and changes
  colour response.
- Lock the capture connection to landscape orientation and document which
  orientation the `u`/`v` coordinates use.
- Set `UIApplication.shared.isIdleTimerDisabled = true` while capturing.
- Show `ProcessInfo.processInfo.thermalState` and stop or warn at `.critical`.

For each `CMSampleBuffer`:

- Take `CMSampleBufferGetPresentationTimeStamp`; this is the capture time, not
  the callback time.
- Lock the pixel buffer and run the detector.
- Send one packet per accepted detection.
- Do not use `CVPixelBufferGetBaseAddress` after unlocking.

## Detector requirements

The detector must be fast enough for 240 fps. At 240 fps the budget is
**4.17 ms per frame**. That budget applies to capture + detection; the packet
send is tiny.

Recommended implementation:

- A configurable ROI rectangle in full-frame coordinates. Default to the full
  frame but expose a centred ROI around the expected strike zone.
- Threshold in HSV if practical, or in YUV using the Y and chroma planes. The
  Python reference uses OpenCV HSV, but the iPhone app does not need OpenCV.
- Default colour range from the Python configuration:

```text
hsv_lower = [25, 70, 70]
hsv_upper = [50, 255, 255]
min_area_px = 40
min_radius_px = 3
max_radius_px = 80
min_circularity = 0.55
max_candidates = 3
min_confidence = 0.25
```

- For speed, a threshold + connected/centroid scan in the ROI is enough. If
  connected components are too slow, compute the centroid and area of the
  largest yellow region using an integral image or a simple row/column scan.
- Compute:

```text
u_px, v_px      full-frame centroid, ROI offset added back
radius_px       sqrt(area / pi), in full-frame pixels
confidence      0..1 quality measure (fill/circularity); use a stable heuristic
```

- Clamp to `max_candidates`; prefer the largest/highest-confidence candidate.
- Do not run morphological open/close on every 1080p frame unless it fits the
  budget; if you use morphology, keep it small and leave it configurable.
- Add a unit test with a synthetic yellow circle: centroid within 1 px and radius
  within 1 px. Add a negative test with a gray/blue frame.

The detector must return full-frame coordinates even when it scans a ROI. The
PC's camera model expects full-frame `u`/`v` and a full-frame radius.

## Packet protocol

Little-endian. Fixed 40-byte packets. No JSON on the wire.

```text
offset  size  field
0       4     magic          UInt32 = 0x424F5254  (bytes "TROB")
4       1     version        UInt8  = 1
5       1     kind           UInt8  = 0 observation, 1 status
6       2     header_size    UInt16 = 40
8       4     sequence       UInt32, increments per packet
12      8     t_capture_ns   UInt64, sample-buffer presentation time in ns
20      4     u              Float32, full-frame pixels
24      4     v              Float32, full-frame pixels
28      4     radius         Float32, full-frame pixels
32      4     confidence     Float32, 0..1
36      2     width          UInt16, frame width
38      2     height         UInt16, frame height
```

Python struct format:

```python
PACKET = struct.Struct("<I B B H I Q f f f f H H")  # 40 bytes
```

Swift can build the same 40 bytes with `Data` and `withUnsafeBytes`; do not rely
on Swift struct padding.

Rules:

- `kind = 0` is an observation. Send one packet per candidate per frame. All
  candidates from one frame share `t_capture_ns`; `sequence` increments per
  packet.
- `kind = 1` is a status packet, sent once per second. Use the same layout:
  `u = measured_fps`, `v = median_detector_ms`, `radius = dropped_frames`,
  `confidence = thermal_state` (0 nominal, 1 fair, 2 serious, 3 critical),
  `width`/`height` = selected frame size. The receiver prints status; the PC
  ignores it.
- Use `t_capture_ns` from the sample buffer presentation timestamp. Do not use
  the wall clock at send time. The PC maps the iPhone clock to its own clock.
- TCP only. Set `TCP_NODELAY` on the listener/connection. One client at a time.
  If the client disconnects, keep capturing and wait for a new connection.
- No compression, no framing headers beyond the fixed 40 bytes. TCP preserves
  order; the receiver reads exactly 40 bytes at a time.

## USB-C / iproxy transport

The app listens on port 5000. On the host:

```bash
iproxy 5000 5000
```

Then the test receiver connects to `127.0.0.1:5000`; `iproxy` forwards that TCP
connection to the iPhone's port 5000 over the USB cable. No Ethernet adapter,
Wi-Fi or Mac server is involved.

On the Mac:

```bash
brew install libimobiledevice
iproxy 5000 5000
```

On Windows, the equivalent is `libimobiledevice`/`iproxy` plus Apple Mobile
Device Service. The Windows PC integration will use the same port and packet
format.

Add `NSLocalNetworkUsageDescription` to `Info.plist` even though the USB tunnel
may use loopback; the listener should work without a local-network prompt, but
the key avoids surprises if the app is later tested over Ethernet.

Do not attempt to open a raw USB endpoint, serial port or UVC device from the
iOS app. iOS does not expose one to third-party apps; `usbmuxd`/`iproxy` is the
supported developer path.

## Test receiver

`tools/iproxy_receiver.py` must run with only the Python standard library:

```bash
python3 tools/iproxy_receiver.py --port 5000
```

It should:

- Listen on `127.0.0.1:5000`.
- Accept one client, read exactly 40-byte packets, validate magic/version/kind.
- Print observation rate, interval median/p95, sequence gaps, latest
  `u/v/radius/confidence`, frame size and status packets.
- Print `arrival_ns - t_capture_ns` minimum/median/p95, labelled as
  clock-offset-contaminated; it is not absolute latency unless a clock sync is
  added.
- Optionally write JSONL with `--jsonl PATH`.
- Exit cleanly on Ctrl-C.

Optional: implement a small ping/pong clock sync if it is easy; do not block the
first milestone on absolute latency. The app's status packet and the receiver's
packet interval are enough to prove the transport.

## Build and test procedure

1. Create the Xcode project and sources.
2. Build for the iPhone 16:

```bash
xcodebuild -project ios/TennisCamera/TennisCamera.xcodeproj \
  -scheme TennisCamera \
  -destination 'platform=iOS,name=<iPhone name>' build
```

   Or open the project in Xcode and run it on the device. The simulator cannot
   capture 240 fps; use it only for unit tests and layout.

3. On the Mac, start the tunnel and receiver in separate terminals:

```bash
iproxy 5000 5000
python3 tools/iproxy_receiver.py --port 5000
```

4. Launch the app, confirm the selected format and measured capture rate.
5. Point the camera at a yellow tennis ball at 1–3 m in normal room light. Hold
   it still, then move it slowly across the ROI.
6. Record:
   - selected format and actual measured capture fps;
   - median/p95 detector time;
   - observation packets per second;
   - status packet values;
   - any dropped frames or thermal warnings;
   - a short receiver log.

If no physical tennis ball is available, run the synthetic detector unit tests
and say clearly that the real-ball test was not performed. Do not claim a
real-ball result you did not observe.

## Acceptance criteria

The task is complete when:

- The app builds and runs on the iPhone 16 (or the exact blocker is reported).
- It selects 1920x1080 at 240 fps, or reports the highest supported rate.
- The app's status shows at least **200 fps** measured capture for a 5-second
  run, with the detector enabled, or the actual shortfall is explained.
- Median detector time is reported; target is **<= 4 ms** per frame. If it is
  higher, report the measurement, not an estimate.
- With a ball in view, the receiver sees at least **200 observation packets/s**
  over `iproxy` for a 5-second run, with no parse errors.
- The detector unit tests pass: synthetic yellow ball centroid/radius within
  1 px; gray/blue negative frame produces no detection.
- `ios/README.md` documents build, signing, `iproxy`, receiver, packet format,
  calibration snapshot and limitations.
- No robot motion, no Epson commands, no PC-side pipeline changes.

## Non-goals

- Do not implement the 3D flight estimator, intercept prediction, racket pose
  planning, safety monitor or Epson protocol on the phone.
- Do not build a Mac server that processes video. The Mac is the build host and
  test harness only.
- Do not use OpenCV, Python or a custom ML model on the iPhone for this first
  version.
- Do not use the App Store, cloud services or a raw USB endpoint.
- Do not modify the Python pipeline or the Windows PC code.

## Calibration snapshot

Add a button that saves the current full-resolution frame for calibration
(`NSPhotoLibraryAddUsageDescription` if saving to Photos, or a share sheet).
The Windows PC will use `tools/calibrate.py` on checkerboard images captured at
the same 240 fps format. The 240 fps mode may crop the sensor; calibration must
use the same format, focus and resolution as the runtime.

## Report back

When finished, report:

1. **Outcome** — app builds/runs, or the exact blocker.
2. **Files added** — list them.
3. **Device** — iPhone model, iOS version, Xcode version.
4. **Format** — selected dimensions and frame-rate range.
5. **Measurements** — measured capture fps, detector median/p95 ms, packet rate,
   dropped frames, thermal state.
6. **Test output** — receiver log excerpt and unit-test result.
7. **Limitations** — anything not tested (real ball, signing, Windows PC, etc.).
8. **Next step** — what the Windows PC needs to integrate the packets.

## Reference files

Read these before implementing; they define the existing contract:

- `src/tennisrobot/types.py` — `BallObservation(time_s, u_px, v_px, radius_px,
  confidence)`.
- `src/tennisrobot/vision.py` — `ColorBlobDetector` and `ObservationGate`; HSV
  defaults and candidate ordering.
- `config/camera_only.toml` — current HSV, radius and candidate settings.
- `docs/ARCHITECTURE.md` — where the iPhone detector fits in the pipeline.
- `docs/CALIBRATION.md` — checkerboard and camera-pose procedure.
- `docs/FEASIBILITY.md` — why 240 fps and the timing budget matter.

The phone is a sensor. The PC is the robot controller.
