// Tap-capture probe: the sensor detects taps, the ESP32 only polls and buffers.
//
// The LSM6DSV320X's own tap engine watches the low-g accelerometer and latches TAP_SRC (0x46) with the axis
// and single/double flag. That is the primary trigger here: no per-sample work on the ESP32 at all, just one
// status read every POLL_US. The accelerometer itself runs in high-accuracy mode at 6.67 kHz and the read loop
// keeps a ring buffer, so when the poll reports a tap we already hold the samples from before it. The window
// dumped around each tap is what tools/collect_taps.py turns into training data for "where was it tapped".
//
// The INMP441 is kept as a secondary path for the bench: a tap has to be very close to (or on) the handle to
// reach its trigger, but tool_on_strings and sharp raps do show up, and the mic gives a second clock to
// compare against.
//
// Serial commands (single characters, echoed):
//   q  print the current configuration
//   m  cycle the mic trigger threshold (0 / 200 / 400 / 700): with 0 the mic path is off
//   s  report whether the on-chip tap engine has fired since boot
// `#` lines are status, printed once a second. Flashed with: pio run -e tapprobe -t upload
#include <Arduino.h>
#include <Wire.h>
#include <driver/i2s.h>

// ---- Pins (as built, see docs/WIRING.md) ----
static const int PIN_SDA = D4, PIN_SCL = D5;          // GPIO6/GPIO7
static const int PIN_SCK = 3, PIN_WS = 4, PIN_SD = 5; // INMP441 on D1/D2/D3

// ---- LSM6DSV320X ----
static const uint8_t LSM_ADDR = 0x6A, LSM_ID = 0x73;
static const uint8_t REG_WHO_AM_I = 0x0F, REG_CTRL1 = 0x10, REG_CTRL2 = 0x11, REG_CTRL3 = 0x12,
                     REG_CTRL6 = 0x15, REG_CTRL8 = 0x17, REG_OUTX_L_A = 0x28,
                     REG_HAODR_CFG = 0x62, REG_TAP_SRC = 0x46, REG_ALL_INT_SRC = 0x1D,
                     REG_TAP_CFG0 = 0x56, REG_TAP_CFG1 = 0x57, REG_TAP_CFG2 = 0x58,
                     REG_TAP_THS_6D = 0x59, REG_TAP_DUR = 0x5A, REG_WAKE_UP_THS = 0x5B;
static const float MG_PER_LSB_16G = 0.488f;   // ±16 g full scale

// Accel: high-accuracy ODR 6667 Hz (op_mode 001 + odr 1100, haodr_sel 10).
static const uint8_t CTRL1_HA_6667HZ = 0x1C, HAODR_SEL_6667HZ = 0x02;
// Accel: high-performance 1920 Hz (op_mode 000 + odr 1010) - the mode the production firmware uses.
static const uint8_t CTRL1_HP_1920HZ = 0x0A;
// Gyro 960 Hz high-performance: for gating taps during swings and for the raw stream.
static const uint8_t CTRL2_GYRO_960HZ_HP = 0x09;

// ---- Tap engine ----
// Thresholds are tap_ths x FS/32; at ±16 g that is 0.5 g per step.
static const uint8_t TAP_THS_X = 1, TAP_THS_Y = 1, TAP_THS_Z = 1;   // 0.5 g
// TAP_DUR: shock (2b, bits 7:6), quiet (2b, bits 5:4), dur (4b, bits 3:0 = double-tap gap).
// shock/quiet scale with the ODR and must cover the whole contact, so keep them generous.
static const uint8_t TAP_DUR_VALUE = (2 << 6) | (2 << 4) | 15;
// TAP_CFG0: lir(0) + tap_z_en + tap_y_en + tap_x_en.
static const uint8_t TAP_CFG0_VALUE = 0x38;
// WAKE_UP_THS bit7 = single/double tap (1 = double tap only).
static const uint8_t WAKE_UP_THS_VALUE = 0x00;   // single tap + wake-up

