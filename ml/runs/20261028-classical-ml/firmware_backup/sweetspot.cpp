#include "sweetspot.h"

#include <math.h>
#include <string.h>

#include "sweetspot_model.h"

static const int N = SS_CLIP_SAMPLES;
static const int BLOCK = 16, NBLK = N / BLOCK;
static const int N_BANDS = 8;
static const float BAND_HZ[N_BANDS] = {250, 500, 800, 1200, 1800, 2600, 3800, 5500};
static const float SWEET_RADIUS_PCT = 100.0f * 4.0f / 12.0f;  // matches ml/synth.py

void ss_features(const int16_t *clip, float *out) {
  static float x[SS_CLIP_SAMPLES];  // static: keeps ~2 KB off the small task stack
  float sum = 0;
  for (int i = 0; i < N; i++) sum += clip[i];
  const float mean = sum / N;
  float sumsq = 0, peak = 0;
  for (int i = 0; i < N; i++) {
    x[i] = clip[i] - mean;
    sumsq += x[i] * x[i];
    float a = fabsf(x[i]);
    if (a > peak) peak = a;
  }

  // 8 Goertzel bands, energy relative to the total (so loudness cancels out).
  for (int b = 0; b < N_BANDS; b++) {
    const float coeff = 2.0f * cosf(2.0f * (float)M_PI * BAND_HZ[b] / SS_SAMPLE_RATE);
    float s1 = 0, s2 = 0;
    for (int i = 0; i < N; i++) {
      float s0 = x[i] + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    float p = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    float r = p / ((float)N * sumsq + 1.0f);
    out[b] = log10f((r > 0 ? r : 0) + 1e-6f);
  }

  // 1 ms rectified envelope: how long does the sound ring?
  float env[NBLK], envSum = 0;
  int pk = 0;
  for (int b = 0; b < NBLK; b++) {
    float e = 0;
    for (int i = 0; i < BLOCK; i++) e += fabsf(x[b * BLOCK + i]);
    env[b] = e;
    envSum += e;
    if (e > env[pk]) pk = b;
  }
  int decay = NBLK - pk;
  for (int b = pk; b < NBLK; b++)
    if (env[b] < 0.25f * env[pk]) { decay = b - pk; break; }
  out[8] = (float)decay / NBLK;

  float early = 0;
  for (int b = 4; b < 12; b++) early += env[b];
  out[9] = early / (envSum + 1.0f);

  int crossings = 0;
  for (int i = 1; i < N; i++)
    if ((x[i] >= 0) != (x[i - 1] >= 0)) crossings++;
  out[10] = (float)crossings / (N - 1);

  const float rms = sqrtf(sumsq / N);
  out[11] = log10f(peak / (rms + 1.0f) + 1e-6f);
}

// y = act(scale * (in . W) + b), W is int8 row-major [in][out]
static void dense(const float *in, int nin, const int8_t *w, float scale, const float *b, float *out, int nout,
                  bool relu) {
  for (int o = 0; o < nout; o++) {
    float acc = 0;
    for (int i = 0; i < nin; i++) acc += in[i] * (float)w[i * nout + o];
    acc = acc * scale + b[o];
    out[o] = (relu && acc < 0) ? 0 : acc;
  }
}

SweetSpotResult ss_infer_features(const float *f) {
  float x[SS_N_FEATURES], h1[SS_H1], h2[SS_H2], o[2];
  for (int i = 0; i < SS_N_FEATURES; i++) x[i] = (f[i] - SS_MEAN[i]) / SS_STD[i];
  dense(x, SS_N_FEATURES, SS_W1, SS_S1, SS_B1, h1, SS_H1, true);
  dense(h1, SS_H1, SS_W2, SS_S2, SS_B2, h2, SS_H2, true);
  dense(h2, SS_H2, SS_W3, SS_S3, SS_B3, o, 2, false);

  SweetSpotResult r;
  r.p_sweet = 1.0f / (1.0f + expf(-o[0]));
  r.sweet = r.p_sweet > 0.5f;
  float conf = (r.sweet ? r.p_sweet : 1.0f - r.p_sweet);   // 0.5..1
  r.confidence = (uint8_t)(100.0f * conf + 0.5f);
  float pct = 100.0f * o[1];
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  if (r.sweet) pct = 0;
  else if (pct < SWEET_RADIUS_PCT) pct = SWEET_RADIUS_PCT;   // "not sweet" can't be inside the sweet disc
  r.off_pct = (uint8_t)(pct + 0.5f);
  return r;
}

SweetSpotResult ss_classify(const int16_t *clip) {
  float f[SS_N_FEATURES];
  ss_features(clip, f);
  return ss_infer_features(f);
}
