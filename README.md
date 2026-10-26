# 🎾 Tennis Buddy

A tennis racket that knows every shot you hit. Sensors hidden in the handle of a Yonex VCore 98 measure swing speed,
ball speed, spin, face angle and where the ball hit the strings. iPhone, Mac and Apple Watch apps turn it into
analytics, and an on-device **Gemma 4 E2B** model coaches you in plain language, fully offline.

Forked from [AahanPrajapati/Smart-Tennis-Racket](https://github.com/AahanPrajapati/Smart-Tennis-Racket) (MIT).
The original project streamed MPU6050 acceleration over Wi-Fi to a second ESP32 and lit a green/red LED for shot
intensity; its code is preserved in [`legacy/`](legacy/). Tennis Buddy builds out several of its "future
enhancements": a mobile app, stroke classification, impact force sensing and richer analytics.

## Repository layout

| Folder | Contents |
|---|---|
| [`firmware/`](firmware/) | PlatformIO project for the Seeed XIAO ESP32C3 (MPU6050 + H3LIS331DL, BLE streaming) |
| [`apple/`](apple/) | Xcode project: iPhone + Mac app, Watch app, shared `RacketKit` Swift package |
| [`hardware/`](hardware/) | CAD for the handle insert (STEP + Parasolid), wiring |
| [`tools/`](tools/) | Python analysis scripts, Gemma model download |
| [`data/`](data/) | Calibration recordings |
| [`docs/`](docs/) | [Plan](docs/PLAN.md), calibration guide, demo script |
| [`legacy/`](legacy/) | The original project's sketches and docs |

## Hardware

Seeed XIAO ESP32C3 · MPU6050 (±2000 °/s gyro) · Adafruit H3LIS331DL (±200 g) · INMP441 mic · 1S LiPo, all in a
3D-printed insert that replaces the handle's foam core. Pin map and BLE protocol: [docs/PLAN.md](docs/PLAN.md).

## License

MIT. See [LICENSE.md](LICENSE.md). Original work © 2025 Aahan Prajapati; Tennis Buddy additions © 2026 the Tennis Buddy team.
