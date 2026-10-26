// Tennis Buddy racket firmware.
//
// Reads the MPU6050 (gyro + low-g accel) and H3LIS331DL (high-g accel) at 1 kHz and streams raw
// samples over BLE. All analysis happens in the apps. Wiring and protocol: docs/PLAN.md.
//
// Serial monitor (115200) prints a status line every second for bench bring-up.

#include <Arduino.h>
#include <Wire.h>
#include <NimBLEDevice.h>
#include "protocol.h"
#include "mic.h"

// ---- Pins (XIAO ESP32C3) ----
// As built (see docs/WIRING.md): sensors on the right header, mic on D0-D2.
static const int PIN_SDA = D9;   // GPIO9 (strapping pin; fine, the I2C pull-ups keep it high at boot)
static const int PIN_SCL = D10;  // GPIO10
static const int PIN_VBAT = -1;  // no battery divider fitted (A0 is the mic clock)

// ---- I2C addresses / registers ----
static const uint8_t MPU_ADDR = 0x68;
static const uint8_t MPU_WHO_AM_I = 0x75, MPU_PWR_MGMT_1 = 0x6B, MPU_SMPLRT_DIV = 0x19,
                     MPU_CONFIG = 0x1A, MPU_GYRO_CONFIG = 0x1B, MPU_ACCEL_CONFIG = 0x1C,
                     MPU_ACCEL_XOUT_H = 0x3B;

static const uint8_t H3_ADDR = 0x18;
static const uint8_t H3_WHO_AM_I = 0x0F, H3_CTRL_REG1 = 0x20, H3_CTRL_REG4 = 0x23,
                     H3_OUT_X_L = 0x28, H3_AUTO_INC = 0x80;

// ---- State ----
static bool mpuOk = false, h3Ok = false;
static volatile bool streaming = true;   // stream whenever a client subscribes
static volatile uint8_t h3Range = 1;     // 0 = 100 g, 1 = 200 g, 3 = 400 g
static volatile bool h3RangeDirty = false;
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
static bool setupMPU() {
  uint8_t who = readReg(MPU_ADDR, MPU_WHO_AM_I);
  Serial.printf("MPU6050 WHO_AM_I = 0x%02X (expect 0x68; clones may differ)\n", who);
  if (who == 0x00 || who == 0xFF) return false;
  bool ok = writeReg(MPU_ADDR, MPU_PWR_MGMT_1, 0x01);   // wake, PLL on gyro X
  delay(10);
  ok &= writeReg(MPU_ADDR, MPU_SMPLRT_DIV, 0x00);       // 1 kHz
  ok &= writeReg(MPU_ADDR, MPU_CONFIG, 0x01);           // DLPF ~188 Hz
  ok &= writeReg(MPU_ADDR, MPU_GYRO_CONFIG, 0x18);      // ±2000 deg/s
  ok &= writeReg(MPU_ADDR, MPU_ACCEL_CONFIG, 0x18);     // ±16 g
  return ok;
}

static bool applyH3Range(uint8_t range) {
  uint8_t fs = (range == 0) ? 0x00 : (range == 1) ? 0x10 : 0x30;
  return writeReg(H3_ADDR, H3_CTRL_REG4, 0x80 | fs);    // BDU + full scale
}

static bool setupH3LIS() {
  uint8_t who = readReg(H3_ADDR, H3_WHO_AM_I);
  Serial.printf("H3LIS331DL WHO_AM_I = 0x%02X (expect 0x32)\n", who);
  if (who != 0x32) return false;
  bool ok = writeReg(H3_ADDR, H3_CTRL_REG1, 0x3F);      // normal mode, 1000 Hz, XYZ on
  ok &= applyH3Range(h3Range);
  return ok;
}

