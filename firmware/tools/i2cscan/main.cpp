// I2C bring-up helper: tries every free XIAO pin pair as SDA/SCL, scans every address and reads the WHO_AM_I
// registers (0x0F on ST sensors, 0x75 on InvenSense) of whatever answers.
// Flash with: pio run -e i2cscan -t upload   (then reflash the main firmware with: pio run -t upload)
#include <Arduino.h>
#include <Wire.h>

static const int pins[] = {2, 6, 7, 21, 20, 8, 9, 10};   // D0, D4-D10 (D1-D3 = mic, see docs/WIRING.md)
static const char *names[] = {"D0", "D4", "D5", "D6", "D7", "D8", "D9", "D10"};

static int readReg(uint8_t addr, uint8_t reg) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return -1;
  if (Wire.requestFrom(addr, (uint8_t)1) != 1) return -1;
  return Wire.read();
}

void setup() {
  Serial.begin(115200);
  delay(1500);
}

void loop() {
  Serial.println("\n=== I2C scan: every pin pair, every address ===");
  bool any = false;
  for (int a = 0; a < 8; a++) {
    for (int b = 0; b < 8; b++) {
      if (a == b) continue;
      Wire.end();
      Wire.begin(pins[a], pins[b]);
      Wire.setClock(100000);
      Wire.setTimeOut(5);
      String found;
      for (uint8_t addr = 0x08; addr < 0x78; addr++) {
        Wire.beginTransmission(addr);
        if (Wire.endTransmission() != 0) continue;
        int st = readReg(addr, 0x0F), inv = readReg(addr, 0x75);
        char buf[48];
        snprintf(buf, sizeof(buf), " 0x%02X(reg0F=0x%02X reg75=0x%02X)", addr, st & 0xFF, inv & 0xFF);
        found += buf;
      }
      Serial.printf(".");
      if (found.length()) {
        Serial.printf("\nSDA=%s SCL=%s ->%s\n", names[a], names[b], found.c_str());
        any = true;
      }
    }
  }
  if (!any) Serial.println("\nNo I2C devices on any pin pair: check 3V3/GND and the SDA/SCL pull-ups.");
  Wire.end();
  for (int p : pins) { pinMode(p, INPUT); }
  Serial.printf("Idle pin levels (1 = pulled up):");
  for (int i = 0; i < 8; i++) Serial.printf(" %s=%d", names[i], digitalRead(pins[i]));
  Serial.println();
  delay(3000);
}
