# Tennis Buddy: Hackathon Plan

**Time:** 12:18 to 6:00 (about 5.5 hours). **Team:** CS (apps), EE (wiring + firmware), ME (hardware + calibration + data).
**Requirement:** fork an open-source project ([AahanPrajapati/Smart-Tennis-Racket](https://github.com/AahanPrajapati/Smart-Tennis-Racket), MIT) and add a **trick** and a **treat**.

- **Trick:** the racket itself. Sensors in the handle detect every shot and measure swing speed, ball speed, spin, face angle, swing path and where the ball hit the strings.
- **Treat:** the analytics. iPhone + Mac apps with identical features, an Apple Watch companion, and an on-device **Gemma 4 E2B** coach that explains your session in plain language (open-weights prize category).

How we extend the original project:

| Original "future enhancement" | Tennis Buddy |
|---|---|
| Mobile app for real-time graphs | iPhone, Mac and Watch apps |
| ML to classify strokes | Forehand / backhand / serve / volley detection |
| Force sensors for impact force | High-g accelerometer + impact physics |
| Wi-Fi to a second ESP32 | Bluetooth LE straight to the phone |
| Green/red LED for intensity | Green/red flash on the shot card + Watch haptics |

---

## 1. Hardware

| Part | Role | Settings |
|---|---|---|
| Seeed XIAO ESP32C3 | MCU + BLE (external U.FL antenna at the butt flange) | |
| MPU6050 (GY-521) | Gyro (orientation, rotation) + low-g accel | 1 kHz, ±2000 °/s, ±16 g, DLPF 188 Hz |
| Adafruit H3LIS331DL | High-g accel: swing (MPU6050 saturates at 16 g) + impact | 1 kHz, ±200 g |
| INMP441 | Impact sound (stretch, not in v1 firmware) | 16 kHz I2S |
| 1S LiPo + power button | Button cuts battery power, so **it only charges while switched ON** | |

Positions from the CAD file (measured from the outer face of the butt flange): XIAO 0–30 mm (USB-C at the butt face),
H3LIS331 center 18 mm, MPU6050 chip 39 mm, mic 55 mm (deep end, facing into the handle). The battery sits past the insert:
wrap it in foam so it can't rattle.

### Pin map (EE)

| XIAO pin | GPIO | Connects to |
|---|---|---|
| 3V3 | | VCC of MPU6050, H3LIS331 (VIN), INMP441 VDD |
| GND | | All grounds, INMP441 L/R |
| D4 | GPIO6 | SDA: MPU6050 SDA + H3LIS331 SDA |
| D5 | GPIO7 | SCL: MPU6050 SCL + H3LIS331 SCL |
| D0 / A0 | GPIO2 | Battery voltage: BAT+ → 220 kΩ → A0 → 220 kΩ → GND (optional) |
| D6 | GPIO21 | INMP441 SCK (stretch) |
| D7 | GPIO20 | INMP441 WS (stretch) |
| D10 | GPIO10 | INMP441 SD (stretch) |
| BAT+ / BAT− pads | | Battery through the power button |

I2C addresses: MPU6050 `0x68` (AD0 low), H3LIS331 `0x18` (Adafruit default). No interrupt pins needed.

---

## 2. Architecture

```
Racket (ESP32C3) ──BLE, raw 1 kHz──► iPhone or Mac app ──WatchConnectivity──► Apple Watch
                                       └─ RacketKit (shared Swift package):
                                          decode → orientation → shot detection → metrics → SwiftData
                                       └─ Gemma 4 E2B (MLX Swift, on device) → coach text
```

- **Firmware does no math.** It reads both IMUs at 1 kHz and streams raw samples. All analysis lives in Swift.
- **One device connects to the racket at a time** (iPhone at the court, Mac for the demo).
- **Simulated racket** in the app generates realistic swings and impacts, so the apps can be built and demoed without hardware.
- **Record/replay:** every session's raw data can be saved and replayed, so stats get tuned at a desk.

### BLE protocol (v1)

Service `7E5B0001-6B1D-4D8E-9C1A-7E5B7E5B0001`

| Characteristic | UUID suffix | Props | Payload |
|---|---|---|---|
| IMU stream | `...0002` | notify | Header + 8 samples (below) |
| Status | `...0003` | read, notify (every 2 s) | `u16 battery_mV, u8 fw_major, u8 fw_minor, u8 flags, u8 h3lis_range, u16 dropped` |
| Control | `...0004` | write | `0x01` start stream, `0x02` stop, `0x10 n` H3LIS range (0=100 g, 1=200 g, 3=400 g) |

IMU packet (little-endian, 152 bytes): `u16 seq, u32 t0_us, u8 count(=8), u8 flags`, then 8 samples of
`i16 ax, ay, az, gx, gy, gz` (MPU6050 raw) + `i16 hx, hy, hz` (H3LIS331 raw, 12-bit left-aligned).
Samples are 1 ms apart, starting at `t0_us`. Scales: MPU accel 2048 LSB/g, gyro 16.4 LSB/(°/s); H3LIS at ±200 g = 98 mg/digit after `>> 4`.

---

## 3. Stats (RacketKit)

| Stat | Method | Tier |
|---|---|---|
| Live 3D orientation | Mahony filter on gyro; accel correction only when near 1 g; yaw recenter button | Core |
| Shot detection | High-g impact spike (>8 g jump in < 3 ms) during a fast swing (gyro > 300 °/s) | Core |
| Shot type | Rotation direction about the vertical + face orientation, mirrored for handedness; serve = racket above head before contact | Core |
| Swing speed | Peak angular speed × effective radius (calibrated, default 1.1 m), checked against slow-mo | Core |
| Face angle, swing path | Racket orientation and velocity direction at contact | Core |
| Sweet spot + hit location | Side-to-side: roll-rate jump at impact. Tip vs throat: frame ringing energy (120–200 Hz) at the butt + handle jolt sign. Thresholds from the drop-grid calibration | Core |
| Ball speed | `v_ball ≈ e·v_in + (1+e)·V_racket`, e ≈ 0.4 at the sweet spot (less off-center), v_in ≈ 12 m/s assumed for groundstrokes, ≈ 0 for serves | Nice |
| Spin (rpm) | Racket velocity along the string face at contact → `rpm ≈ k·v_t / r_ball`, k fitted to slow-mo | Nice |
| Session: count, mix, heat map, consistency, fatigue trend | Aggregates over shots | Core / Nice |

Racket constants (edit after the ME measures): mass 325 g, length 686 mm, balance ~320 mm, string-bed center ~520 mm from the butt.

---

## 4. Apps (iPhone + Mac identical, one SwiftUI codebase)

Tabs (iPhone) / sidebar (Mac): **Live · History · Insights · Racket**, plus first-launch setup.

- **Live:** Start/Stop, live 3D racket, a shot card per hit (type, swing speed, ball speed, spin, impact dot) with a green/red edge flash, a running strip (shots, sweet spot %, average speed). Mac: full-screen presenter mode.
- **History:** sessions list → session summary (shot mix, averages per stroke, impact heat map filtered by stroke) → shot detail.
- **Insights:** trend charts across sessions, fatigue chart, **Coach** (Gemma summary + "Ask your stats" chat).
- **Racket:** connection, battery, sensor health, **Calibration mode** (hold still → tip up → lay flat → drop-grid with tap-to-label), recorder (raw record/replay, CSV export), simulated racket toggle.
- **Storage:** SwiftData, synced iPhone ↔ Mac with CloudKit (paid developer account).

### Watch (non-playing wrist)

- Start a tennis **workout** from the Watch → starts the racket session on the iPhone; heart rate + calories saved to Health.
- **Haptics per shot:** crisp tap = sweet spot, double buzz = mishit.
- **Last-shot glance:** speed, spin, impact dot.
- **Point logging** (Nice): tap Won / Lost after each point → "win % when first serve > X".
- **Drill mode** (Nice): Gemma picks a drill from your weak spots, the Watch counts it down.
- Later: wear the Watch on the hitting wrist for a wrist-lag metric.

### Gemma 4 E2B (on device, MLX Swift)

1. **Session coach** (Core): stats JSON → short report with 2–3 tips.
2. **Ask your stats** (Nice): chat; the app answers from computed stats passed into the prompt.
3. **Drill planner → Watch** (Nice).
4. **Voice journal** (Stretch): audio input.

Model weights are not in git; `tools/fetch_gemma.sh` downloads them. Pre-load them on the demo iPhone and Mac.
Fallback if MLX won't run in our iOS app: llama.cpp with a GGUF build.

---

## 5. Schedule

| Time | EE | ME | CS (+ Claude) |
|---|---|---|---|
| 12:30–1:15 | Wire on the bench per the pin map; flash `firmware/`; check serial output | Measurements; tape a 3×3 grid on the strings; foam-wrap the battery | Plan, firmware, Xcode project, simulated racket |
| 1:15–2:30 | Get BLE streaming to the app; fix dropouts | Install electronics in the handle; antenna flat against the flange | Live 3D racket on real data; recorder |
| 2:30–3:30 | Help collect data | Desk calibration, 45 grid drops (tap-to-label), shadow swings, all filmed at 240 fps | Shot detection, swing speed, shot type, sweet spot |
| 3:30–4:30 | Mic (stretch) or help ME | Hit into a blanket or at the wall; slow-mo for speed and spin checks | History, Insights, Watch, Gemma coach |
| 4:30–5:30 | Bug fixes | Accuracy slide: app numbers vs slow-mo | Polish, README, backup demo video |
| 5:30–6:00 | Everyone: rehearse the demo, submit | | |

## 6. Calibration (mostly indoors)

1. **Desk (2 min):** app-guided: hold still → tip up → lay flat face-up. Sets gyro bias and maps sensor axes to racket axes.
2. **Drop grid (15 min):** hold the racket face-up with a relaxed grip; drop a ball from ~1.5 m onto each of 9 squares, 5 times each. Tap the square in the app before each drop.
3. **Shadow swings (15 min):** forehands, backhands, serves; film from the side at 240 fps. The racket (686 mm) is the ruler for speed.
4. **Blanket/wall hits (20 min):** draw a line around the ball; rpm = 14,400 ÷ frames per full turn at 240 fps.

## 7. Demo script (3 min)

1. The problem + the forked project (10 s on what we started from).
2. Live: swing the racket → 3D racket moves on the Mac; hit a ball into a blanket → shot card with green flash, Watch taps.
3. Session summary + heat map; Gemma coach reads it out in plain language, fully offline.
4. Accuracy slide (app vs slow-mo). Backup: recorded session replay + video.
