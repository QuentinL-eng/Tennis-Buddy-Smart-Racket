#include "mic.h"

#include <driver/i2s.h>

#include "sweetspot.h"

// INMP441 wiring as built (docs/WIRING.md): SCK=D1/GPIO3, WS=D2/GPIO4, SD=D3/GPIO5, L/R tied to GND (left slot).
static const int PIN_SCK = 3, PIN_WS = 4, PIN_SD = 5;
static const i2s_port_t PORT = I2S_NUM_0;

// Trigger tuning. Samples are int16 (top 16 bits of the mic's 24).
static const int TRIG_MIN = 1500;          // never trigger below this absolute level
static const float TRIG_RATIO = 8.0f;      // ... or below this many times the running noise floor
static const uint32_t REFRACTORY_MS = 250; // ignore ringing / double detections
static const uint32_t STARTUP_MS = 1500;   // ignore the mic's power-up transient
// Collection only: retain 128 ms after the last near-full-scale sample,
// bounded to 1 s after the trigger. Keep the deployed model's 512-sample input.
static const int CLIP_LEVEL = 30000;
static const int TAIL_SAMPLES = SS_SAMPLE_RATE * 128 / 1000;
static const int MAX_COLLECT_SAMPLES = SS_PRE_SAMPLES + SS_SAMPLE_RATE;
static uint32_t startedAt = 0;

static QueueHandle_t outQueue;
static volatile bool collect = false;
static volatile uint32_t impacts = 0;
static volatile uint32_t lastTriggerUs = 0;
static volatile float levelFloor = 0;   // running mean |x|, published by the mic task
static volatile int levelPeak = 0;      // max |x| since the last micLevel() call

void micSetCollect(bool on) { collect = on; }
bool micCollecting() { return collect; }
uint32_t micImpactCount() { return impacts; }
uint32_t micLastTriggerUs() { return lastTriggerUs; }

MicLevel micLevel() {
  MicLevel l;
  l.floor = (int)levelFloor;
  l.peak = levelPeak;
  levelPeak = 0;
  l.trigger = (int)max((float)TRIG_MIN, TRIG_RATIO * levelFloor);
  return l;
}

static void printClip(const int16_t *clip, int count, uint32_t triggerAt) {
  Serial.printf("CLIP_META,samples=%d,trigger_age_us=%lu\n", count,
                (unsigned long)(micros() - triggerAt));
  Serial.print("CLIP,");
  for (int i = 0; i < count; i++) Serial.printf("%04x", (uint16_t)clip[i]);
  Serial.println();
}

static void micTask(void *) {
  static int16_t clip[MAX_COLLECT_SAMPLES];
  static int16_t pre[SS_PRE_SAMPLES];       // ring buffer of the most recent samples
  int32_t raw[64];
  int preHead = 0;
  float floorAbs = 200;                     // running mean |x| (noise floor)
  int capturing = -1;                       // -1 idle, else number of clip samples filled
  int captureEnd = SS_CLIP_SAMPLES;
  bool captureCollect = false;
  uint32_t triggerAt = 0;
  uint32_t lastImpact = 0;
  uint16_t seq = 0;

  for (;;) {
    size_t bytes = 0;
    i2s_read(PORT, raw, sizeof(raw), &bytes, portMAX_DELAY);
    int n = bytes / sizeof(int32_t);
    for (int k = 0; k < n; k++) {
      int16_t s = (int16_t)(raw[k] >> 16);  // INMP441: 24-bit MSB-first in a 32-bit slot
      if (abs((int)s) > levelPeak) levelPeak = abs((int)s);
      if (capturing >= 0) {
        clip[capturing++] = s;
        if (captureCollect && abs((int)s) >= CLIP_LEVEL)
          captureEnd = min(MAX_COLLECT_SAMPLES, capturing + TAIL_SAMPLES);
        if (capturing >= captureEnd) {
          const int captured = capturing;
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
          Serial.printf("SHOT %s off=%u%% dist=%.2fcm conf=unavailable peak=%d inference=%luus\n", r.sweet ? "SWEET" : "off-centre",
                        r.off_pct, r.distance_cm, peak, (unsigned long)dt);
          if (captureCollect) printClip(clip, captured, triggerAt);
        }
        continue;
      }
      // The INMP441 pops for ~1 s after power-up; treat that like a refractory period so it isn't scored as a hit.
      bool refractory = millis() - lastImpact < REFRACTORY_MS || millis() - startedAt < STARTUP_MS;
      float thresh = max((float)TRIG_MIN, TRIG_RATIO * floorAbs);
      if (!refractory && abs((int)s) > thresh) {
        // Start the clip with the buffered pre-trigger samples, then this sample is the onset.
        for (int i = 0; i < SS_PRE_SAMPLES; i++) clip[i] = pre[(preHead + i) % SS_PRE_SAMPLES];
        clip[SS_PRE_SAMPLES] = s;
        capturing = SS_PRE_SAMPLES + 1;
        captureCollect = collect;
        triggerAt = micros();
        lastTriggerUs = triggerAt ? triggerAt : 1;
        captureEnd = captureCollect ? SS_PRE_SAMPLES + 1 + TAIL_SAMPLES : SS_CLIP_SAMPLES;
      } else {
        floorAbs += 0.001f * (abs((int)s) - floorAbs);
        levelFloor = floorAbs;
      }
      pre[preHead] = s;
      preHead = (preHead + 1) % SS_PRE_SAMPLES;
    }
  }
}

bool micBegin(QueueHandle_t out) {
  if (!ss_self_test()) {
    Serial.println("RIDGE SELF-TEST FAILED: microphone classification disabled");
    return false;
  }
  Serial.println("RIDGE SELF-TEST PASS (8 reviewed clips)");
  outQueue = out;
  startedAt = millis();
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
