// INMP441 pin finder: tries every SCK/WS/SD assignment over the XIAO pins and reports which ones give live audio.
// D1/D2/D3 orderings are tried first, then every other combination. Afterwards it streams levels on the best hit
// so you can clap and watch it react.
// Flash with: pio run -e micscan -t upload   (then reflash the main firmware with: pio run -t upload)
#include <Arduino.h>
#include <driver/gpio.h>
#include <driver/i2s.h>

static const int pins[] = {2, 3, 4, 5, 6, 7, 21, 20, 8, 9, 10};   // D0-D10
static const char *names[] = {"D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7", "D8", "D9", "D10"};
static const int NPINS = 11;
static const i2s_port_t PORT = I2S_NUM_0;

struct Level {
  float rms[2];
  uint32_t changes[2], n[2];
  bool live(int c) const { return n[c] && rms[c] > 2.0f && changes[c] > n[c] / 4; }
};

static void stopI2S(int sck, int ws, int sd) {
  i2s_driver_uninstall(PORT);
  for (int p : {sck, ws, sd}) gpio_reset_pin((gpio_num_t)p);
}

static bool startI2S(int sck, int ws, int sd) {
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX);
  cfg.sample_rate = 16000;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;   // both slots: L/R may be tied either way
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.dma_buf_count = 4;
  cfg.dma_buf_len = 64;
  i2s_pin_config_t pc = {};
  pc.mck_io_num = I2S_PIN_NO_CHANGE;
  pc.bck_io_num = sck;
  pc.ws_io_num = ws;
  pc.data_out_num = I2S_PIN_NO_CHANGE;
  pc.data_in_num = sd;
  if (i2s_driver_install(PORT, &cfg, 0, nullptr) != ESP_OK) return false;
  if (i2s_set_pin(PORT, &pc) != ESP_OK) { i2s_driver_uninstall(PORT); return false; }
  gpio_pulldown_en((gpio_num_t)sd);   // an unconnected SD then reads as solid zeros
  return true;
}

// Reads `ms` of audio after discarding the mic's power-up settling time.
static Level measure(uint32_t settleMs, uint32_t ms) {
  static int32_t raw[128];
  Level L = {};
  int64_t sum[2] = {0, 0}, sq[2] = {0, 0};
  int32_t prev[2] = {0, 0};
  size_t bytes;
  uint32_t t0 = millis();
  while (millis() - t0 < settleMs) i2s_read(PORT, raw, sizeof(raw), &bytes, pdMS_TO_TICKS(50));
  t0 = millis();
  while (millis() - t0 < ms) {
    bytes = 0;
    i2s_read(PORT, raw, sizeof(raw), &bytes, pdMS_TO_TICKS(50));
    for (size_t k = 0; k < bytes / sizeof(int32_t); k++) {
      int c = k & 1;
      int32_t s = raw[k] >> 16;
      if (s != prev[c]) L.changes[c]++;
      prev[c] = s;
      sum[c] += s; sq[c] += (int64_t)s * s; L.n[c]++;
    }
  }
  for (int c = 0; c < 2; c++) {
    float mean = L.n[c] ? (float)sum[c] / L.n[c] : 0;
    L.rms[c] = L.n[c] ? sqrtf(fmaxf(0, (float)sq[c] / L.n[c] - mean * mean)) : 0;
  }
  return L;
}

static int best[3] = {-1, -1, -1};
static float bestRms = 0;

static void tryCombo(int a, int b, int c, bool verbose) {
  if (!startI2S(pins[a], pins[b], pins[c])) {
    if (verbose) Serial.printf("SCK=%s WS=%s SD=%s: I2S setup failed\n", names[a], names[b], names[c]);
    return;
  }
  Level L = measure(120, 150);
  stopI2S(pins[a], pins[b], pins[c]);
  bool live = L.live(0) || L.live(1);
  if (verbose || live) {
    Serial.printf("%sSCK=%-3s WS=%-3s SD=%-3s  left rms=%7.1f chg=%3lu%%  right rms=%7.1f chg=%3lu%%%s\n",
                  verbose ? "" : "\n", names[a], names[b], names[c], L.rms[0],
                  (unsigned long)(L.n[0] ? L.changes[0] * 100 / L.n[0] : 0), L.rms[1],
                  (unsigned long)(L.n[1] ? L.changes[1] * 100 / L.n[1] : 0),
                  live ? (L.live(0) ? "  <- MIC (left slot, L/R=GND)" : "  <- MIC (right slot, L/R=3V3)") : "");
  }
  if (live) {
    float r = max(L.live(0) ? L.rms[0] : 0, L.live(1) ? L.rms[1] : 0);
    if (best[0] < 0 || r > bestRms) { best[0] = a; best[1] = b; best[2] = c; bestRms = r; }
  }
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n=== INMP441 pin scan ===");
  Serial.println("-- D1/D2/D3, every ordering --");
  const int d123[3] = {1, 2, 3};
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      for (int k = 0; k < 3; k++)
        if (i != j && j != k && i != k) tryCombo(d123[i], d123[j], d123[k], true);

  Serial.println("-- every other combination of D0-D10 (dot = 11 combos, live hits printed) --");
  uint32_t tried = 0;
  for (int a = 0; a < NPINS; a++)
    for (int b = 0; b < NPINS; b++)
      for (int c = 0; c < NPINS; c++) {
        if (a == b || b == c || a == c) continue;
        if (a >= 1 && a <= 3 && b >= 1 && b <= 3 && c >= 1 && c <= 3) continue;   // done above
        tryCombo(a, b, c, false);
        if (++tried % 11 == 0) Serial.print(".");
      }
  Serial.println();

  if (best[0] < 0) {
    Serial.println("RESULT: no live mic on any pin combination. Check the mic's VDD=3V3 and GND.");
  } else {
    Serial.printf("RESULT: mic found at SCK=%s WS=%s SD=%s. Streaming its level now: clap to see it jump.\n",
                  names[best[0]], names[best[1]], names[best[2]]);
    startI2S(pins[best[0]], pins[best[1]], pins[best[2]]);
  }
}

void loop() {
  if (best[0] < 0) { delay(1000); return; }
  Level L = measure(0, 500);
  Serial.printf("SCK=%s WS=%s SD=%s  left rms=%7.1f  right rms=%7.1f\n", names[best[0]], names[best[1]],
                names[best[2]], L.rms[0], L.rms[1]);
}
