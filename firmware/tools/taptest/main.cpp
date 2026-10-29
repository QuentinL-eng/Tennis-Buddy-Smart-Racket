// Minimal on-chip tap-engine check. Nothing else runs: no mic, no 6.67 kHz read loop, no BLE.
// Goal: does the LSM6DSV320X tap engine latch TAP_SRC at all on this board?
//
// Flash with: pio run -e taptest -t upload   (then reflash the racket: pio run -t upload)
//
// It boots at the stock full scale (±2 g, threshold 16/32 = 1.0 g) and high-performance 1.92 kHz, which is
// what ST's own examples use. 'w' bumps the full scale to ±16 g (rarely the problem, but rules it out),
// 'h' cycles the accelerometer ODR. Every change is confirmed by reading the register back.
#include <Arduino.h>
#include <Wire.h>

static const int PIN_SDA = D4, PIN_SCL = D5;
static const uint8_t ADDR = 0x6A;
static const uint8_t R_WHO = 0x0F, R_CTRL1 = 0x10, R_CTRL2 = 0x11, R_CTRL3 = 0x12, R_CTRL6 = 0x15,
                     R_CTRL8 = 0x17, R_TAP_SRC = 0x46, R_ALL_INT = 0x1D, R_TAP_CFG0 = 0x56,
                     R_TAP_CFG1 = 0x57, R_TAP_CFG2 = 0x58, R_TAP_THS_6D = 0x59, R_TAP_DUR = 0x5A;

static uint8_t fullScale = 0;    // 0 = ±2 g, 1 = ±4 g, 2 = ±8 g, 3 = ±16 g
static uint8_t odrIdx = 0;       // 0 = 1.92 kHz HP, 1 = 480 Hz HP, 2 = 6.67 kHz HA
static const uint8_t XL_FS[4] = {0x00, 0x01, 0x02, 0x03};
static const char *FS_NAME[4] = {"2g", "4g", "8g", "16g"};

static bool wReg(uint8_t r, uint8_t v) {
  Wire.beginTransmission(ADDR); Wire.write(r); Wire.write(v);
  return Wire.endTransmission() == 0;
}
static uint8_t rReg(uint8_t r) {
  Wire.beginTransmission(ADDR); Wire.write(r);
  if (Wire.endTransmission(false) != 0) return 0xFF;
  if (Wire.requestFrom(ADDR, (uint8_t)1) != 1) return 0xFF;
  return Wire.read();
}

static void config(bool fsChanged) {
  wReg(R_CTRL3, 0x01); delay(10);
  wReg(R_CTRL3, 0x44);
  wReg(R_CTRL8, XL_FS[fullScale]);          // accel full scale
  wReg(R_CTRL6, 0x04);                      // gyro ±2000 dps
  wReg(R_CTRL2, 0x09);                      // gyro 960 Hz high performance
  // Tap engine: all three axes, threshold 16 (= 1.0 g at ±2 g), generous timing windows.
  wReg(R_TAP_CFG1, 16);
  wReg(R_TAP_CFG2, 16);
  wReg(R_TAP_THS_6D, (uint8_t)(16 << 3));
  wReg(R_TAP_DUR, 0xAF);
  wReg(R_TAP_CFG0, 0x38);
  if (odrIdx == 2) {
    wReg(0x62, 0x02);                       // HAODR_CFG -> 6667 Hz
    wReg(R_CTRL1, 0x1C);                    // high-accuracy 6667 Hz
  } else {
    wReg(R_CTRL1, odrIdx == 0 ? 0x0A : 0x08);   // 1.92 kHz / 480 Hz, high performance
  }
  delay(30);
  Serial.printf("cfg: %s FS, odr %s | CTRL1=0x%02X CTRL8=0x%02X CFG0=0x%02X CFG1=0x%02X THS_6D=0x%02X "
                "TAP_DUR=0x%02X\n",
                FS_NAME[fullScale], odrIdx == 0 ? "1.92kHz HP" : odrIdx == 1 ? "480Hz HP" : "6.67kHz HA",
                rReg(R_CTRL1), rReg(R_CTRL8), rReg(R_TAP_CFG0), rReg(R_TAP_CFG1), rReg(R_TAP_THS_6D),
                rReg(R_TAP_DUR));
  if (fsChanged) Serial.println("  (full scale / ODR changed - tap threshold is in FS/32 steps)");
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n=== taptest: does the on-chip tap engine latch? ===");
  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(1000000);
  Wire.setTimeOut(50);
  uint8_t who = rReg(R_WHO);
  Serial.printf("WHO_AM_I = 0x%02X (expect 0x73)\n", who);
  config(false);
  Serial.println("commands: q=regs, w=next full scale, h=next ODR. Tap the handle; any latch prints TAP.");
}

void loop() {
  static uint32_t lastPoll = 0, count = 0;
  uint32_t now = micros();
  if (now - lastPoll >= 2000) {              // poll every 2 ms
    lastPoll = now;
    uint8_t src = rReg(R_TAP_SRC);
    if (src & 0x20) {                        // tap_ia
      count++;
      Serial.printf("TAP #%lu src=0x%02X  axis %c%c%c  %s  sign=%u  ALL_INT=0x%02X  t=%lu us\n",
                    (unsigned long)count, src, (src & 0x10) ? '-' : 'x', (src & 0x20) ? '-' : 'y',
                    (src & 0x40) ? '-' : 'z', (src & 0x40) ? "double" : "SINGLE",
                    (src >> 3) & 1, rReg(R_ALL_INT), (unsigned long)now);
    }
  }
  if (Serial.available()) {
    int c = Serial.read();
    if (c == 'w') { fullScale = (fullScale + 1) & 3; config(true); }
    else if (c == 'h') { odrIdx = (odrIdx + 1) % 3; config(true); }
    else if (c == 'q') {
      Serial.printf("q: CTRL1=0x%02X CTRL8=0x%02X(%s) CFG0=0x%02X CFG1=0x%02X CFG2=0x%02X THS_6D=0x%02X "
                    "TAP_DUR=0x%02X ALL_INT=0x%02X TAP_SRC=0x%02X taps=%lu\n",
                    rReg(R_CTRL1), rReg(R_CTRL8), FS_NAME[fullScale], rReg(R_TAP_CFG0), rReg(R_TAP_CFG1),
                    rReg(R_TAP_CFG2), rReg(R_TAP_THS_6D), rReg(R_TAP_DUR), rReg(R_ALL_INT),
                    rReg(R_TAP_SRC), (unsigned long)count);
    }
  }
  delay(1);
}
