#include "impact.h"

#include <math.h>
#include <string.h>

// ---- Detection tuning (the phone's RacketEngine used the same motion rule on the raw stream) ----
static const float JUMP_G = 10.0f;          // high-g change over 3 ms that counts as a ball impact ...
static const float SWING_RADS = 5.0f;       // ... during a swing this fast (within SWING_LOOKBACK)
static const int SWING_LOOKBACK = 150;
// Mic path, for hits too soft or too still for the motion rule (blocked volleys, drop shots): the mic in the
// handle heard a hit, and the high-g accel confirms the racket was struck within MIC_LOOKBACK ms.
static const float MIC_JUMP_G = 3.0f;
static const float MIC_SWING_RADS = 2.0f;   // some racket movement in the last MIC_SWING_LOOKBACK ms, so a
static const int MIC_SWING_LOOKBACK = 300;  // tap on the handle of a still racket isn't counted
static const int MIC_LOOKBACK = 40;
static const uint32_t MIC_MAX_AGE_US = 50000;
static const int REFRACTORY = 400;          // samples between hits
static const int REFINE = 6;                // the impact is placed on the largest jump within ±REFINE

// ---- Orientation (port of MahonyFilter in apple/RacketKit/Sources/RacketKit/Orientation.swift) ----
static const float KP = 2.0f, KI = 0.05f;

static const int RING = 512;   // power of two, > TB_WINDOW_SAMPLES + 2 * REFINE + 4
static_assert(RING >= TB_WINDOW_SAMPLES + 2 * REFINE + 4, "ring too small for a window");

struct Slot {
  TBSample s;
  uint32_t t_us;
  float hg[3];
  float gyroMag;
  float q[4];
};

static Slot ring[RING];
static uint32_t count = 0;   // samples seen; the newest is count - 1
static uint32_t lastT = 0;
static float q[4] = {1, 0, 0, 0}, integral[3] = {0, 0, 0};
static bool qInit = false;
static bool pending = false;
static uint32_t pendingAt = 0, lastImpact = 0;
static uint32_t lastMic = 0;
static uint16_t seq = 0;
static uint32_t hits = 0, windowsDropped = 0;

static inline Slot &at(uint32_t i) { return ring[i & (RING - 1)]; }

void impactReset() {
  count = 0;
  qInit = false;
  q[0] = 1; q[1] = q[2] = q[3] = 0;
  integral[0] = integral[1] = integral[2] = 0;
  pending = false;
  lastImpact = 0;
}

static void normalize(float *v, int n) {
  float s = 0;
  for (int k = 0; k < n; k++) s += v[k] * v[k];
  s = sqrtf(s);
  if (s > 1e-9f)
    for (int k = 0; k < n; k++) v[k] /= s;
}

static void mahony(const float *gyro, const float *accel, float dt) {
  float an = sqrtf(accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2]);
  if (!qInit && an > 0.5f) {
    // Tilt only: the rotation taking the measured "up" to world z.
    float u[3] = {accel[0] / an, accel[1] / an, accel[2] / an};
    if (1 + u[2] < 1e-6f) {
      q[0] = 0; q[1] = 1; q[2] = 0; q[3] = 0;
    } else {
      q[0] = 1 + u[2]; q[1] = u[1]; q[2] = -u[0]; q[3] = 0;
      normalize(q, 4);
    }
    qInit = true;
  }
  float w[3] = {gyro[0], gyro[1], gyro[2]};
  float gn = sqrtf(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
  if (an > 0.85f && an < 1.15f && gn < 3) {
    float a[3] = {accel[0] / an, accel[1] / an, accel[2] / an};
    // World up in body axes: the third row of q's rotation matrix.
    float up[3] = {2 * (q[1] * q[3] - q[0] * q[2]), 2 * (q[2] * q[3] + q[0] * q[1]),
                   1 - 2 * (q[1] * q[1] + q[2] * q[2])};
    float e[3] = {a[1] * up[2] - a[2] * up[1], a[2] * up[0] - a[0] * up[2], a[0] * up[1] - a[1] * up[0]};
    for (int k = 0; k < 3; k++) {
      integral[k] += KI * e[k] * dt;
      w[k] += KP * e[k] + integral[k];
    }
  }
  // q += 0.5 q ⊗ (0, w) dt
  float h = 0.5f * dt;
  float dq0 = -q[1] * w[0] - q[2] * w[1] - q[3] * w[2];
  float dq1 = q[0] * w[0] + q[2] * w[2] - q[3] * w[1];
  float dq2 = q[0] * w[1] - q[1] * w[2] + q[3] * w[0];
  float dq3 = q[0] * w[2] + q[1] * w[1] - q[2] * w[0];
  q[0] += h * dq0; q[1] += h * dq1; q[2] += h * dq2; q[3] += h * dq3;
  normalize(q, 4);
}

