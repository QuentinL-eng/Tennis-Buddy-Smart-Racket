// Tennis Buddy racket firmware.
//
// Reads the LSM6DSV320X (gyro + low-g accel + high-g accel, on a STEVAL-MKI251A) at 1 kHz. In raw mode every
// sample is streamed over BLE; in impact mode (TB_CMD_STREAM_MODE) the racket detects hits itself (impact.cpp)
// and sends only the samples around each one, which the apps analyse. The sweet-spot model (mic.cpp) and
// handle-tap gestures (tap.cpp) run here in both modes. Wiring and protocol: docs/PLAN.md.
// The BLE format predates this IMU (MPU6050 + H3LIS331DL), so samples are converted to those units.
//
// Serial monitor (115200) prints a status line every second for bench bring-up.

#include <Arduino.h>
#include <Wire.h>
#include <NimBLEDevice.h>
#include "nimble/porting/nimble/include/os/os_mbuf.h"
#include "protocol.h"
#include "mic.h"
#include "tap.h"
#include "impact.h"
#include "shot.h"
#include "backlog.h"
#include <Preferences.h>
#include <esp_partition.h>

// ---- Pins (XIAO ESP32C3) ----
// As built (see docs/WIRING.md): IMU on D4/D5, mic on D1-D3.
static const int PIN_SDA = D4;   // GPIO6
static const int PIN_SCL = D5;   // GPIO7
static const int PIN_VBAT = -1;  // no battery divider fitted (A0/D0 is free)

// ---- LSM6DSV320X (ST driver lsm6dsv320x_reg.h) ----
static const uint8_t LSM_ADDR = 0x6A;   // SDO tied to GND
static const uint8_t LSM_ID = 0x73;
static const uint8_t LSM_WHO_AM_I = 0x0F, LSM_CTRL1 = 0x10, LSM_CTRL2 = 0x11, LSM_CTRL3 = 0x12,
                     LSM_CTRL6 = 0x15, LSM_CTRL8 = 0x17, LSM_OUTX_L_G = 0x22, LSM_OUTX_L_A_HG = 0x34,
                     LSM_CTRL1_XL_HG = 0x4E;
// Native scales at the full scales set in setupIMU().
static const float LSM_G_DPS_PER_LSB = 0.070f;    // ±2000 dps (0.140 at ±4000 dps)
static const float LSM_HG_MG_PER_LSB = 10.417f;   // ±320 g
// Wire units (protocol.h): gyro 16.4 LSB/dps; low-g accel 2048 LSB/g, which the LSM's ±16 g (0.488 mg/LSB)
// already matches; high-g as H3LIS counts << 4 at the app-selected range.
static const float WIRE_G_LSB_PER_DPS = 16.4f;
// At ±4000 dps the native LSB doubles and the wire LSB halves (8.2 LSB/dps, TB_FLAG_GYRO_4000), so
// native -> wire is the same factor in both ranges.
static const float LSM_TO_WIRE_GYRO = LSM_G_DPS_PER_LSB * WIRE_G_LSB_PER_DPS;
static const uint8_t CTRL1_ACCEL = 0x0A;               // accel high-performance, 1.92 kHz
static const uint8_t CTRL2_GYRO = 0x0A;                // gyro high-performance, 1.92 kHz
static const uint8_t CTRL6_GYRO_2000 = 0x04, CTRL6_GYRO_4000 = 0x05;

// ---- Handle taps (tap.cpp detects single jolts; the sampler groups them into gestures) ----
static const int32_t TAP_TRIG_MG = 400;          // jolt above the resting |a| that counts as a tap
static const int TAP_MAX_LEN = 25;               // samples (ms) a tap's jolt may last
static const uint32_t TAP_REFRACTORY_MS = 100;   // short enough for a quick double tap
static const uint32_t TAP_GAP_MS = 450;          // a tap this soon after the previous one joins its gesture
static const int32_t TAP_MAX_JOLT_MG = 12000;    // near the ±16 g rail: a ball impact, not a tap
static const float TAP_MAX_GYRO_DPS = 150.0f;    // rotation this fast means a swing is under way
static const uint32_t TAP_SWING_HOLD_MS = 300;   // ... and taps are ignored until it has been calm this long
static const int TAP_MAX_COUNT = 5;

struct TapEvent {
  TBTap tap;
  int32_t jolt_mg;      // strongest tap, for the serial log
  uint32_t detect_us;   // time tapPush() took on the completing sample
};

// ---- State ----
static bool imuOk = false;
static volatile bool streaming = true;   // stream whenever a client subscribes
// High-g goes on the wire as H3LIS 12-bit counts at ±400 g (195 mg/count), so the sensor's whole ±320 g fits.
// Fixed since 1.6: the coarser step is below the sensor's noise (~0.35 g at rest).
static const uint8_t h3Range = 3;        // 0 = 100 g, 1 = 200 g, 3 = 400 g
// ±4000 dps by default: fast swings pass 2000 dps, and every packet flags its units. TB_CMD_GYRO_RANGE can still
// select ±2000.
static volatile bool gyro4000Wanted = true;    // requested by the app (TB_CMD_GYRO_RANGE)
static volatile bool gyro4000 = true;          // what the IMU is set to; changed by the sampler between packets
static volatile uint32_t imuResets = 0;        // times the watchdog found the IMU had lost its settings
static volatile uint8_t streamMode = TB_STREAM_RAW;

