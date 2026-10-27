// INMP441 bring-up helper: reads I2S on the mic pins and reports per-slot levels once a second.
// A live mic shows a non-zero, changing noise floor that jumps when you clap; a missing mic reads all zeros
// (SD is pulled down). Flash with: pio run -e micprobe -t upload   (then reflash: pio run -t upload)
#include <Arduino.h>
#include <driver/gpio.h>
#include <driver/i2s.h>

static const int PIN_SCK = 3, PIN_WS = 4, PIN_SD = 5;   // D1/D2/D3, as in src/mic.cpp
static const i2s_port_t PORT = I2S_NUM_0;

void setup() {
  Serial.begin(115200);
  delay(1500);
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX);
  cfg.sample_rate = 16000;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;      // both slots, to catch a mis-tied L/R pin
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.dma_buf_count = 6;
  cfg.dma_buf_len = 64;
  i2s_pin_config_t pins = {};
  pins.mck_io_num = I2S_PIN_NO_CHANGE;
  pins.bck_io_num = PIN_SCK;
  pins.ws_io_num = PIN_WS;
  pins.data_out_num = I2S_PIN_NO_CHANGE;
  pins.data_in_num = PIN_SD;
  esp_err_t e1 = i2s_driver_install(PORT, &cfg, 0, nullptr);
  esp_err_t e2 = i2s_set_pin(PORT, &pins);
  gpio_pulldown_en((gpio_num_t)PIN_SD);
  Serial.printf("\n=== INMP441 probe: SCK=D1 WS=D2 SD=D3, install=%d set_pin=%d ===\n", e1, e2);
}

void loop() {
  static int32_t raw[256];
  int64_t sum[2] = {0, 0}, sq[2] = {0, 0};
  int32_t mn[2] = {INT32_MAX, INT32_MAX}, mx[2] = {INT32_MIN, INT32_MIN};
  uint32_t n[2] = {0, 0}, zeros[2] = {0, 0};
  uint32_t t0 = millis();
  while (millis() - t0 < 1000) {
    size_t bytes = 0;
    i2s_read(PORT, raw, sizeof(raw), &bytes, portMAX_DELAY);
    for (size_t k = 0; k < bytes / sizeof(int32_t); k++) {
      int c = k & 1;
      int32_t s = raw[k] >> 16;   // top 16 of the 24-bit sample
      if (raw[k] == 0) zeros[c]++;
      sum[c] += s; sq[c] += (int64_t)s * s; n[c]++;
      mn[c] = min(mn[c], s); mx[c] = max(mx[c], s);
    }
  }
  for (int c = 0; c < 2; c++) {
    float mean = n[c] ? (float)sum[c] / n[c] : 0;
    float rms = n[c] ? sqrtf((float)sq[c] / n[c] - mean * mean) : 0;
    Serial.printf("slot%d n=%lu min=%ld max=%ld mean=%.0f rms=%.1f zeros=%lu%%  ", c, (unsigned long)n[c], (long)mn[c],
                  (long)mx[c], mean, rms, (unsigned long)(n[c] ? zeros[c] * 100 / n[c] : 0));
  }
  bool live = (mx[0] != mn[0]) || (mx[1] != mn[1]);
  Serial.println(live ? "-> MIC DETECTED" : "-> no signal (mic missing / SD or SCK not connected)");
}
