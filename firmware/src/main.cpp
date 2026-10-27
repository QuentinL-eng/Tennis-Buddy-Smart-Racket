// Tennis Buddy racket firmware.
//
// Reads the LSM6DSV320X (gyro + low-g accel + high-g accel, on a STEVAL-MKI251A) at 1 kHz and streams
// samples over BLE. All analysis happens in the apps. Wiring and protocol: docs/PLAN.md.
// The BLE format predates this IMU (MPU6050 + H3LIS331DL), so samples are converted to those units.
//
// Serial monitor (115200) prints a status line every second for bench bring-up.

#include <Arduino.h>
#include <Wire.h>
#include <NimBLEDevice.h>
#include "protocol.h"
#include "mic.h"

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
static const float LSM_G_DPS_PER_LSB = 0.070f;    // ±2000 dps
static const float LSM_HG_MG_PER_LSB = 10.417f;   // ±320 g
// Wire units (protocol.h): gyro 16.4 LSB/dps; low-g accel 2048 LSB/g, which the LSM's ±16 g (0.488 mg/LSB)
// already matches; high-g as H3LIS counts << 4 at the app-selected range.
static const float WIRE_G_LSB_PER_DPS = 16.4f;

// ---- State ----
static bool imuOk = false;
static volatile bool streaming = true;   // stream whenever a client subscribes
static volatile uint8_t h3Range = 1;     // 0 = 100 g, 1 = 200 g, 3 = 400 g

static volatile uint16_t droppedPackets = 0;
static volatile uint32_t samplesRead = 0, i2cErrors = 0;
static TBSample lastSample = {};

static QueueHandle_t packetQueue;
static NimBLEServer *server;
static NimBLECharacteristic *imuChar, *statusChar, *shotChar;
static QueueHandle_t shotQueue;
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
static bool setupIMU() {
  uint8_t who = readReg(LSM_ADDR, LSM_WHO_AM_I);
  Serial.printf("LSM6DSV320X WHO_AM_I = 0x%02X (expect 0x%02X)\n", who, LSM_ID);
  if (who != LSM_ID) return false;
  bool ok = writeReg(LSM_ADDR, LSM_CTRL3, 0x01);        // software reset
  delay(10);
  ok &= writeReg(LSM_ADDR, LSM_CTRL3, 0x44);            // BDU + register auto-increment
  ok &= writeReg(LSM_ADDR, LSM_CTRL6, 0x04);            // gyro ±2000 dps
  ok &= writeReg(LSM_ADDR, LSM_CTRL8, 0x03);            // accel ±16 g
  ok &= writeReg(LSM_ADDR, LSM_CTRL1, 0x0A);            // accel high-performance, 1.92 kHz
  ok &= writeReg(LSM_ADDR, LSM_CTRL2, 0x0A);            // gyro high-performance, 1.92 kHz
  ok &= writeReg(LSM_ADDR, LSM_CTRL1_XL_HG, 0xAC);      // high-g: output regs on, 1.92 kHz, ±320 g
  return ok;
}

static int16_t clamp16(float v) { return (int16_t)constrain(lroundf(v), -32768L, 32767L); }

// High-g sample (LSM LSBs) -> H3LIS 12-bit counts, left-aligned, at the range the app selected.
static int16_t toH3Wire(int16_t raw) {
  float mgPerCount = (h3Range == 0) ? 49.0f : (h3Range == 1) ? 98.0f : 195.0f;
  long counts = constrain(lroundf(raw * LSM_HG_MG_PER_LSB / mgPerCount), -2048L, 2047L);
  return (int16_t)(counts * 16);
}