// NimBLE buffers (of the 32 set in platformio.ini) kept free for the stack's own replies. Notifying until
// the pool is empty makes notify() fail silently and leaves nothing to answer the phone's requests.
static const int BLE_BUFFER_RESERVE = 6;
static uint32_t sentPackets = 0;

static volatile uint16_t droppedPackets = 0;
static volatile uint32_t samplesRead = 0, i2cErrors = 0;
static TBSample lastSample = {};

static QueueHandle_t packetQueue;
static NimBLEServer *server;
static NimBLECharacteristic *imuChar, *statusChar, *shotChar, *tapChar;
static QueueHandle_t shotQueue, tapQueue;
static NimBLECharacteristic *hitChar, *windowChar, *poseChar, *summaryChar;

// Impact mode: hits go out at once through hitQueue. The sampler captures each hit's window into a backlog slot
// (backlog.cpp), the shot task computes its summary (shot.cpp), and the loop sends the summary, then the window.
static QueueHandle_t hitQueue;
static volatile uint32_t impactStepMaxUs = 0, shotMaxUs = 0;
static TaskHandle_t shotTaskHandle;
// TB_STREAM_IMPACTS_ACKED: the app's calibration and profile, and its acks and resend requests (queued to the loop,
// which owns the backlog).
static portMUX_TYPE cfgMux = portMUX_INITIALIZER_UNLOCKED;
static ShotConfig shotConfig = {};
struct BacklogCmd {
  uint8_t cmd;
  uint16_t boot, seq;
  uint8_t n;
  uint8_t chunks[24];
};
static QueueHandle_t backlogCmdQueue;
static uint16_t bootId = 0;
// Once an app has used TB_STREAM_IMPACTS_ACKED, windows are captured even with no phone connected (kept in NVS).
static volatile bool backlogEnabled = false, backlogEnablePending = false;
static volatile int64_t unixAtBootMs = 0;      // from TB_CMD_SET_TIME; 0 = unknown
static volatile uint32_t lastActiveMs = 0;     // last swing or hit, for "idle" (flash erases wait for it)
static const uint32_t POSE_INTERVAL_MS = 33;
static volatile uint32_t tapGestures = 0, tapsRejected = 0;
static bool micOk = false;

// ---- I2C helpers ----
static bool writeReg(uint8_t addr, uint8_t reg, uint8_t val) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

static bool readRegs(uint8_t addr, uint8_t reg, uint8_t *buf, size_t len) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(addr, (uint8_t)len) != len) return false;
  for (size_t i = 0; i < len; i++) buf[i] = Wire.read();
  return true;
}

static uint8_t readReg(uint8_t addr, uint8_t reg) {
  uint8_t v = 0;
  readRegs(addr, reg, &v, 1);
  return v;
}

// ---- Sensor setup ----
static bool setupIMU(bool wideGyro) {
  uint8_t who = readReg(LSM_ADDR, LSM_WHO_AM_I);
  Serial.printf("LSM6DSV320X WHO_AM_I = 0x%02X (expect 0x%02X)\n", who, LSM_ID);
  if (who != LSM_ID) return false;
  bool ok = writeReg(LSM_ADDR, LSM_CTRL3, 0x01);        // software reset
  delay(10);
  ok &= writeReg(LSM_ADDR, LSM_CTRL3, 0x44);            // BDU + register auto-increment
  ok &= writeReg(LSM_ADDR, LSM_CTRL6, wideGyro ? CTRL6_GYRO_4000 : CTRL6_GYRO_2000);
  ok &= writeReg(LSM_ADDR, LSM_CTRL8, 0x03);            // accel ±16 g
  ok &= writeReg(LSM_ADDR, LSM_CTRL1, CTRL1_ACCEL);
  ok &= writeReg(LSM_ADDR, LSM_CTRL2, CTRL2_GYRO);
  ok &= writeReg(LSM_ADDR, LSM_CTRL1_XL_HG, 0xAC);      // high-g: output regs on, 1.92 kHz, ±320 g
  return ok;
}

// Changes the gyro full scale. ST's driver (lsm6dsv320x_gy_full_scale_set) powers the gyro down first: the
// full scale must only be changed in power-down. True once CTRL6 reads back the new range.
static bool setGyroRange(bool wide) {
  const uint8_t want = wide ? CTRL6_GYRO_4000 : CTRL6_GYRO_2000;
  bool ok = writeReg(LSM_ADDR, LSM_CTRL2, 0x00);
  ok &= writeReg(LSM_ADDR, LSM_CTRL6, want);
  ok &= writeReg(LSM_ADDR, LSM_CTRL2, CTRL2_GYRO);
  return ok && readReg(LSM_ADDR, LSM_CTRL6) == want;
}

