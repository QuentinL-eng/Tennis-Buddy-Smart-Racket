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
