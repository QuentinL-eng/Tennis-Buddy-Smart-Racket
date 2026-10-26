# Tennis Buddy firmware (EE)

Seeed XIAO ESP32C3 + MPU6050 + H3LIS331DL. Reads both IMUs at 1 kHz and streams raw samples over BLE as
"Tennis Buddy". Pin map and protocol: [../docs/PLAN.md](../docs/PLAN.md).

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
MPU6050 WHO_AM_I = 0x68 ...
H3LIS331DL WHO_AM_I = 0x32 ...
MPU6050: OK   H3LIS331DL: OK
BLE: advertising as "Tennis Buddy"
rate 1000 Hz | MPU a[g]  0.00  0.00  1.00 ... | H3LIS a[g] 0.0 0.0 1.0 | BLE advertising ...
```

Checklist:
- **rate ≈ 1000 Hz.** Much lower means I2C trouble: shorten the wires, check pull-ups.
- **Lying flat and still:** one MPU accel axis reads ≈ ±1.00 g; the gyro reads near 0.
- **H3LIS:** at ±200 g, resolution is ~0.1 g, so 1 g at rest shows as ≈ ±1.0 on one axis.
- **NOT FOUND:** check SDA = D4, SCL = D5, 3V3, GND. The MPU6050 must be at 0x68 (AD0 low) and the H3LIS at 0x18.
- **Power button** cuts the battery, so the battery only charges while switched ON.
- **Antenna:** plug the U.FL antenna in before testing range; without it, range is a few cm.
