#include "mic.h"

#include <driver/i2s.h>

#include "sweetspot.h"

// INMP441 wiring (docs/PLAN.md): SCK=D6/GPIO21, WS=D7/GPIO20, SD=D10/GPIO10, L/R tied to GND (left slot).
static const int PIN_SCK = 21, PIN_WS = 20, PIN_SD = 10;
static const i2s_port_t PORT = I2S_NUM_0;

// Trigger tuning. Samples are int16 (top 16 bits of the mic's 24).
static const int TRIG_MIN = 1500;          // never trigger below this absolute level
static const float TRIG_RATIO = 8.0f;      // ... or below this many times the running noise floor
static const uint32_t REFRACTORY_MS = 250; // ignore ringing / double detections

static QueueHandle_t outQueue;
static volatile bool collect = false;
static volatile uint32_t impacts = 0;

void micSetCollect(bool on) { collect = on; }
bool micCollecting() { return collect; }
uint32_t micImpactCount() { return impacts; }

static void printClip(const int16_t *clip) {
  Serial.print("CLIP,");
  for (int i = 0; i < SS_CLIP_SAMPLES; i++) Serial.printf("%04x", (uint16_t)clip[i]);
  Serial.println();
}

static void micTask(void *) {
  static int16_t clip[SS_CLIP_SAMPLES];
  static int16_t pre[SS_PRE_SAMPLES];       // ring buffer of the most recent samples
  int32_t raw[64];
  int preHead = 0;
  float floorAbs = 200;                     // running mean |x| (noise floor)
  int capturing = -1;                       // -1 idle, else number of clip samples filled
  uint32_t lastImpact = 0;
  uint16_t seq = 0;

  for (;;) {
    size_t bytes = 0;
    i2s_read(PORT, raw, sizeof(raw), &bytes, portMAX_DELAY);
    int n = bytes / sizeof(int32_t);
    for (int k = 0; k < n; k++) {
      int16_t s = (int16_t)(raw[k] >> 16);  // INMP441: 24-bit MSB-first in a 32-bit slot
      if (capturing >= 0) {
        clip[capturing++] = s;
        if (capturing == SS_CLIP_SAMPLES) {
          capturing = -1;
          lastImpact = millis();
          uint32_t t0 = micros();
          SweetSpotResult r = ss_classify(clip);
          uint32_t dt = micros() - t0;
          int peak = 0;
          for (int i = 0; i < SS_CLIP_SAMPLES; i++) peak = max(peak, abs((int)clip[i]));
          TBShot shot = {seq++, (uint8_t)r.sweet, r.off_pct, r.confidence, (uint8_t)min(255, peak / 128)};
          impacts++;
          xQueueSend(outQueue, &shot, 0);
          Serial.printf("SHOT %s off=%u%% conf=%u%% p=%.2f peak=%d inference=%luus\n", r.sweet ? "SWEET" : "off-centre",
                        r.off_pct, r.confidence, r.p_sweet, peak, (unsigned long)dt);
          if (collect) printClip(clip);
        }
        continue;
      }
      bool refractory = millis() - lastImpact < REFRACTORY_MS;
      float thresh = max((float)TRIG_MIN, TRIG_RATIO * floorAbs);
      if (!refractory && abs((int)s) > thresh) {
        // Start the clip with the buffered pre-trigger samples, then this sample is the onset.
        for (int i = 0; i < SS_PRE_SAMPLES; i++) clip[i] = pre[(preHead + i) % SS_PRE_SAMPLES];
        clip[SS_PRE_SAMPLES] = s;
        capturing = SS_PRE_SAMPLES + 1;
      } else {
        floorAbs += 0.001f * (abs((int)s) - floorAbs);
      }
      pre[preHead] = s;
      preHead = (preHead + 1) % SS_PRE_SAMPLES;
    }
  }
}

bool micBegin(QueueHandle_t out) {
  outQueue = out;
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX);
  cfg.sample_rate = SS_SAMPLE_RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_ONLY_LEFT;
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
  cfg.dma_buf_count = 6;
  cfg.dma_buf_len = 64;
  cfg.use_apll = false;
  i2s_pin_config_t pins = {};
  pins.mck_io_num = I2S_PIN_NO_CHANGE;
  pins.bck_io_num = PIN_SCK;
  pins.ws_io_num = PIN_WS;
  pins.data_out_num = I2S_PIN_NO_CHANGE;
  pins.data_in_num = PIN_SD;
  if (i2s_driver_install(PORT, &cfg, 0, nullptr) != ESP_OK) return false;
  if (i2s_set_pin(PORT, &pins) != ESP_OK) return false;
  // Priority below the 1 kHz IMU sampler so inference (~ms) never delays IMU reads.
  xTaskCreate(micTask, "mic", 6144, nullptr, 3, nullptr);
  return true;
}