// ---- Capture geometry ----
static const int RING = 512;            // ~89 ms of history at 5.7 kHz: a long baseline for both triggers
static const int PRE_SAMPLES = 160;     // the window keeps this much before the trigger
static const int POST_SAMPLES = 160;    // ... and this much after it
static const int WIN_SAMPLES = PRE_SAMPLES + POST_SAMPLES;
static const int MIC_SAMPLES = 384;     // ~24 ms at 16 kHz, starting 4 ms before the trigger
static const uint32_t POLL_US = 5000;   // on-chip tap status poll: worst case 5 ms of latency
static const uint32_t REFRACTORY_MS = 200;
static const uint32_t STARTUP_MS = 1500;
// On-chip trigger: a tap jolt is a fast swing well above the noise. 300 mg above a slow baseline is
// tight enough for a light tap and loose enough that handling or a table bump does not trip it.
static const float JOLT_TRIGGER_MG = 300.0f;

struct Smp {
  uint32_t t;      // micros() at the read
  int16_t a[3];    // mg (low-g, ±16 g)
};

static Smp ring[RING];
static volatile int w = 0;
static uint32_t seqNo = 0;
static volatile bool dumpPending = false;
static volatile bool clipReady = false;
static volatile int capturing = -1;
static volatile bool tapSeen = false;
static volatile bool accelHiRate = true;   // true = 6.67 kHz high accuracy, false = 1.92 kHz high performance
static bool imuOk = false;
static volatile float liveDev = 0;          // peak |a| - baseline since the last status line, mg
static volatile float liveMag = 0, liveBase = 0;   // live |a| and its baseline, mg
static volatile uint8_t tapLastSrc = 0;
static volatile uint8_t intLastSrc = 0;
static int16_t micClip[MIC_SAMPLES];
static uint32_t micTrigT = 0;
static uint32_t lastCapture = 0;
static volatile bool captureFromAccel = false;
static volatile int micFloor = 0;
static volatile int micTrigMin = 250;
static float micFloorF = 200;
static uint32_t acqCount = 0, dumpCount = 0, tapEventCount = 0;
static volatile uint32_t lastCaptureUs = 0;

