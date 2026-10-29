# Tennis Buddy firmware (EE)

Seeed XIAO ESP32C3 + LSM6DSV320X (on an ST STEVAL-MKI251A adapter). Reads gyro, ±16 g and ±320 g accel at 1 kHz
and streams samples over BLE as
"Tennis Buddy". Pin map and protocol: [../docs/PLAN.md](../docs/PLAN.md).

The INMP441 mic feeds an on-device ML model that reports sweet spot / % off-centre for each hit (serial `SHOT …`
lines and BLE characteristic `…0005`). Docs: [../ml/README.md](../ml/README.md).

## Flash it

```bash
python3 -m pip install --user platformio   # once
cd firmware
~/Library/Python/3.13/bin/pio run -t upload
~/Library/Python/3.13/bin/pio device monitor
```

(If `pio` is on your PATH, just use `pio`.) If upload fails: hold **BOOT**, tap **RESET**, release BOOT, upload again.

## What you should see in the serial monitor (115200)

```
LSM6DSV320X WHO_AM_I = 0x73 (expect 0x73)
LSM6DSV320X: OK
INMP441 mic + sweet-spot model: OK
BLE: advertising as "Tennis Buddy"
rate 1000 Hz | a[g] -0.06 -0.01 -0.99 ... | high-g a[g] 0.0 0.0 -1.2 | mic floor 160 peak 470 trig 1500 hits 0 | ...
```

Checklist:
- **rate ≈ 1000 Hz.** Much lower means I2C trouble: shorten the wires, check pull-ups.
- **Lying flat and still:** one accel axis reads ≈ ±1.00 g; the gyro reads near 0.
- **high-g:** sent in the old H3LIS units, fixed at the ±400 g range since 1.6 (~0.2 g steps; the sensor reads
  ±320 g), so 1 g at rest shows as ≈ ±1.0–1.4 on one axis.
- **mic:** `floor` is the background level, `peak` the loudest sample in the last second; a hit fires when it beats `trig`.
- **NOT FOUND:** check SDA = D4, SCL = D5, 3V3, GND. The LSM6DSV320X must be at 0x6A (SDO to GND, CS to 3V3).
- **Power button** cuts the battery, so the battery only charges while switched ON.
- **Antenna:** plug the U.FL antenna in before testing range; without it, range is a few cm.

## Shots, windows and the backlog (firmware 1.6)

With an app that knows it (`TB_STREAM_IMPACTS_ACKED`, protocol in `include/protocol.h`), each hit goes out as:

1. `TBHit` the moment it is detected.
2. `TBShotSummary` (80 bytes): the whole shot, computed on the racket by `src/shot.cpp`, a port of the app's
   `ShotAnalyzer` that uses the calibration and profile the app sends (`TB_CMD_SHOT_CONFIG`). The app shows the shot
   from this alone.
3. The 448-sample window, as backlog: 56 `TBWindowChunkAcked` that the app acks (`TB_CMD_WINDOW_ACK`). Missing
   chunks are re-requested (`TB_CMD_WINDOW_RESEND`), and unacked windows go again after 5 s.

`src/backlog.cpp` holds up to 6 windows in RAM. When they are all taken (slow link), or no phone is connected and the
racket has been still for 3 s, windows are written to the unused `spiffs` partition (1.375 MB, 117 windows) and
sent oldest first once the link is free, across reboots. Erasing flash stalls the CPU for tens of ms, so it only
happens while the racket is idle; writes go one 256-byte page per loop pass. Once an app has asked for this mode,
the racket also captures windows with no phone connected (flag kept in NVS).

The status line ends with the backlog counters (`acked`, `resent`, flash `waiting` / `spilled` / `lost`), `shot max`
(µs per summary) and free heap.

Apps from before 1.6 still get plain impact mode: windows sent once, no summaries.

## Host tests

```bash
clang++ -std=c++17 -fsanitize=address,undefined -Iinclude -Isrc -o /tmp/backlog_test tools/backlog_test/backlog_test.cpp src/backlog.cpp && /tmp/backlog_test
```

`tools/backlog_test` runs the backlog against a fake flash that, like the real one, can only clear bits between
erases. The shot analyzer is checked against the Swift one by RacketKit's `ShotParityTests` (`swift test` in
`apple/RacketKit`), which builds `tools/shot_parity` itself.