static int16_t clamp16(float v) { return (int16_t)constrain(lroundf(v), -32768L, 32767L); }

// High-g sample (LSM LSBs) -> H3LIS 12-bit counts, left-aligned, at the range the app selected.
static int16_t toH3Wire(int16_t raw) {
  float mgPerCount = (h3Range == 0) ? 49.0f : (h3Range == 1) ? 98.0f : 195.0f;
  long counts = constrain(lroundf(raw * LSM_HG_MG_PER_LSB / mgPerCount), -2048L, 2047L);
  return (int16_t)(counts * 16);
}

// Runs once per sample on the low-g accel (raw ±16 g LSBs) and the fastest gyro axis. Single taps from
// tap.cpp are accepted only when the racket is calm, then grouped: the gesture is queued once no further tap
// has arrived for TAP_GAP_MS.
static void tapStep(const int16_t *a, float gyroDps, uint32_t t_us) {
  static uint32_t lastFastMs = 0, lastTapMs = 0;
  static uint8_t count = 0;
  static TapEvent ev = {};
  static uint16_t seq = 0;
  const uint32_t now = t_us / 1000;
  if (gyroDps > TAP_MAX_GYRO_DPS) lastFastMs = now;

  TapResult r;
  uint32_t t0 = micros();
  // LSM ±16 g: 0.488 mg/LSB = 61/125.
  if (tapPush(a[0] * 61 / 125, a[1] * 61 / 125, a[2] * 61 / 125, t_us, r)) {
    uint32_t dt = micros() - t0;
    if (now - lastFastMs < TAP_SWING_HOLD_MS || r.jolt_mg > TAP_MAX_JOLT_MG) {
      tapsRejected++;
    } else {
      if (count == 0 || r.jolt_mg > ev.jolt_mg) {
        ev.tap.strength = r.strength;
        ev.tap.zone = r.zone;
        ev.tap.confidence = r.confidence;
        float n = sqrtf((float)r.dir_mg[0] * r.dir_mg[0] + (float)r.dir_mg[1] * r.dir_mg[1] +
                        (float)r.dir_mg[2] * r.dir_mg[2]);
        for (int k = 0; k < 3; k++) ev.tap.dir[k] = n > 0 ? (int8_t)lroundf(127.0f * r.dir_mg[k] / n) : 0;
        ev.jolt_mg = r.jolt_mg;
        ev.detect_us = dt;
      }
      if (count < TAP_MAX_COUNT) count++;
      lastTapMs = now;
    }
  }
  if (count > 0 && now - lastTapMs > TAP_GAP_MS) {
    ev.tap.seq = seq++;
    ev.tap.count = count;
    xQueueSend(tapQueue, &ev, 0);
    tapGestures++;
    count = 0;
  }
}