// ---- I2C ----
static bool writeReg(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(LSM_ADDR);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

static uint8_t readReg(uint8_t reg) {
  Wire.beginTransmission(LSM_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return 0;
  if (Wire.requestFrom(LSM_ADDR, (uint8_t)1) != 1) return 0;
  return Wire.read();
}

static bool setupIMU() {
  uint8_t who = readReg(REG_WHO_AM_I);
  Serial.printf("WHO_AM_I = 0x%02X (expect 0x%02X)\n", who, LSM_ID);
  if (who != LSM_ID) return false;
  bool ok = writeReg(REG_CTRL3, 0x01);              // software reset
  delay(10);
  ok &= writeReg(REG_CTRL3, 0x44);                  // BDU + auto-increment
  ok &= writeReg(REG_CTRL8, 0x03);                  // accel ±16 g
  ok &= writeReg(REG_CTRL6, 0x04);                  // gyro ±2000 dps
  ok &= writeReg(REG_CTRL2, CTRL2_GYRO_960HZ_HP);   // gyro 960 Hz
  // Tap engine.
  if (!accelHiRate) writeReg(REG_HAODR_CFG, HAODR_SEL_6667HZ);
  ok &= writeReg(REG_CTRL1, accelHiRate ? CTRL1_HA_6667HZ : CTRL1_HP_1920HZ);
  delay(20);   // let the XL chain settle before the tap engine is armed
  ok &= writeReg(REG_TAP_CFG1, TAP_THS_X & 0x1F);
  ok &= writeReg(REG_TAP_CFG2, TAP_THS_Y & 0x1F);
  ok &= writeReg(REG_TAP_THS_6D, (TAP_THS_Z & 0x1F) << 3);
  ok &= writeReg(REG_TAP_DUR, TAP_DUR_VALUE);
  ok &= writeReg(REG_WAKE_UP_THS, WAKE_UP_THS_VALUE);
  ok &= writeReg(REG_TAP_CFG0, TAP_CFG0_VALUE);
  Serial.printf("tap engine: ths %u/%u/%u (%.2f g), CTRL1 0x%02X -> 0x%02X, TAP_CFG0 0x%02X -> 0x%02X, "
                "TAP_CFG1 0x%02X, TAP_THS_6D 0x%02X, TAP_DUR 0x%02X -> 0x%02X, ALL_INT 0x%02X\n",
                TAP_THS_X, TAP_THS_Y, TAP_THS_Z, TAP_THS_X * 0.5f, accelHiRate ? CTRL1_HA_6667HZ : CTRL1_HP_1920HZ,
                readReg(REG_CTRL1), TAP_CFG0_VALUE, readReg(REG_TAP_CFG0), readReg(REG_TAP_CFG1),
                readReg(REG_TAP_THS_6D), TAP_DUR_VALUE, readReg(REG_TAP_DUR), readReg(REG_ALL_INT_SRC));
  return ok;
}

static bool readAccel(Smp &s) {
  uint8_t b[6];
  Wire.beginTransmission(LSM_ADDR);
  Wire.write(REG_OUTX_L_A);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(LSM_ADDR, (uint8_t)6) != 6) return false;
  for (int i = 0; i < 6; i++) b[i] = Wire.read();
  for (int i = 0; i < 3; i++) s.a[i] = (int16_t)lroundf((int16_t)(b[i * 2] | (b[i * 2 + 1] << 8)) * MG_PER_LSB_16G);
  return true;
}

static void put16(char *&p, int16_t v) {
  static const char digits[] = "0123456789abcdef";
  uint16_t u = (uint16_t)v;
  *p++ = digits[(u >> 12) & 0xF];
  *p++ = digits[(u >> 8) & 0xF];
  *p++ = digits[(u >> 4) & 0xF];
  *p++ = digits[u & 0xF];
}

static int micPeak() {
  int peak = 0;
  for (int i = 0; i < MIC_SAMPLES; i++) peak = max(peak, abs((int)micClip[i]));
  return peak;
}

// One capture. The window is centred PRE_SAMPLES before the tap-event sample.
static void dumpCapture(uint8_t tapSrc, uint8_t intSrc, uint32_t pollLag) {
  // Same clock, but a jolt needs no mic wait: record which trigger asked for this capture.
  Serial.printf("PT %lu tap_src 0x%02X int_src 0x%02X poll_lag %lu from %s\n", (unsigned long)seqNo, tapSrc,
                intSrc, (unsigned long)pollLag, captureFromAccel ? "accel" : "mic");
  seqNo++;
  const int perLine = 16;
  char line[perLine * 12 + 4];
  uint32_t t0 = 0, tlast = 0;
  for (int base = 0; base < WIN_SAMPLES; base += perLine) {
    char *p = line;
    *p++ = 'I';
    *p++ = ' ';
    for (int i = base; i < base + perLine && i < WIN_SAMPLES; i++) {
      const Smp &s = ring[(w + RING - PRE_SAMPLES + i) % RING];
      if (base == 0 && i == 0) t0 = s.t;
      tlast = s.t;
      put16(p, s.a[0]);
      put16(p, s.a[1]);
      put16(p, s.a[2]);
    }
    *p = 0;
    Serial.println(line);
  }
  for (int base = 0; base < MIC_SAMPLES; base += 64) {
    char *p = line;
    *p++ = 'M';
    *p++ = ' ';
    for (int i = base; i < base + 64 && i < MIC_SAMPLES; i++) put16(p, micClip[i]);
    *p = 0;
    Serial.println(line);
  }
  uint32_t dt = WIN_SAMPLES > 1 ? (tlast - t0) / (WIN_SAMPLES - 1) : 175;
  Serial.printf("T0 %lu %d %lu %lu\n", (unsigned long)t0, WIN_SAMPLES, (unsigned long)dt,
                (unsigned long)micTrigT);
  Serial.printf("CAP %lu mic_peak %d\n", (unsigned long)seqNo, micPeak());
  captureFromAccel = false;
  micTrigT = 0;
}

// ---- Acquisition: read accel flat out, watch for a jolt, poll the on-chip tap engine ----
static void acqTask(void *) {
  Smp s = {};
  uint32_t lastPoll = micros();
  uint32_t startedAt = micros();
  float slowMag = 1000;          // slow baseline of |a| in mg (gravity included)
  int postLeft = -1;             // samples still to take after a jolt
  for (;;) {
    if (dumpPending) {
      // Freeze here: stop sampling so the ring cannot be overwritten while the window is trimmed and
      // printed. (The mic task only needs to finish its clip when a mic trigger asked for this capture.)
      for (int i = 0; i < 400 && !clipReady; i++) vTaskDelay(1);
      uint8_t src = tapLastSrc, isrc = intLastSrc;
      uint32_t lag = micros() - lastPoll;
      dumpPending = false;
      clipReady = false;
      dumpCapture(src, isrc, lag);
      dumpCount++;
      continue;
    }
    if (readAccel(s)) {
      s.t = micros();
      ring[w] = s;
      w = (w + 1) % RING;
      acqCount++;
      float mag = sqrtf((float)s.a[0] * s.a[0] + (float)s.a[1] * s.a[1] + (float)s.a[2] * s.a[2]);
      float dev = mag - slowMag;
      if (fabsf(dev) > fabsf(liveDev)) liveDev = dev;   // peak-hold until the status line clears it
      liveMag = mag;
      liveBase = slowMag;
      slowMag += 0.004f * (mag - slowMag);   // ~44 ms time constant: taps pass, posture does not
      if (postLeft > 0 && --postLeft == 0) {
        postLeft = -1;
        clipReady = true;        // the accel path has nothing else to wait for
        dumpPending = true;
        continue;
      }
      if (postLeft < 0 && millis() - lastCapture > REFRACTORY_MS && millis() - startedAt > STARTUP_MS &&
          mag - slowMag > JOLT_TRIGGER_MG) {
        lastCaptureUs = micros();
        postLeft = POST_SAMPLES;   // keep sampling through the ring-down, then dump
        captureFromAccel = true;
      }
    }
    uint32_t now = micros();
    if (now - lastPoll >= POLL_US && now - startedAt > (uint32_t)RING * 200) {
      lastPoll = now;
      // A tap latches TAP_SRC until it is read, so one poll can afford to be late: the event is not lost.
      uint8_t tap = readReg(REG_TAP_SRC);
      if (tap & 0x20) {   // tap_ia: which axis, single or double
        tapSeen = true;
        tapLastSrc = tap;
        intLastSrc = readReg(REG_ALL_INT_SRC);
        tapEventCount++;
      }
    }
  }
}

// ---- Microphone: secondary trigger, and the clip that goes with each capture ----
static void micTask(void *) {
  static int16_t pre[64];
  static int32_t raw[64];
  int preHead = 0;
  uint32_t startedAt = millis();

  for (;;) {
    size_t bytes = 0;
    if (i2s_read(I2S_NUM_0, raw, sizeof(raw), &bytes, portMAX_DELAY) != ESP_OK) continue;
    int n = bytes / sizeof(int32_t);
    for (int k = 0; k < n; k++) {
      int16_t smp = (int16_t)(raw[k] >> 16);
      if (capturing >= 0) {
        micClip[capturing++] = smp;
        if (capturing == MIC_SAMPLES) {
          capturing = -1;
          lastCapture = millis();
          clipReady = true;
          if (!captureFromAccel) {   // the accel path freezes from its own side
            seqNo++;
            dumpPending = true;
          }
        }
        continue;
      }
      bool refractory = millis() - lastCapture < REFRACTORY_MS || millis() - startedAt < STARTUP_MS;
      float thresh = max((float)micTrigMin, 6.0f * micFloorF);
      if (micTrigMin > 0 && !refractory && abs((int)smp) > thresh) {
        for (int i = 0; i < 64; i++) pre[i] = pre[(preHead + i) % 64];
        memcpy(micClip, pre, sizeof(pre));
        micClip[64] = smp;
        capturing = 65;
        micTrigT = micros();
      } else {
        micFloorF += 0.001f * (abs((int)smp) - micFloorF);
        micFloor = (int)micFloorF;
      }
      pre[preHead] = smp;
      preHead = (preHead + 1) % 64;
    }
  }
}

bool micBegin() {
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX);
  cfg.sample_rate = 16000;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_ONLY_LEFT;
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
  cfg.dma_buf_count = 6;
  cfg.dma_buf_len = 64;
  i2s_pin_config_t pins = {};
  pins.mck_io_num = I2S_PIN_NO_CHANGE;
  pins.bck_io_num = PIN_SCK;
  pins.ws_io_num = PIN_WS;
  pins.data_out_num = I2S_PIN_NO_CHANGE;
  pins.data_in_num = PIN_SD;
  if (i2s_driver_install(I2S_NUM_0, &cfg, 0, nullptr) != ESP_OK) return false;
  return i2s_set_pin(I2S_NUM_0, &pins) == ESP_OK;
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n=== tapprobe: on-chip tap engine + 6.67 kHz ring + mic trigger ===");
  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(1000000);
  Wire.setTimeOut(50);
  for (int i = 0; i < 10 && !imuOk; i++) {
    imuOk = setupIMU();
    if (!imuOk) delay(100);
  }
  Serial.printf("IMU: %s\n", imuOk ? "OK" : "NOT FOUND");
  if (!micBegin()) Serial.println("mic: FAILED to start I2S");
  xTaskCreatePinnedToCore(micTask, "mic", 4096, nullptr, 4, nullptr, 0);
  xTaskCreatePinnedToCore(acqTask, "acq", 4096, nullptr, 6, nullptr, 1);
  Serial.printf("commands: q=config, m=cycle mic trigger, s=tap engine state, h=toggle accel rate\n");
}

