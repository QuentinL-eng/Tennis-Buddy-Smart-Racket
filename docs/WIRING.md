# Wiring (as built)

XIAO ESP32C3, viewed from the component side with USB-C at the top.
Left header top→bottom: D0 D1 D2 D3 D4 D5 D6. Right header top→bottom: **5V GND 3V3 D10 D9 D8 D7**.

| XIAO pin | Connects to |
|---|---|
| GND | STEVAL-MKI251A GND (13) + SDO (22), INMP441 GND + L/R |
| 3V3 | STEVAL-MKI251A VDD (1) + VDDIO (2) + OCS (3) + CS (19), INMP441 VDD, SDA/SCL pull-ups (4.7 kΩ each) |
| D4 (GPIO6) | STEVAL-MKI251A SDA (21) |
| D5 (GPIO7) | STEVAL-MKI251A SCL (20) |
| D1 (GPIO3) | INMP441 SCK |
| D2 (GPIO4) | INMP441 WS |
| D3 (GPIO5) | INMP441 SD |
| — | INMP441 L/R → GND |
| BAT+/BAT− pads | Battery through the power button |

The IMU is an LSM6DSV320X (gyro + ±16 g + ±320 g accel) on ST's STEVAL-MKI251A adapter, replacing the earlier
MPU6050 + H3LIS331DL. CS high selects I2C; SDO low sets address 0x6A. **Do not use the 5V pin for the sensors.**
The firmware pin map in `firmware/src/main.cpp` and `firmware/src/mic.cpp` matches this table.

Check it: `cd firmware && pio run -e i2cscan -t upload`, then open the serial monitor. It should report
`0x6A(reg0F=0x73 ...)` on SDA=D4 (the scanner also lists other SCL pins for it; that is the ESP32 leaving the last SCL
pin attached, not a wiring fault). Then reflash the main firmware: `pio run -t upload`.

Mic check: `pio run -e micprobe -t upload`, then open the serial monitor. A connected INMP441 shows a changing level on
slot0 (`-> MIC DETECTED`) that jumps when you clap; slot1 stays 0 because L/R is tied to GND.