// ---- 1 kHz sampling task ----
static void samplerTask(void *) {
  TBPacket pkt = {};
  uint16_t seq = 0;
  uint8_t n = 0;
  uint8_t buf[24];   // 0x22..0x39: gyro, accel, OIS (unused), high-g accel; little-endian
  uint32_t sinceCheck = 0;
  TickType_t last = xTaskGetTickCount();

  for (;;) {
    vTaskDelayUntil(&last, pdMS_TO_TICKS(1));

    // Gyro range changes only between packets, so every packet's samples share one scale.
    if (imuOk && n == 0 && gyro4000Wanted != gyro4000) {
      bool wide = gyro4000Wanted;
      if (setGyroRange(wide)) {
        gyro4000 = wide;
        Serial.printf("Gyro range now ±%d dps\n", wide ? 4000 : 2000);
      } else {
        // Don't retry every packet (each try stops the gyro); the watchdog below restores the old range.
        gyro4000Wanted = gyro4000;
        Serial.printf("Gyro range change to ±%d dps FAILED\n", wide ? 4000 : 2000);
      }
    }
    // Watchdog: a brownout (e.g. a loose supply wire during a fast spin) resets the IMU to power-down,
    // after which it reads all zeros. Check the settings once a second and restore them.
    if (imuOk && ++sinceCheck >= 1000) {
      sinceCheck = 0;
      uint8_t c1 = readReg(LSM_ADDR, LSM_CTRL1), c6 = readReg(LSM_ADDR, LSM_CTRL6);
      if (c1 != CTRL1_ACCEL || c6 != (gyro4000 ? CTRL6_GYRO_4000 : CTRL6_GYRO_2000)) {
        imuResets++;
        Serial.printf("IMU lost its settings (CTRL1 0x%02X CTRL6 0x%02X): reconfiguring\n", c1, c6);
        setupIMU(gyro4000);
      }
    }

    TBSample s = {};
    uint32_t t = micros();
    if (imuOk && readRegs(LSM_ADDR, LSM_OUTX_L_G, buf, sizeof(buf))) {
      auto le = [&](int i) { return (int16_t)(buf[i + 1] << 8 | buf[i]); };
      const float g = LSM_TO_WIRE_GYRO;
      s.gx = clamp16(le(0) * g);
      s.gy = clamp16(le(2) * g);
      s.gz = clamp16(le(4) * g);
      s.ax = le(6);
      s.ay = le(8);
      s.az = le(10);
      const int hg = LSM_OUTX_L_A_HG - LSM_OUTX_L_G;
      s.hx = toH3Wire(le(hg));
      s.hy = toH3Wire(le(hg + 2));
      s.hz = toH3Wire(le(hg + 4));
      const int16_t a[3] = {s.ax, s.ay, s.az};
      int16_t gmax = max(max(abs(le(0)), abs(le(2))), abs(le(4)));
      const float dpsPerLsb = LSM_G_DPS_PER_LSB * (gyro4000 ? 2 : 1);
      tapStep(a, gmax * dpsPerLsb, t);

      // Impact detection runs in both modes (it also feeds the serial log); windows are only claimed when
      // someone in impact mode will receive them. Window gyro is always at 8.2 LSB/dps.
      ImpactInput in;
      in.wire = s;
      in.t_us = t;
      int16_t *wireGyro[3] = {&in.wire.gx, &in.wire.gy, &in.wire.gz};
      for (int k = 0; k < 3; k++) {
        float dps = le(2 * k) * dpsPerLsb;
        *wireGyro[k] = clamp16(dps * WIRE_G_LSB_PER_DPS / 2);
        in.gyro[k] = dps * (float)DEG_TO_RAD;
        in.accel[k] = le(6 + 2 * k) / 2048.0f;
        in.highG[k] = le(hg + 2 * k) * LSM_HG_MG_PER_LSB / 1000.0f;
      }
      const bool connected = server->getConnectedCount() > 0;
      const bool impactMode = streamMode != TB_STREAM_RAW && connected;
      static int fillSlot = -1;
      // Raw mode with a phone connected (calibration, raw recordings) doesn't capture: those aren't play.
      const bool capture = impactMode || (backlogEnabled && !connected);
      if (capture && fillSlot < 0) fillSlot = backlogReserve();
      if (!capture && fillSlot >= 0) {
        backlogRelease(fillSlot);
        fillSlot = -1;
      }
      TBHit hit;
      uint32_t s0 = micros();
      int r = impactStep(in, micLastTriggerUs(), &hit, fillSlot >= 0 ? &backlogSlot(fillSlot).win : nullptr);
      uint32_t took = micros() - s0;
      if (took > impactStepMaxUs) impactStepMaxUs = took;
      if (r & IMPACT_HIT) {
        xQueueSend(hitQueue, &hit, 0);
        lastActiveMs = millis();
      }
      if (r & IMPACT_WINDOW) {
        int64_t unix0 = unixAtBootMs;
        uint32_t nowMs = millis();
        backlogCaptured(fillSlot, nowMs, unix0 ? (uint64_t)(unix0 + nowMs) : 0,
                        !(streamMode == TB_STREAM_IMPACTS_ACKED && connected));
        fillSlot = -1;
        xTaskNotifyGive(shotTaskHandle);
      }
      if (in.gyro[0] * in.gyro[0] + in.gyro[1] * in.gyro[1] + in.gyro[2] * in.gyro[2] > 1.0f) lastActiveMs = millis();
    } else if (imuOk) {
      i2cErrors++;
    }
    lastSample = s;
    samplesRead++;

    if (!streaming || streamMode != TB_STREAM_RAW || server->getConnectedCount() == 0) {
      n = 0;
      continue;
    }
    if (n == 0) pkt.t0_us = t;
    pkt.s[n++] = s;
    if (n == TB_SAMPLES_PER_PACKET) {
      pkt.seq = seq++;
      pkt.count = n;
      pkt.flags = (imuOk ? TB_FLAG_MPU_OK | TB_FLAG_H3LIS_OK : 0) | TB_FLAG_STREAMING |
                  (gyro4000 ? TB_FLAG_GYRO_4000 : 0);
      if (xQueueSend(packetQueue, &pkt, 0) != pdTRUE) droppedPackets++;
      n = 0;
    }
  }
}

// ---- BLE ----
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, ble_gap_conn_desc *desc) override {
    Serial.println("BLE: connected");
    // 15-30 ms interval: the fastest iOS accepts; several packets go out per interval.
    s->updateConnParams(desc->conn_handle, 12, 24, 0, 400);
    // A 152-byte packet should travel in one link-layer PDU, at 2 Mbit/s when the phone allows it.
    ble_gap_set_data_len(desc->conn_handle, 251, 2120);
    ble_gap_set_prefered_le_phy(desc->conn_handle, BLE_GAP_LE_PHY_2M_MASK, BLE_GAP_LE_PHY_2M_MASK, 0);
    // Keep advertising so a second device (Mac + iPhone) can join; otherwise whoever reconnects first
    // after a reboot locks everyone else out.
    if (s->getConnectedCount() < 3) NimBLEDevice::startAdvertising();
  }
  void onDisconnect(NimBLEServer *) override {
    Serial.println("BLE: disconnected, advertising again");
    NimBLEDevice::startAdvertising();
    if (NimBLEDevice::getServer()->getConnectedCount() == 0) {
      xQueueReset(packetQueue);
      gyro4000Wanted = true;    // back to the default, whatever the last app chose
      streamMode = TB_STREAM_RAW;   // the next app may not know about impact mode (captured windows stay queued)
    }
  }
};

class ControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c) override {
    std::string v = c->getValue();
    if (v.empty()) return;
    switch ((uint8_t)v[0]) {
      case TB_CMD_START_STREAM: streaming = true; break;
      case TB_CMD_STOP_STREAM: streaming = false; break;
      case TB_CMD_GYRO_RANGE:
        if (v.size() >= 2 && (v[1] == 0 || v[1] == 1)) gyro4000Wanted = v[1] == 1;
        break;
      case TB_CMD_STREAM_MODE:
        if (v.size() >= 2 && v[1] <= TB_STREAM_IMPACTS_ACKED) {
          streamMode = v[1];
          if (streamMode == TB_STREAM_IMPACTS_ACKED && !backlogEnabled) backlogEnablePending = true;
        }
        break;
      case TB_CMD_SHOT_CONFIG: {
        ShotConfig c;
        if (shotConfigDecode((const uint8_t *)v.data() + 1, v.size() - 1, &c)) {
          portENTER_CRITICAL(&cfgMux);
          shotConfig = c;
          portEXIT_CRITICAL(&cfgMux);
        }
        break;
      }
      case TB_CMD_WINDOW_ACK:
      case TB_CMD_WINDOW_RESEND:
        if (v.size() >= 5) {
          BacklogCmd b = {};
          b.cmd = (uint8_t)v[0];
          b.boot = (uint8_t)v[1] | (uint8_t)v[2] << 8;
          b.seq = (uint8_t)v[3] | (uint8_t)v[4] << 8;
          if (b.cmd == TB_CMD_WINDOW_RESEND && v.size() >= 6) {
            b.n = (uint8_t)v[5];
            if (b.n > sizeof(b.chunks) || v.size() < 6u + b.n) b.n = 0;   // malformed: resend it all
            memcpy(b.chunks, v.data() + 6, b.n);
          }
          xQueueSend(backlogCmdQueue, &b, 0);
        }
        break;
      case TB_CMD_SET_TIME:
        if (v.size() >= 9) {
          uint64_t ms = 0;
          memcpy(&ms, v.data() + 1, 8);
          unixAtBootMs = (int64_t)ms - (int64_t)millis();
        }
        break;
    }
  }
};

static TBStatus makeStatus() {
  TBStatus st;
  st.battery_mv = PIN_VBAT >= 0 ? (uint16_t)(analogReadMilliVolts(PIN_VBAT) * 2) : 0;
  st.fw_major = TB_FW_MAJOR;
  st.fw_minor = TB_FW_MINOR;
  st.flags = (imuOk ? TB_FLAG_MPU_OK | TB_FLAG_H3LIS_OK : 0) | (streaming ? TB_FLAG_STREAMING : 0) |
             (gyro4000 ? TB_FLAG_GYRO_4000 : 0) | (streamMode == TB_STREAM_IMPACTS ? TB_FLAG_IMPACT_MODE : 0);
  st.h3lis_range = h3Range;
  st.dropped = droppedPackets;
  return st;
}

