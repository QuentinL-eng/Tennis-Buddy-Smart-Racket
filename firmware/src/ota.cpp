#include "ota.h"

#include <Arduino.h>
#include <Update.h>
#include <esp_ota_ops.h>
#include "protocol.h"

// A newly installed image must run this long before it is confirmed; a crash or reset sooner rolls back.
static const uint32_t CONFIRM_AFTER_MS = 10000;
static const uint16_t NO_CONN = 0xFFFF;

static NimBLECharacteristic *controlChar;
static volatile bool active = false;
static uint16_t updaterConn = NO_CONN;
static uint32_t expectedSize = 0, expectedCrc = 0, received = 0, crc = 0;
static uint32_t rebootAt = 0;

// The Arduino core confirms a new image as soon as it boots unless this returns true; we confirm it
// ourselves in otaLoop() once it has proven it runs.
extern "C" bool verifyRollbackLater() { return true; }

// Standard CRC-32 (as zlib), chainable from 0; matches FirmwareImage.crc32 in the apps.
static uint32_t crc32Update(uint32_t c, const uint8_t *p, size_t n) {
  c = ~c;
  while (n--) {
    c ^= *p++;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
  }
  return ~c;
}

static void reply(const uint8_t *data, size_t len) {
  controlChar->setValue(data, len);
  controlChar->notify();
}

static void replyCode(uint8_t code) { reply(&code, 1); }

static void replyProgress() {
  uint8_t msg[5] = {TB_OTA_PROGRESS, (uint8_t)received, (uint8_t)(received >> 8), (uint8_t)(received >> 16),
                    (uint8_t)(received >> 24)};
  reply(msg, sizeof(msg));
}

static void fail(uint8_t err) {
  if (Update.isRunning()) Update.abort();
  active = false;
  updaterConn = NO_CONN;
  Serial.printf("OTA: failed, error %u\n", err);
  uint8_t msg[2] = {TB_OTA_ERROR, err};
  reply(msg, sizeof(msg));
}

static uint32_t le32(const std::string &v, size_t at) {
  return (uint8_t)v[at] | (uint8_t)v[at + 1] << 8 | (uint8_t)v[at + 2] << 16 | (uint32_t)(uint8_t)v[at + 3] << 24;
}

class OtaControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, ble_gap_conn_desc *desc) override {
    std::string v = c->getValue();
    if (v.empty()) return;
    Serial.printf("OTA: command 0x%02X (%u bytes) from connection %u\n", (uint8_t)v[0], (unsigned)v.size(),
                  desc->conn_handle);
    // Another device (say the Mac app) is already updating: leave its transfer alone. Replies go to every
    // subscriber, so answering here would cancel the update in progress on the other device.
    if (active && desc->conn_handle != updaterConn) return;
    switch ((uint8_t)v[0]) {
      case TB_OTA_BEGIN:
        if (v.size() < 9) return fail(TB_OTA_ERR_STATE);
        if (Update.isRunning()) Update.abort();
        expectedSize = le32(v, 1);
        expectedCrc = le32(v, 5);
        received = 0;
        crc = 0;
        if (!Update.begin(expectedSize, U_FLASH)) return fail(TB_OTA_ERR_BEGIN);
        active = true;
        updaterConn = desc->conn_handle;
        Serial.printf("OTA: receiving %lu bytes\n", (unsigned long)expectedSize);
        replyCode(TB_OTA_READY);
        break;
      case TB_OTA_END:
        if (!active) return fail(TB_OTA_ERR_STATE);
        if (received != expectedSize) return fail(TB_OTA_ERR_SIZE);
        if (crc != expectedCrc) return fail(TB_OTA_ERR_CRC);
        // Checks the image header and its appended SHA-256, then points the bootloader at it.
        if (!Update.end()) return fail(TB_OTA_ERR_IMAGE);
        active = false;
        Serial.println("OTA: image verified, rebooting");
        replyCode(TB_OTA_DONE);
        rebootAt = millis() + 500;   // let the DONE notification go out first
        break;
      case TB_OTA_ABORT:
        if (active) {
          Update.abort();
          active = false;
          updaterConn = NO_CONN;
          Serial.println("OTA: aborted by app");
        }
        break;
    }
  }
};

class OtaDataCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, ble_gap_conn_desc *desc) override {
    if (!active || desc->conn_handle != updaterConn) return;
    std::string v = c->getValue();
    if (v.empty()) return;
    if (received + v.size() > expectedSize) return fail(TB_OTA_ERR_SIZE);
    // The app stops at each window boundary until we ack, so this flash write (and any sector erase)
    // never has more data arriving behind it.
    if (Update.write((uint8_t *)v.data(), v.size()) != v.size()) return fail(TB_OTA_ERR_WRITE);
    crc = crc32Update(crc, (const uint8_t *)v.data(), v.size());
    received += v.size();
    if (received % TB_OTA_WINDOW == 0 || received == expectedSize) replyProgress();
  }
};

void otaSetup(NimBLEService *svc) {
  controlChar = svc->createCharacteristic(TB_OTA_CONTROL_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY);
  controlChar->setCallbacks(new OtaControlCallbacks());
  NimBLECharacteristic *data = svc->createCharacteristic(TB_OTA_DATA_UUID, NIMBLE_PROPERTY::WRITE_NR);
  data->setCallbacks(new OtaDataCallbacks());
}

bool otaActive() { return active; }

void otaHandleDisconnect(uint16_t connHandle) {
  if (!active || connHandle != updaterConn) return;
  Update.abort();
  active = false;
  updaterConn = NO_CONN;
  Serial.println("OTA: updating device disconnected, update abandoned");
}

void otaLoop() {
  if (rebootAt && (int32_t)(millis() - rebootAt) >= 0) ESP.restart();

  static bool confirmed = false;
  if (!confirmed && millis() >= CONFIRM_AFTER_MS) {
    confirmed = true;
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(esp_ota_get_running_partition(), &state) == ESP_OK &&
        state == ESP_OTA_IMG_PENDING_VERIFY) {
      esp_ota_mark_app_valid_cancel_rollback();
      Serial.println("OTA: new firmware confirmed");
    }
  }
}