void loop() {
  static uint32_t lastStatus = 0, lastAcq = 0, lastDump = 0;
  uint32_t now = millis();
  if (now - lastStatus >= 1000) {
    uint32_t dAcq = acqCount - lastAcq, dDump = dumpCount - lastDump;
    lastAcq = acqCount;
    lastDump = dumpCount;
    Serial.printf("# rate %.0f Hz | taps %lu/s | events %lu | total %lu | mic floor %d trig %d | "
                  "jolt dev %.0f mg (trig %.0f)\n",
                  dAcq * 1000.0f / (now - lastStatus), (unsigned long)dDump, (unsigned long)tapEventCount,
                  (unsigned long)acqCount, micFloor, (int)max((float)micTrigMin, 6.0f * micFloorF),
                  liveDev, JOLT_TRIGGER_MG, liveMag, liveBase);
    liveDev = 0;
    lastStatus = now;
  }
  while (Serial.available()) {
    int c = Serial.read();
    if (c == 'q') {
      Serial.printf("# config: tap ths %u (%.1f g) dur 0x%02X, poll %lu us, ring %d, win %d, mic trig %d, floor %d\n",
                    TAP_THS_X, TAP_THS_X * 0.5f, TAP_DUR_VALUE, (unsigned long)POLL_US, RING, WIN_SAMPLES,
                    micTrigMin, micFloor);
      Serial.printf("# regs: CTRL1 %02X CTRL2 %02X HAODR %02X TAP_CFG0 %02X TAP_CFG1 %02X TAP_CFG2 %02X "
                    "TAP_THS_6D %02X TAP_DUR %02X WAKE_UP_THS %02X ALL_INT %02X TAP_SRC %02X\n",
                    readReg(REG_CTRL1), readReg(REG_CTRL2), readReg(REG_HAODR_CFG), readReg(REG_TAP_CFG0),
                    readReg(REG_TAP_CFG1), readReg(REG_TAP_CFG2), readReg(REG_TAP_THS_6D),
                    readReg(REG_TAP_DUR), readReg(REG_WAKE_UP_THS), readReg(REG_ALL_INT_SRC),
                    readReg(REG_TAP_SRC));
    } else if (c == 'm') {
      micTrigMin = micTrigMin >= 700 ? 0 : micTrigMin + 150;
      Serial.printf("# mic trigger %d\n", micTrigMin);
    } else if (c == 's') {
      Serial.printf("# tap engine: %s, %lu events, TAP_SRC 0x%02X, ALL_INT 0x%02X\n",
                    tapSeen ? "HAS FIRED" : "never fired yet", (unsigned long)tapEventCount, tapLastSrc,
                    intLastSrc);
    } else if (c == 'h') {
      accelHiRate = !accelHiRate;
      tapSeen = false;
      tapEventCount = 0;
      imuOk = setupIMU();
      Serial.printf("# accel now %s (reconfigured %s), tap counter reset\n",
                    accelHiRate ? "6.67 kHz high-accuracy" : "1.92 kHz high-performance",
                    imuOk ? "OK" : "FAILED");
    }
  }
  delay(20);
}
