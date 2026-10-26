// I2C bring-up helper: tries every free XIAO pin pair as SDA/SCL and reports which finds the sensors.
// Flash with: pio run -e i2cscan -t upload   (then reflash the main firmware with: pio run -t upload)
#include <Arduino.h>
#include <Wire.h>

static const int pins[] = {2, 3, 4, 5, 6, 7, 8, 9};   // D0-D3, D4, D5, D8, D9 (D6/D7/D10 = mic)
static const char *names[] = {"D0", "D1", "D2", "D3", "D4", "D5", "D8", "D9"};

void setup() {
  Serial.begin(115200);
  delay(1500);
}

void loop() {
  Serial.println("\n=== I2C scan (looking for MPU6050 0x68/0x69, H3LIS331 0x18/0x19) ===");
  bool any = false;
  for (int a = 0; a < 8; a++) {
    for (int b = 0; b < 8; b++) {
      if (a == b) continue;
      Wire.end();
      Wire.begin(pins[a], pins[b]);
      Wire.setClock(100000);
      String found;
      Wire.setTimeOut(5);
      for (uint8_t addr : {0x18, 0x19, 0x68, 0x69}) {
        Wire.beginTransmission(addr);
        if (Wire.endTransmission() == 0) found += String(" 0x") + String(addr, HEX);
      }
      Serial.printf(".");
      if (found.length()) {
        Serial.printf("SDA=%s SCL=%s ->%s\n", names[a], names[b], found.c_str());
        any = true;
      }
    }
  }
  if (!any) Serial.println("No I2C devices on any pin pair: check 3V3/GND to the sensor boards.");
  Wire.end();
  for (int p : pins) { pinMode(p, INPUT); }
  Serial.printf("Idle pin levels (1 = pulled up):");
  for (int i = 0; i < 8; i++) Serial.printf(" %s=%d", names[i], digitalRead(pins[i]));
  Serial.println();
  delay(3000);
}
