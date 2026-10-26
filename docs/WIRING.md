# Wiring (as built)

XIAO ESP32C3, viewed from the component side with USB-C at the top.
Left header top→bottom: D0 D1 D2 D3 D4 D5 D6. Right header top→bottom: **5V GND 3V3 D10 D9 D8 D7**.

| XIAO pin | Connects to |
|---|---|
| GND | GND of MPU6050, H3LIS331, INMP441 (black) |
| 3V3 | VCC of MPU6050, VIN of H3LIS331, VDD of INMP441 (yellow) |
| D10 (GPIO10) | SCL of MPU6050 + H3LIS331 (green) |
| D9 (GPIO9) | SDA of MPU6050 + H3LIS331 (blue) |
| D0 (GPIO2) | INMP441 SCK |
| D1 (GPIO3) | INMP441 WS |
| D2 (GPIO4) | INMP441 SD |
| — | INMP441 L/R → GND |
| BAT+/BAT− pads | Battery through the power button |

**Do not use the 5V pin for the sensors.** The first wiring diagram shifted the right header by one pin, putting
sensor GND on 5V and VCC on GND (reversed power) and SCL on the 3V3 rail. Fix: move black 5V→GND, yellow GND→3V3,
green 3V3→D10, blue D10→D9. The firmware pin map in `firmware/src/main.cpp` and `firmware/src/mic.cpp` matches this table.

Check it: `cd firmware && pio run -e i2cscan -t upload`, then open the serial monitor. It should report the MPU6050
(0x68) and H3LIS331 (0x18) on SDA=D9 SCL=D10. Then reflash the main firmware: `pio run -t upload`.