// ---- 1 kHz sampling task ----
static void samplerTask(void *) {
  TBPacket pkt = {};
  uint16_t seq = 0;
  uint8_t n = 0;
  uint8_t buf[24];   // 0x22..0x39: gyro, accel, OIS (unused), high-g accel; little-endian
  TickType_t last = xTaskGetTickCount();

  for (;;) {
    vTaskDelayUntil(&last, pdMS_TO_TICKS(1));

    TBSample s = {};
    uint32_t t = micros();
    if (imuOk && readRegs(LSM_ADDR, LSM_OUTX_L_G, buf, sizeof(buf))) {
      auto le = [&](int i) { return (int16_t)(buf[i + 1] << 8 | buf[i]); };
      const float g = LSM_G_DPS_PER_LSB * WIRE_G_LSB_PER_DPS;
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
    } else if (imuOk) {
      i2cErrors++;
    }
    lastSample = s;
    samplesRead++;

    if (!streaming || server->getConnectedCount() == 0) {
      n = 0;
      continue;
    }
    if (n == 0) pkt.t0_us = t;
    pkt.s[n++] = s;
    if (n == TB_SAMPLES_PER_PACKET) {
      pkt.seq = seq++;
      pkt.count = n;
      pkt.flags = (imuOk ? TB_FLAG_MPU_OK | TB_FLAG_H3LIS_OK : 0) | TB_FLAG_STREAMING;
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
    // Keep advertising so a second device (Mac + iPhone) can join; otherwise whoever reconnects first
    // after a reboot locks everyone else out.
    if (s->getConnectedCount() < 3) NimBLEDevice::startAdvertising();
  }
  void onDisconnect(NimBLEServer *) override {
    Serial.println("BLE: disconnected, advertising again");
    NimBLEDevice::startAdvertising();
    if (NimBLEDevice::getServer()->getConnectedCount() == 0) xQueueReset(packetQueue);
  }
};

class ControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c) override {
    std::string v = c->getValue();
    if (v.empty()) return;
    switch ((uint8_t)v[0]) {
      case TB_CMD_START_STREAM: streaming = true; break;
      case TB_CMD_STOP_STREAM: streaming = false; break;
      case TB_CMD_H3LIS_RANGE:
        if (v.size() >= 2 && (v[1] == 0 || v[1] == 1 || v[1] == 3)) {
          h3Range = v[1];
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
  st.flags = (imuOk ? TB_FLAG_MPU_OK | TB_FLAG_H3LIS_OK : 0) | (streaming ? TB_FLAG_STREAMING : 0);
  st.h3lis_range = h3Range;
  st.dropped = droppedPackets;
  return st;
}

static void setupBLE() {
  NimBLEDevice::init(TB_DEVICE_NAME);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(185);

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  NimBLEService *svc = server->createService(TB_SERVICE_UUID);
  imuChar = svc->createCharacteristic(TB_IMU_UUID, NIMBLE_PROPERTY::NOTIFY);
  statusChar = svc->createCharacteristic(TB_STATUS_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  shotChar = svc->createCharacteristic(TB_SHOT_UUID, NIMBLE_PROPERTY::NOTIFY);
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
  Serial.println("BLE: advertising as \"" TB_DEVICE_NAME "\"");
}

void setup() {
  Serial.begin(115200);
  delay(1500);  // give USB serial time to attach
  Serial.println("\n=== Tennis Buddy firmware " + String(TB_FW_MAJOR) + "." + String(TB_FW_MINOR) + " ===");

  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(400000);
  // The IMU may not be ready right after power-up: retry a few times.
  for (int attempt = 0; attempt < 10 && !imuOk; attempt++) {
    imuOk = setupIMU();
    if (!imuOk) delay(100);
  }
  Serial.printf("LSM6DSV320X: %s\n", imuOk ? "OK" : "NOT FOUND");
  if (!imuOk) Serial.println("Check wiring: SDA=D4, SCL=D5, VCC=3V3, GND=GND, CS=3V3, SDO=GND (see docs/WIRING.md)");

  analogReadResolution(12);
  packetQueue = xQueueCreate(48, sizeof(TBPacket));
  shotQueue = xQueueCreate(8, sizeof(TBShot));
  micOk = micBegin(shotQueue);
  Serial.printf("INMP441 mic + sweet-spot model: %s\n", micOk ? "OK" : "FAILED to start I2S");
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
  // Sweet-spot verdicts from the on-device model.
  TBShot shot;
  while (xQueueReceive(shotQueue, &shot, 0) == pdTRUE) {
    shotChar->setValue((uint8_t *)&shot, sizeof(shot));
    if (server->getConnectedCount() > 0) shotChar->notify();
  }

  // Send queued packets as notifications.
  TBPacket pkt;
  while (xQueueReceive(packetQueue, &pkt, pdMS_TO_TICKS(2)) == pdTRUE) {
    imuChar->setValue((uint8_t *)&pkt, sizeof(pkt));
    imuChar->notify();
  }

  static uint32_t lastStatus = 0, lastSamples = 0, lastRetry = 0;
  uint32_t now = millis();
  if (!imuOk && now - lastRetry > 2000) {
    lastRetry = now;
    imuOk = setupIMU();
  }
  if (now - lastStatus >= 1000) {
    TBStatus st = makeStatus();
    statusChar->setValue((uint8_t *)&st, sizeof(st));
    if (server->getConnectedCount() > 0) statusChar->notify();

    uint32_t rate = samplesRead - lastSamples;
    lastSamples = samplesRead;
    lastStatus = now;
    TBSample s = lastSample;
    float h3Scale = (h3Range == 0) ? 0.049f : (h3Range == 1) ? 0.098f : 0.195f;
    MicLevel mic = micLevel();
    Serial.printf(
        "rate %4lu Hz | a[g] %6.2f %6.2f %6.2f  g[dps] %7.1f %7.1f %7.1f | high-g a[g] %6.1f %6.1f %6.1f | "
        "mic floor %4d peak %5d trig %5d hits %lu | BLE %s, dropped %u, i2c err %lu | bat %u mV\n",
        (unsigned long)rate, s.ax / 2048.0f, s.ay / 2048.0f, s.az / 2048.0f, s.gx / 16.4f, s.gy / 16.4f,
        s.gz / 16.4f, (s.hx >> 4) * h3Scale, (s.hy >> 4) * h3Scale, (s.hz >> 4) * h3Scale, mic.floor, mic.peak,
        mic.trigger, (unsigned long)micImpactCount(),
        server->getConnectedCount() ? (server->getConnectedCount() > 1 ? "connected x2+" : "connected") : "advertising", droppedPackets, (unsigned long)i2cErrors,
        st.battery_mv);
  }
}