// High-g change over 3 samples ending at i.
static float jumpAt(uint32_t i) {
  const Slot &a = at(i), &b = at(i - 3);
  float d0 = a.hg[0] - b.hg[0], d1 = a.hg[1] - b.hg[1], d2 = a.hg[2] - b.hg[2];
  return sqrtf(d0 * d0 + d1 * d1 + d2 * d2);
}

// Fastest rotation in the `span` samples before i.
static float swingBefore(uint32_t i, int span) {
  float m = 0;
  for (int k = 1; k <= span; k++) m = fmaxf(m, at(i - k).gyroMag);
  return m;
}

int16_t impactQuatWire(float v) {
  long x = lroundf(v * 16384);
  return (int16_t)(x > 32767 ? 32767 : x < -32768 ? -32768 : x);
}

static void finishWindow(ImpactWindow *win) {
  uint32_t c = pendingAt, best = c;
  float bestJump = 0;
  for (uint32_t k = c - REFINE; k <= c + REFINE; k++) {
    float j = jumpAt(k);
    if (j > bestJump) { bestJump = j; best = k; }
  }
  uint32_t impact = best - 2;   // the first sample of the jump
  uint32_t start = impact - TB_WINDOW_PRE;
  win->seq = seq - 1;
  win->impact = TB_WINDOW_PRE;
  const Slot &first = at(start);
  for (int k = 0; k < 4; k++) win->q0[k] = impactQuatWire(first.q[k]);
  for (int j = 0; j < TB_WINDOW_SAMPLES; j++) {
    const Slot &sl = at(start + j);
    win->s[j] = sl.s;
    if (j % TB_SAMPLES_PER_PACKET == 0) win->chunkT0[j / TB_SAMPLES_PER_PACKET] = sl.t_us;
  }
}

int impactStep(const ImpactInput &in, uint32_t micTriggerUs, TBHit *hit, ImpactWindow *win) {
  float dt = 0.001f;
  if (count > 0) {
    dt = (in.t_us - lastT) * 1e-6f;
    dt = dt < 0.0002f ? 0.0002f : dt > 0.02f ? 0.02f : dt;
  }
  lastT = in.t_us;
  mahony(in.gyro, in.accel, dt);

  uint32_t i = count++;
  Slot &sl = at(i);
  sl.s = in.wire;
  sl.t_us = in.t_us;
  memcpy(sl.hg, in.highG, sizeof(sl.hg));
  sl.gyroMag = sqrtf(in.gyro[0] * in.gyro[0] + in.gyro[1] * in.gyro[1] + in.gyro[2] * in.gyro[2]);
  memcpy(sl.q, q, sizeof(sl.q));

  bool micNew = micTriggerUs != 0 && micTriggerUs != lastMic;
  if (micNew) lastMic = micTriggerUs;

  int result = 0;
  if (pending) {
    if (i >= pendingAt + REFINE + TB_WINDOW_POST) {
      pending = false;
      if (win) {
        finishWindow(win);
        result |= IMPACT_WINDOW;
      } else {
        windowsDropped++;
      }
    }
    return result;
  }
  if (i < TB_WINDOW_PRE + MIC_SWING_LOOKBACK || i - lastImpact < REFRACTORY) return result;

  uint32_t cand = 0;
  uint8_t source = 0;
  if (jumpAt(i) > JUMP_G && swingBefore(i, SWING_LOOKBACK) > SWING_RADS) {
    cand = i;
    source = TB_HIT_MOTION;
  } else if (micNew && (int32_t)(in.t_us - micTriggerUs) < (int32_t)MIC_MAX_AGE_US &&
             swingBefore(i, MIC_SWING_LOOKBACK) > MIC_SWING_RADS) {
    float best = 0;
    for (uint32_t k = i - MIC_LOOKBACK; k <= i; k++) {
      float j = jumpAt(k);
      if (j > best) { best = j; cand = k; }
    }
    if (best > MIC_JUMP_G) source = TB_HIT_MIC;
  }
  if (!source) return result;

  pending = true;
  pendingAt = cand;
  lastImpact = cand;
  hits++;
  const Slot &c = at(cand);
  float jump = jumpAt(cand);
  hit->seq = seq++;
  hit->t_us = c.t_us;
  hit->source = source;
  hit->jump_g = (uint8_t)(jump > 255 ? 255 : jump);
  float swingDps = swingBefore(cand, SWING_LOOKBACK) * 57.29578f;
  hit->swing_dps = (uint16_t)(swingDps > 65535 ? 65535 : swingDps);
  for (int k = 0; k < 4; k++) hit->q[k] = impactQuatWire(c.q[k]);
  return result | IMPACT_HIT;
}

void impactOrientation(float out[4]) { memcpy(out, q, sizeof(q)); }
uint32_t impactHits() { return hits; }
uint32_t impactWindowsDropped() { return windowsDropped; }
