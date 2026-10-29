#include "tap.h"

#include <math.h>
#include <string.h>

// ---- Tuning ----
static int32_t cfg_trig_mg = 300;
static int cfg_max_len = 90;          // ~17 ms at 5.3 kHz: a tap's ring-down is over well inside this
static uint32_t cfg_refractory_us = 200000;
static uint8_t cfg_base_shift = 7;    // 2^7 samples (~128 ms at 1 kHz): follows posture, not a ~10 ms tap

static int32_t ring[TAP_WINDOW][3];
static int w = 0;
// Running per-axis baseline in mg << 8 (the fraction keeps it moving on small changes). The trigger is the
// distance of the accel vector from it: a knock across gravity barely changes |a| but moves the vector.
static int32_t baseq[3] = {0, 0, 1000 << 8};
static int32_t peakDev = 0;      // largest deviation seen while the current tap is open, mg
static int32_t peakVec[3] = {0, 0, 0};   // the deviation vector at that peak
static volatile int32_t livePeak = 0;    // largest deviation since tapPeakDeviation() was last called

int32_t tapPeakDeviation() {
  int32_t p = livePeak;
  livePeak = 0;
  return p;
}
static uint32_t lastTapUs = 0;
static bool first = true;
static int lag = 0;              // samples between the trigger and the end of the jolt
static int32_t win[TAP_WINDOW][3];
static uint32_t trigUs = 0;
static int32_t win_jolt = 0;     // peak |a| above baseline in the last completed window, mg

const char *const TAP_ZONE_NAMES[TAP_N_ZONES + 1] = {"unknown", "butt", "grip_60", "grip_120", "grip_180",
                                                      "throat"};

static int32_t isqrt32(int32_t v) {
  if (v <= 0) return 0;
  int32_t r = (int32_t)sqrtf((float)v);   // the C3 has no FPU, but sqrtf is a fast ROM call
  while ((r + 1) * (r + 1) <= v) r++;
  while (r * r > v) r--;
  return r;
}

static int32_t magOf(const int32_t *s) { return isqrt32(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]); }

void tapInit() {
  memset(ring, 0, sizeof(ring));
  w = 0;
  first = true;
  lag = 0;
}

void tapConfigure(int32_t trig_mg, int max_len, uint32_t refractory_ms) {
  if (trig_mg > 0) cfg_trig_mg = trig_mg;
  if (max_len > 4 && max_len <= TAP_PRE) cfg_max_len = max_len;
  if (refractory_ms > 0) cfg_refractory_us = refractory_ms * 1000;
}

// One pass over the window. Mirrors tools/fit_tap_model.py feature for feature.
// Returns the peak |a| above the pre-tap baseline (mg); the quantised vector goes to `out`.
static int32_t features(const int32_t (*w3)[3], int n_after, uint8_t *out) {
  const int span = n_after < TAP_WINDOW - TAP_PRE ? n_after : TAP_WINDOW - TAP_PRE;

  int32_t sum = 0;
  for (int i = 0; i < TAP_PRE; i++) sum += magOf(w3[i]);
  const int32_t b = sum / TAP_PRE;

  int32_t pk[3] = {0, 0, 0}, smag = b, step = 0, prev = b;
  int idx[3] = {0, 0, 0};
  for (int i = 0; i < span; i++) {
    const int32_t *s = w3[TAP_PRE + i];
    const int32_t m = magOf(s);
    if (m > smag) smag = m;
    int32_t d = m - prev;
    if (d > step) step = d;
    if (d < -step) step = -d;
    prev = m;
    for (int a = 0; a < 3; a++) {
      int32_t v = s[a];
      if (v > pk[a]) { pk[a] = v; idx[a] = i; }
      if (-v > pk[a]) { pk[a] = -v; idx[a] = i; }
    }
  }

  int32_t lead = pk[0];
  if (pk[1] > lead) lead = pk[1];
  if (pk[2] > lead) lead = pk[2];

  const int32_t quarter = b + (smag - b) / 4;
  int decay = 0;
  for (int i = 0; i < span; i++)
    if (magOf(w3[TAP_PRE + i]) > quarter) decay = i + 1;

  int zc = 0, above = 0;
  for (int i = 0; i < span; i++) {
    int now = magOf(w3[TAP_PRE + i]) > b + 40 ? 1 : 0;
    if (now != above) zc++;
    above = now;
  }

  int32_t e[3] = {0, 0, 0};
  for (int i = 0; i < span; i++)
    for (int a = 0; a < 3; a++) e[a] += w3[TAP_PRE + i][a] * w3[TAP_PRE + i][a];
  const int32_t etot = e[0] + e[1] + e[2] + 1;

  int peak_i = idx[0];
  if (idx[1] > peak_i) peak_i = idx[1];
  if (idx[2] > peak_i) peak_i = idx[2];

  const int32_t jolt = smag - b;
  out[0] = (uint8_t)(jolt > 2047 ? 255 : (jolt > 0 ? jolt * 255 / 2048 : 0));
  out[1] = (uint8_t)(lead > 1023 ? 255 : (lead > 0 ? lead * 255 / 1024 : 0));
  out[2] = (uint8_t)(step > 255 ? 255 : step);
  out[3] = (uint8_t)(decay * 255 / 64);
  out[4] = (uint8_t)(zc > 63 ? 63 : zc);
  out[5] = (uint8_t)((e[0] * 255) / etot);
  out[6] = (uint8_t)((e[1] * 255) / etot);
  out[7] = (uint8_t)((e[2] * 255) / etot);
  out[8] = (uint8_t)(peak_i * 255 / (span > 0 ? span : 1));
  out[9] = (uint8_t)(n_after * 255 / (TAP_WINDOW - TAP_PRE));
  return jolt;
}