static void setupBLE() {
  // Two rackets in one room must be tellable apart: suffix the name with the last MAC bytes.
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_BT);
  char bleName[24];
  snprintf(bleName, sizeof(bleName), TB_DEVICE_NAME " %02X%02X", mac[4], mac[5]);
  NimBLEDevice::init(bleName);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(185);

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  NimBLEService *svc = server->createService(TB_SERVICE_UUID);
  imuChar = svc->createCharacteristic(TB_IMU_UUID, NIMBLE_PROPERTY::NOTIFY);
  statusChar = svc->createCharacteristic(TB_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  shotChar = svc->createCharacteristic(TB_SHOT_UUID, NIMBLE_PROPERTY::NOTIFY);
  tapChar = svc->createCharacteristic(TB_TAP_UUID, NIMBLE_PROPERTY::NOTIFY);
  hitChar = svc->createCharacteristic(TB_HIT_UUID, NIMBLE_PROPERTY::NOTIFY);
  windowChar = svc->createCharacteristic(TB_WINDOW_UUID, NIMBLE_PROPERTY::NOTIFY);
  summaryChar = svc->createCharacteristic(TB_SUMMARY_UUID, NIMBLE_PROPERTY::NOTIFY);
  poseChar = svc->createCharacteristic(TB_POSE_UUID, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic *control =
      svc->createCharacteristic(TB_CONTROL_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  control->setCallbacks(new ControlCallbacks());
  svc->start();

  TBStatus st = makeStatus();
  statusChar->setValue((uint8_t *)&st, sizeof(st));

  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(TB_SERVICE_UUID);
  adv->setScanResponse(true);
  adv->start();
  Serial.printf("BLE: advertising as \"%s\"\n", bleName);
}

// ---- Backlog: boot number and flags in NVS, windows in the spare data partition ----
static const esp_partition_t *backlogPart = nullptr;
static bool partRead(uint32_t off, void *dst, uint32_t len) { return esp_partition_read(backlogPart, off, dst, len) == ESP_OK; }
static bool partWrite(uint32_t off, const void *src, uint32_t len) {
  return esp_partition_write(backlogPart, off, src, len) == ESP_OK;
}
static bool partErase(uint32_t off, uint32_t len) { return esp_partition_erase_range(backlogPart, off, len) == ESP_OK; }
static BacklogFlash backlogFlash = {0, partRead, partWrite, partErase};

static void setupBacklog() {
  Preferences prefs;
  prefs.begin("tb", false);
  bootId = prefs.getUShort("boot", 0) + 1;
  prefs.putUShort("boot", bootId);
  backlogEnabled = prefs.getBool("backlog", false);
  prefs.end();
  // The default partition table's "spiffs" partition (1.375 MB), which nothing else uses.
  backlogPart = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, nullptr);
  backlogFlash.size = backlogPart ? backlogPart->size : 0;
  backlogInit(bootId, &backlogFlash);
  BacklogStats st = backlogStats();
  Serial.printf("Backlog: boot %u, %s, flash %lu KB (%lu windows waiting)\n", bootId,
                backlogEnabled ? "capturing" : "off until an app asks", (unsigned long)(backlogFlash.size / 1024),
                (unsigned long)st.flashPending);
}

// Computes each captured window's shot (shot.cpp) off the 1 kHz sampler.
static void shotTask(void *) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(100));
    int s;
    while ((s = backlogNextCaptured()) >= 0) {
      ShotConfig cfg;
      portENTER_CRITICAL(&cfgMux);
      cfg = shotConfig;
      portEXIT_CRITICAL(&cfgMux);
      BacklogSlot &b = backlogSlot(s);
      uint32_t t0 = micros();
      bool ok = shotAnalyze(cfg, b.win, gyro4000, 0.195f, &b.summary);
      uint32_t took = micros() - t0;
      if (took > shotMaxUs) shotMaxUs = took;
      backlogAnalyzed(s, ok);
    }
  }
}

// Sends the backlog's next message; false when there is nothing to send.
static bool sendBacklog(bool acked) {
  uint32_t now = millis();
  BacklogMsg m = backlogNext(acked, now);
  if (m.kind == BacklogMsg::NONE) return false;
  BacklogSlot &b = backlogSlot(m.slot);
  const uint8_t base = (imuOk ? TB_FLAG_MPU_OK | TB_FLAG_H3LIS_OK : 0) | TB_FLAG_GYRO_4000 | (b.backlog ? TB_FLAG_BACKLOG : 0);
  if (m.kind == BacklogMsg::SUMMARY) {
    TBShotSummary s = b.summary;
    s.seq = b.win.seq;
    s.boot = b.boot;
    s.age_ms = b.boot == bootId ? now - b.hitMs : 0xFFFFFFFFu;
    s.unix_ms = b.unixMs;
    if (b.backlog) s.flags |= TB_SUMMARY_BACKLOG;
    summaryChar->setValue((uint8_t *)&s, sizeof(s));
    summaryChar->notify();
  } else if (acked) {
    TBWindowChunkAcked c;
    c.seq = b.win.seq;
    c.index = (uint8_t)m.chunk;
    c.total = TB_WINDOW_CHUNKS;
    c.impact = b.win.impact;
    memcpy(c.q0, b.win.q0, sizeof(c.q0));
    c.t0_us = b.win.chunkT0[m.chunk];
    c.count = TB_SAMPLES_PER_PACKET;
    c.flags = base;
    c.boot = b.boot;
    memcpy(c.s, &b.win.s[m.chunk * TB_SAMPLES_PER_PACKET], sizeof(c.s));
    windowChar->setValue((uint8_t *)&c, sizeof(c));
    windowChar->notify();
  } else {
    TBWindowChunk c;
    c.seq = b.win.seq;
    c.index = (uint8_t)m.chunk;
    c.total = TB_WINDOW_CHUNKS;
    c.impact = b.win.impact;
    memcpy(c.q0, b.win.q0, sizeof(c.q0));
    c.t0_us = b.win.chunkT0[m.chunk];
    c.count = TB_SAMPLES_PER_PACKET;
    c.flags = base & ~TB_FLAG_BACKLOG;
    memcpy(c.s, &b.win.s[m.chunk * TB_SAMPLES_PER_PACKET], sizeof(c.s));
    windowChar->setValue((uint8_t *)&c, sizeof(c));
    windowChar->notify();
  }
  backlogSent(m, acked, now);
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1500);  // give USB serial time to attach
  Serial.println("\n=== Tennis Buddy firmware " + String(TB_FW_MAJOR) + "." + String(TB_FW_MINOR) + " ===");

  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(400000);
  // The IMU may not be ready right after power-up: retry a few times.
  for (int attempt = 0; attempt < 10 && !imuOk; attempt++) {
    imuOk = setupIMU(gyro4000);
    if (!imuOk) delay(100);
  }
  Serial.printf("LSM6DSV320X: %s\n", imuOk ? "OK" : "NOT FOUND");
  if (!imuOk) Serial.println("Check wiring: SDA=D4, SCL=D5, VCC=3V3, GND=GND, CS=3V3, SDO=GND (see docs/WIRING.md)");

  analogReadResolution(12);
  packetQueue = xQueueCreate(48, sizeof(TBPacket));
  shotQueue = xQueueCreate(8, sizeof(TBShot));
  micOk = micBegin(shotQueue);
  Serial.printf("INMP441 mic + ridge distance model (156 features): %s\n", micOk ? "OK" : "FAILED to start I2S");
  tapQueue = xQueueCreate(8, sizeof(TapEvent));
  hitQueue = xQueueCreate(8, sizeof(TBHit));
  backlogCmdQueue = xQueueCreate(16, sizeof(BacklogCmd));
  impactReset();
  setupBacklog();
  xTaskCreate(shotTask, "shot", 4096, nullptr, 1, &shotTaskHandle);
  tapInit();
  tapConfigure(TAP_TRIG_MG, TAP_MAX_LEN, TAP_REFRACTORY_MS);
  Serial.printf("Handle taps: trigger %ld mg, gestures up to %d taps %lu ms apart\n", (long)TAP_TRIG_MG,
                TAP_MAX_COUNT, (unsigned long)TAP_GAP_MS);
  Serial.println("Send 'c' over serial to toggle clip dump for training data (tools/collect_clips.py)");
  setupBLE();
  xTaskCreate(samplerTask, "sampler", 4096, nullptr, configMAX_PRIORITIES - 2, nullptr);
}