// ---- 1 kHz sampling task ----
static void samplerTask(void *) {
  TBPacket pkt = {};
  uint16_t seq = 0;
  uint8_t n = 0;
  uint8_t mpu[14], h3[6];
  TickType_t last = xTaskGetTickCount();

  for (;;) {
    vTaskDelayUntil(&last, pdMS_TO_TICKS(1));

    if (h3RangeDirty) {
      if (h3Ok) applyH3Range(h3Range);
      h3RangeDirty = false;
    }

    TBSample s = {};
    uint32_t t = micros();
    if (mpuOk && readRegs(MPU_ADDR, MPU_ACCEL_XOUT_H, mpu, 14)) {
      s.ax = (int16_t)(mpu[0] << 8 | mpu[1]);
      s.ay = (int16_t)(mpu[2] << 8 | mpu[3]);
      s.az = (int16_t)(mpu[4] << 8 | mpu[5]);
      s.gx = (int16_t)(mpu[8] << 8 | mpu[9]);
      s.gy = (int16_t)(mpu[10] << 8 | mpu[11]);
      s.gz = (int16_t)(mpu[12] << 8 | mpu[13]);
    } else if (mpuOk) {
      i2cErrors++;
    }
    if (h3Ok && readRegs(H3_ADDR, H3_OUT_X_L | H3_AUTO_INC, h3, 6)) {
      s.hx = (int16_t)(h3[1] << 8 | h3[0]);
      s.hy = (int16_t)(h3[3] << 8 | h3[2]);
      s.hz = (int16_t)(h3[5] << 8 | h3[4]);
    } else if (h3Ok) {
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
      pkt.flags = (mpuOk ? TB_FLAG_MPU_OK : 0) | (h3Ok ? TB_FLAG_H3LIS_OK : 0) | TB_FLAG_STREAMING;
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
  }
  void onDisconnect(NimBLEServer *) override {
    Serial.println("BLE: disconnected, advertising again");
    xQueueReset(packetQueue);
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
          h3RangeDirty = true;
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
  st.flags = (mpuOk ? TB_FLAG_MPU_OK : 0) | (h3Ok ? TB_FLAG_H3LIS_OK : 0) | (streaming ? TB_FLAG_STREAMING : 0);
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
  mpuOk = setupMPU();
  h3Ok = setupH3LIS();
  Serial.printf("MPU6050: %s   H3LIS331DL: %s\n", mpuOk ? "OK" : "NOT FOUND", h3Ok ? "OK" : "NOT FOUND");
  if (!mpuOk || !h3Ok) Serial.println("Check wiring: SDA=D9, SCL=D10, VCC=3V3, GND=GND (see docs/WIRING.md)");

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

  static uint32_t lastStatus = 0, lastSamples = 0;
  uint32_t now = millis();
  if (now - lastStatus >= 1000) {
    TBStatus st = makeStatus();
    statusChar->setValue((uint8_t *)&st, sizeof(st));
    if (server->getConnectedCount() > 0) statusChar->notify();

    uint32_t rate = samplesRead - lastSamples;
    lastSamples = samplesRead;
    lastStatus = now;
    TBSample s = lastSample;
    float h3Scale = (h3Range == 0) ? 0.049f : (h3Range == 1) ? 0.098f : 0.195f;
    Serial.printf(
        "rate %4lu Hz | MPU a[g] %6.2f %6.2f %6.2f  g[dps] %7.1f %7.1f %7.1f | H3LIS a[g] %6.1f %6.1f %6.1f | "
        "BLE %s, dropped %u, i2c err %lu | bat %u mV\n",
        (unsigned long)rate, s.ax / 2048.0f, s.ay / 2048.0f, s.az / 2048.0f, s.gx / 16.4f, s.gy / 16.4f,
        s.gz / 16.4f, (s.hx >> 4) * h3Scale, (s.hy >> 4) * h3Scale, (s.hz >> 4) * h3Scale,
        server->getConnectedCount() ? "connected" : "advertising", droppedPackets, (unsigned long)i2cErrors,
        st.battery_mv);
  }
}