bool tapPush(int32_t ax, int32_t ay, int32_t az, uint32_t t_us, TapResult &out) {
  ring[w][0] = ax;
  ring[w][1] = ay;
  ring[w][2] = az;
  w = (w + 1) % TAP_WINDOW;

  if (first) {
    for (int a = 0; a < 3; a++) baseq[a] = ring[(w + TAP_WINDOW - 1) % TAP_WINDOW][a] * 256;   // start at rest
    first = false;
  }
  int32_t d[3];
  for (int a = 0; a < 3; a++) d[a] = ring[(w + TAP_WINDOW - 1) % TAP_WINDOW][a] - (baseq[a] >> 8);
  const int32_t dev = magOf(d);
  if (dev > livePeak) livePeak = dev;

  if (lag > 0) {
    lag++;
    if (dev > peakDev) {
      peakDev = dev;
      memcpy(peakVec, d, sizeof(peakVec));
    }
    const bool quiet = dev < cfg_trig_mg / 3;
    if (!quiet && lag < cfg_max_len) return false;

    // Copy the window oldest-first so the trigger sits at TAP_PRE, where features() expects it. Only
    // TAP_PRE + lag samples are real; the tail is zeroed rather than left holding wrapped-around history.
    const int start = (w - lag - TAP_PRE + 2 * TAP_WINDOW) % TAP_WINDOW;
    for (int i = 0; i < TAP_WINDOW; i++) {
      if (i < TAP_PRE + lag) memcpy(win[i], ring[(start + i) % TAP_WINDOW], sizeof(win[i]));
      else memset(win[i], 0, sizeof(win[i]));
    }

    uint8_t f[TAP_N_FEATURES];
    win_jolt = features(win, lag, f);
    out.t_us = trigUs;
    out.jolt_mg = peakDev;
    out.strength = (uint8_t)(peakDev > 2047 ? 255 : peakDev * 255 / 2048);
    out.rate_hz = 0;
    memcpy(out.dir_mg, peakVec, sizeof(peakVec));
    memcpy(out.features, f, sizeof(f));
    tapClassify(f, &out.zone, &out.confidence);
    lag = 0;
    lastTapUs = t_us;
    return true;
  }

  // The baseline is frozen while a tap is open so the jolt doesn't drag it along.
  for (int a = 0; a < 3; a++) baseq[a] += ((ring[(w + TAP_WINDOW - 1) % TAP_WINDOW][a] * 256) - baseq[a]) >> cfg_base_shift;
  if (dev > cfg_trig_mg && (t_us - lastTapUs) > cfg_refractory_us) {
    lag = 1;
    peakDev = dev;
    memcpy(peakVec, d, sizeof(peakVec));
    trigUs = t_us;
  }
  return false;
}

void tapWindow(int32_t *out_xyz) {
  for (int i = 0; i < TAP_WINDOW; i++)
    for (int a = 0; a < 3; a++) out_xyz[i * 3 + a] = win[i][a];
}