void loop() {
  // Serial 'c' toggles clip dumping for data collection.
  while (Serial.available()) {
    if (Serial.read() == 'c') {
      micSetCollect(!micCollecting());
      Serial.printf("collect mode %s\n", micCollecting() ? "ON" : "OFF");
    }
  }
  const bool impactMode = streamMode != TB_STREAM_RAW && server->getConnectedCount() > 0;
  const bool acked = streamMode == TB_STREAM_IMPACTS_ACKED && server->getConnectedCount() > 0;
  if (backlogEnablePending) {
    backlogEnablePending = false;
    backlogEnabled = true;
    Preferences prefs;
    prefs.begin("tb", false);
    prefs.putBool("backlog", true);
    prefs.end();
  }
  BacklogCmd cmd;
  while (xQueueReceive(backlogCmdQueue, &cmd, 0) == pdTRUE) {
    if (cmd.cmd == TB_CMD_WINDOW_ACK) backlogAck(cmd.boot, cmd.seq);
    else backlogResend(cmd.boot, cmd.seq, cmd.chunks, cmd.n);
  }
  // Hits go out first: they are what makes the phone react.
  TBHit hit;
  while (xQueueReceive(hitQueue, &hit, 0) == pdTRUE) {
    if (impactMode) {
      hitChar->setValue((uint8_t *)&hit, sizeof(hit));
      hitChar->notify();
    }
    Serial.printf("HIT #%u %s jump %u g swing %u dps\n", hit.seq, hit.source == TB_HIT_MIC ? "mic" : "motion",
                  hit.jump_g, hit.swing_dps);
  }
  // Sweet-spot verdicts from the on-device model.
  TBShot shot;
  while (xQueueReceive(shotQueue, &shot, 0) == pdTRUE) {
    shotChar->setValue((uint8_t *)&shot, sizeof(shot));
    if (server->getConnectedCount() > 0) shotChar->notify();
  }
  // Handle-tap gestures.
  TapEvent tap;
  while (xQueueReceive(tapQueue, &tap, 0) == pdTRUE) {
    tapChar->setValue((uint8_t *)&tap.tap, sizeof(tap.tap));
    if (server->getConnectedCount() > 0) tapChar->notify();
    Serial.printf("TAP x%u strength %u (jolt %ld mg) dir %+.2f %+.2f %+.2f zone %s detect %luus\n",
                  tap.tap.count, tap.tap.strength, (long)tap.jolt_mg, tap.tap.dir[0] / 127.0f,
                  tap.tap.dir[1] / 127.0f, tap.tap.dir[2] / 127.0f, TAP_ZONE_NAMES[tap.tap.zone],
                  (unsigned long)tap.detect_us);
  }

  // Impact mode: live orientation, then the current hit's window while NimBLE has buffers to spare.
  static uint32_t lastPose = 0;
  if (impactMode && millis() - lastPose >= POSE_INTERVAL_MS) {
    lastPose = millis();
    float q[4];
    impactOrientation(q);
    TBSample ls = lastSample;
    float gs = gyro4000 ? WIRE_G_LSB_PER_DPS / 2 : WIRE_G_LSB_PER_DPS;
    float h3Scale = (h3Range == 0) ? 0.049f : (h3Range == 1) ? 0.098f : 0.195f;
    float gyroDps = sqrtf((float)ls.gx * ls.gx + (float)ls.gy * ls.gy + (float)ls.gz * ls.gz) / gs;
    float hx = (ls.hx >> 4) * h3Scale, hy = (ls.hy >> 4) * h3Scale, hz = (ls.hz >> 4) * h3Scale;
    float highG = sqrtf(hx * hx + hy * hy + hz * hz);
    TBPose pose;
    for (int k = 0; k < 4; k++) pose.q[k] = impactQuatWire(q[k]);
    pose.gyro_dps = (uint16_t)min(gyroDps, 65535.0f);
    pose.high_g = (uint8_t)min(highG, 255.0f);
    pose.flags = makeStatus().flags;
    poseChar->setValue((uint8_t *)&pose, sizeof(pose));
    poseChar->notify();
  }
  // Summaries, then windows, while NimBLE has buffers to spare.
  while (impactMode && os_msys_num_free() > BLE_BUFFER_RESERVE && sendBacklog(acked)) {
  }
  // Flash housekeeping, one small step; it stalls the CPU, so let the sampler catch up after it.
  const bool idle = millis() - lastActiveMs > 3000;
  if (backlogStep(acked, idle, millis())) vTaskDelay(1);

  // Send queued packets as notifications.
  // Send queued packets while NimBLE has buffers to spare. When the link can't keep up, packets wait in
  // the queue and the sampler counts any that overflow it as dropped.
  TBPacket pkt;
  if (os_msys_num_free() <= BLE_BUFFER_RESERVE) {
    vTaskDelay(1);
  } else {
    while (os_msys_num_free() > BLE_BUFFER_RESERVE && xQueueReceive(packetQueue, &pkt, pdMS_TO_TICKS(2)) == pdTRUE) {
      imuChar->setValue((uint8_t *)&pkt, sizeof(pkt));
      imuChar->notify();
      sentPackets++;
    }
  }

  static uint32_t lastStatus = 0, lastSamples = 0, lastSent = 0, lastRetry = 0;
  uint32_t now = millis();
  if (!imuOk && now - lastRetry > 2000) {
    lastRetry = now;
    imuOk = setupIMU(gyro4000);
  }
  if (now - lastStatus >= 1000) {
    TBStatus st = makeStatus();
    statusChar->setValue((uint8_t *)&st, sizeof(st));
    if (server->getConnectedCount() > 0) statusChar->notify();

    uint32_t rate = samplesRead - lastSamples;
    lastSamples = samplesRead;
    uint32_t sentRate = sentPackets - lastSent;
    lastSent = sentPackets;
    lastStatus = now;
    TBSample s = lastSample;
    float gs = gyro4000 ? WIRE_G_LSB_PER_DPS / 2 : WIRE_G_LSB_PER_DPS;
    float h3Scale = (h3Range == 0) ? 0.049f : (h3Range == 1) ? 0.098f : 0.195f;
    MicLevel mic = micLevel();
    BacklogStats bs = backlogStats();
    Serial.printf(
        "rate %4lu Hz | a[g] %6.2f %6.2f %6.2f  g[dps] %7.1f %7.1f %7.1f | high-g a[g] %6.1f %6.1f %6.1f | "
        "mic floor %4d peak %5d trig %5d hits %lu | taps %lu (rejected %lu) jolt %4ld/%ld mg | BLE %s, "
        "sent %lu pkt/s, dropped %u, bufs free %d, itvl %.1f ms, i2c err %lu, gyro ±%d dps, imu resets %lu | "
        "%s mode, hits %lu, windows dropped %lu, detect max %lu us, shot max %lu us | backlog acked %lu resent %lu "
        "flash %lu waiting, %lu spilled, %lu lost | heap %lu | bat %u mV\n",
        (unsigned long)rate, s.ax / 2048.0f, s.ay / 2048.0f, s.az / 2048.0f, s.gx / gs, s.gy / gs,
        s.gz / gs, (s.hx >> 4) * h3Scale, (s.hy >> 4) * h3Scale, (s.hz >> 4) * h3Scale, mic.floor, mic.peak,
        mic.trigger, (unsigned long)micImpactCount(), (unsigned long)tapGestures, (unsigned long)tapsRejected,
        (long)tapPeakDeviation(), (long)TAP_TRIG_MG,
        server->getConnectedCount() ? (server->getConnectedCount() > 1 ? "connected x2+" : "connected") : "advertising", (unsigned long)sentRate, droppedPackets, os_msys_num_free(), server->getConnectedCount() ? server->getPeerInfo(0).getConnInterval() * 1.25f : 0.0f, (unsigned long)i2cErrors, gyro4000 ? 4000 : 2000, (unsigned long)imuResets,
        streamMode == TB_STREAM_IMPACTS_ACKED ? "acked impact" : streamMode == TB_STREAM_IMPACTS ? "impact" : "raw",
        (unsigned long)impactHits(), (unsigned long)impactWindowsDropped(), (unsigned long)impactStepMaxUs,
        (unsigned long)shotMaxUs, (unsigned long)bs.acked, (unsigned long)bs.resent, (unsigned long)bs.flashPending,
        (unsigned long)bs.spilled, (unsigned long)bs.flashLost, (unsigned long)ESP.getFreeHeap(), st.battery_mv);
    impactStepMaxUs = 0;
    shotMaxUs = 0;
  }
}
