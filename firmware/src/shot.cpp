#include "shot.h"

#include <math.h>
#include <string.h>

// Mirrors the Swift code step by step (same order of operations where it matters), so the parity test can hold the
// two to tight tolerances. Racket frame: x toward the tip, y across the face, z face normal.

namespace {

struct V3 {
  float x, y, z;
};
struct Q {
  float w, x, y, z;
};

inline V3 add(V3 a, V3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline V3 sub(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline V3 mul(V3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline V3 dvd(V3 a, float s) { return {a.x / s, a.y / s, a.z / s}; }
inline float dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline V3 cross(V3 a, V3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
inline float len(V3 a) { return sqrtf(dot(a, a)); }
inline V3 norm(V3 a) { return dvd(a, len(a)); }

// Row-major 3x3 times vector (simd_float3x3(rows:) * v).
inline V3 mv(const float *m, V3 v) {
  return {m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z,
          m[6] * v.x + m[7] * v.y + m[8] * v.z};
}

inline Q qmul(Q a, Q b) {
  return {a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z, a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
          a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x, a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w};
}
inline Q qnorm(Q q) {
  float n = sqrtf(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z);
  return {q.w / n, q.x / n, q.y / n, q.z / n};
}
inline Q qinv(Q q) {
  float n2 = q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z;
  return {q.w / n2, -q.x / n2, -q.y / n2, -q.z / n2};
}
// Rotates v by q (q * (0, v) * q^-1).
inline V3 act(Q q, V3 v) {
  Q p = qmul(qmul(q, Q{0, v.x, v.y, v.z}), qinv(q));
  return {p.x, p.y, p.z};
}
inline Q fromAngleAxis(float angle, V3 axis) {
  float s = sinf(angle / 2);
  return {cosf(angle / 2), axis.x * s, axis.y * s, axis.z * s};
}

struct Sample {
  double time;   // s, as RacketBLE computes it: chunk t0 + k ms
  V3 accel, gyro, highG;   // racket frame (Calibration.apply)
};

struct Ctx {
  const ShotConfig &cfg;
  const ImpactWindow &win;
  float hgPerCount;

  // RacketProtocol.convert (window gyro is always 8.2 LSB/dps) then Calibration.apply.
  Sample at(int k) const {
    const TBSample &r = win.s[k];
    const float lsbPerDps = 16.4f / 2, dps2rad = (float)M_PI / 180;
    V3 a = {r.ax / 2048.0f, r.ay / 2048.0f, r.az / 2048.0f};
    V3 g = {r.gx / lsbPerDps * dps2rad, r.gy / lsbPerDps * dps2rad, r.gz / lsbPerDps * dps2rad};
    V3 h = {(float)(r.hx >> 4) * hgPerCount, (float)(r.hy >> 4) * hgPerCount, (float)(r.hz >> 4) * hgPerCount};
    Sample s;
    s.time = win.chunkT0[k / TB_SAMPLES_PER_PACKET] / 1e6 + (k % TB_SAMPLES_PER_PACKET) * 0.001;
    s.accel = mul(mv(cfg.mpu, a), cfg.accelScale);
    s.gyro = mv(cfg.mpu, sub(g, {cfg.gyroBias[0], cfg.gyroBias[1], cfg.gyroBias[2]}));
    s.highG = mv(cfg.h3, sub(h, {cfg.h3Bias[0], cfg.h3Bias[1], cfg.h3Bias[2]}));
    return s;
  }
};

// MahonyFilter.update (Orientation.swift), already initialized.
struct Mahony {
  Q q;
  V3 integral = {0, 0, 0};
  void update(V3 gyro, V3 accel, float dt) {
    const float kp = 2.0f, ki = 0.05f;
    float aNorm = len(accel);
    V3 w = gyro;
    if (aNorm > 0.85f && aNorm < 1.15f && len(gyro) < 3) {
      V3 a = dvd(accel, aNorm);
      V3 upBody = act(qinv(q), {0, 0, 1});
      V3 e = cross(a, upBody);
      integral = add(integral, mul(mul(e, ki), dt));
      w = add(w, add(mul(e, kp), integral));
    }
    float angle = len(w) * dt;
    if (angle > 1e-9f) q = qnorm(qmul(q, fromAngleAxis(angle, norm(w))));
  }
};

inline float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }

}  // namespace

bool shotConfigDecode(const uint8_t *p, size_t len, ShotConfig *out) {
  if (len < TB_SHOT_CONFIG_PAYLOAD || p[0] == 0) return false;
  ShotConfig c;
  c.gen = p[0];
  float f[36];
  memcpy(f, p + 1, sizeof(f));   // little-endian on both ends
  int i = 0;
  for (int k = 0; k < 9; k++) c.mpu[k] = f[i++];
  for (int k = 0; k < 9; k++) c.h3[k] = f[i++];
  for (int k = 0; k < 3; k++) c.gyroBias[k] = f[i++];
  for (int k = 0; k < 3; k++) c.h3Bias[k] = f[i++];
  c.accelScale = f[i++];
  for (int k = 0; k < 4; k++) c.calQ[k] = f[i++];
  c.effectiveRadiusM = f[i++];
  c.forehandBodySign = f[i++];
  c.lateralGain = f[i++];
  c.longitudinalGain = f[i++];
  c.joltDeadband = f[i++];
  c.acorCenter = f[i++];
  c.spinGain = f[i++];
  c.rightHanded = p[1 + 36 * 4] != 0;
  for (int k = 0; k < 36; k++)
    if (!isfinite(f[k])) return false;
  *out = c;
  return true;
}

bool shotAnalyze(const ShotConfig &cfg, const ImpactWindow &win, bool gyro4000, float hgPerCount,
                 TBShotSummary *out) {
  if (cfg.gen == 0) return false;
  const int count = TB_WINDOW_SAMPLES;
  Ctx ctx{cfg, win, hgPerCount};

  // RacketEngine.analyzeImpact: refine the impact on the largest 3 ms high-g jump within ±6 of the racket's mark.
  int center = win.impact + 2;
  int best = center;
  float bestJump = 0;
  int lo = center - 6 > 3 ? center - 6 : 3;
  int hi = center + 6 < count - 1 ? center + 6 : count - 1;
  if (hi < 3) hi = 3;
  for (int k = lo; k <= hi; k++) {
    float j = len(sub(ctx.at(k).highG, ctx.at(k - 3).highG));
    if (j > bestJump) { bestJump = j; best = k; }
  }
  const int i0 = best - 2 > 0 ? best - 2 : 0;
  const int n = i0 + 150 < count ? i0 + 150 : count;   // window[lo..<hi] with lo = 0 (i0 < 700)

  // RacketEngine.process(window): integrate from the racket's orientation at the window start, in racket axes.
  Mahony f;
  Q s2w = {win.q0[0] / 16384.0f, win.q0[1] / 16384.0f, win.q0[2] / 16384.0f, win.q0[3] / 16384.0f};
  s2w = qnorm(s2w);   // RacketProtocol.quaternion normalizes
  f.q = qnorm(qmul(s2w, Q{cfg.calQ[0], cfg.calQ[1], cfg.calQ[2], cfg.calQ[3]}));
  const int qAt = i0 - 3 > 0 ? i0 - 3 : 0;
  double last = 0;
  for (int k = 0; k <= qAt; k++) {
    Sample s = ctx.at(k);
    double d = k == 0 ? 0.001 : s.time - last;
    if (k > 0) d = d < 0.0002 ? 0.0002 : d > 0.02 ? 0.02 : d;
    last = s.time;
    f.update(s.gyro, s.accel, (float)d);
  }
  const Q q = f.q;
  const ShotConfig &m = cfg;

  // ---- ShotAnalyzer.analyze ----
  auto meanGyro = [&](int a, int b) {
    int l = a > 0 ? a : 0, h = b < n ? b : n;
    V3 sum = {0, 0, 0};
    if (h <= l) return sum;
    for (int k = l; k < h; k++) sum = add(sum, ctx.at(k).gyro);
    return dvd(sum, (float)(h - l));
  };
  V3 wPre = meanGyro(i0 - 10, i0 - 2);
  V3 wPost = meanGyro(i0 + 12, i0 + 30);
  V3 dW = sub(wPost, wPre);
  // ShotAnalyzer.swingAngleDeg: degrees turned in the 350 ms before contact (volleys are short swings).
  float swingDeg = 0;
  if (i0 > 0 && i0 < n) {
    const double start = ctx.at(i0).time - 0.35;
    float angle = 0;
    int k = i0 - 1;
    while (k > 0) {
      Sample a = ctx.at(k), b = ctx.at(k - 1);
      if (!(b.time > start)) break;
      double gap = a.time - b.time;
      float dt = (float)(gap < 0.06 ? gap : 0.06);
      angle += (len(a.gyro) + len(b.gyro)) / 2 * dt;
      k -= 1;
    }
    swingDeg = angle * 180 / (float)M_PI;
  }

  // Rotation about the shaft only spins the head in place: the sweet spot moves with the rotation across it.
  float omega = len(wPre);
  float vRacket = sqrtf(wPre.y * wPre.y + wPre.z * wPre.z) * m.effectiveRadiusM;

  const V3 up = {0, 0, 1};
  V3 tipW = act(q, {1, 0, 0});
  V3 normalW = act(q, {0, 0, 1});
  V3 omegaW = act(q, wPre);
  V3 vDir = cross(omegaW, mul(tipW, m.effectiveRadiusM));
  vDir = len(vDir) > 1e-3f ? norm(vDir) : normalW;
  float hitSign = dot(normalW, vDir) >= 0 ? 1 : -1;
  V3 hitNormal = mul(normalW, hitSign);
  float faceAngle = asinf(clampf(dot(hitNormal, up), -1, 1)) * 180 / (float)M_PI;
  float pathAngle = asinf(clampf(dot(vDir, up), -1, 1)) * 180 / (float)M_PI;

  // Shot type (thresholds from ShotAnalyzer: volleyMaxSwingDeg, serveMaxVertical).
  bool forehandTurn = (omegaW.z > 0) == m.rightHanded;
  float forehandVertical = (omega > 1e-3f ? omegaW.z / omega : 0) * (m.rightHanded ? 1 : -1);
  uint8_t type;
  if (swingDeg < 93) {
    type = TB_SHOT_VOLLEY;
  } else if (m.forehandBodySign != 0) {
    bool forehandFace = wPre.y * m.forehandBodySign > 0;
    type = !forehandFace ? TB_SHOT_BACKHAND : (forehandVertical < -0.1f ? TB_SHOT_SERVE : TB_SHOT_FOREHAND);
  } else if (dot(tipW, up) > 0.5f && omega > 8) {
    type = TB_SHOT_SERVE;
  } else {
    type = forehandTurn ? TB_SHOT_FOREHAND : TB_SHOT_BACKHAND;
  }

  // Impact location.
  float impulse = fmaxf(fabsf(dW.y), 0.5f);
  float rollRatio = dW.x / impulse;
  float impactX = fmaxf(-12, fminf(12, -rollRatio * m.lateralGain));

  int ringStart = i0 + 4 < n ? i0 + 4 : n, ringEnd = i0 + 60 < n ? i0 + 60 : n;
  float ringEnergy = 0;
  if (ringEnd - ringStart > 8) {
    float cnt = 0;
    int zlen = ringEnd - (ringStart - 4);
    for (int k = 4; k < zlen; k++) {
      int b0 = ringStart - 4;
      float z0 = ctx.at(b0 + k).highG.z, z1 = ctx.at(b0 + k - 1).highG.z;
      float z2 = ctx.at(b0 + k - 2).highG.z, z3 = ctx.at(b0 + k - 3).highG.z;
      float fast = (z0 + z1) / 2;
      float slow = (z0 + z1 + z2 + z3) / 4;
      float b = fast - slow;
      ringEnergy += b * b;
      cnt += 1;
    }
    ringEnergy = sqrtf(ringEnergy / fmaxf(cnt, 1));
  }
  float ringNorm = ringEnergy / impulse;

  float base = 0;
  {
    int l = i0 - 14 > 0 ? i0 - 14 : 0, h = i0 - 4 < n ? i0 - 4 : n;
    if (h > l) {
      V3 sum = {0, 0, 0};
      for (int k = l; k < h; k++) sum = add(sum, ctx.at(k).highG);
      base = dvd(sum, (float)(h - l)).z;
    }
  }
  float dv = 0;
  for (int k = i0 - 1 > 0 ? i0 - 1 : 0; k < (i0 + 5 < n ? i0 + 5 : n); k++) {
    float excess = ctx.at(k).highG.z - base;
    dv += excess * 0.00981f;
  }
  float jolt = dv * hitSign / impulse;
  float impactY = fminf(14, ringNorm * m.longitudinalGain);
  if (fabsf(jolt) < m.joltDeadband) {
    impactY *= 0.3f;
  } else if (jolt > 0) {
    impactY = -impactY;
  }
  float distance = sqrtf(impactX * impactX + impactY * impactY);

  // Ball speed, for a still ball (ShotAnalyzer.incomingBallMs = 0: the incoming pace isn't measured).
  float e = m.acorCenter * fmaxf(0.55f, 1 - 0.035f * distance);
  const float incomingBallMs = 0;
  float vBall = e * incomingBallMs + (1 + e) * vRacket;

  // Spin: brushing speed along the strings.
  V3 along = sub(vDir, mul(hitNormal, dot(vDir, hitNormal)));
  float brush = vRacket * len(along);
  float spinRPM = m.spinGain * brush / 0.0335f * 60 / (2 * (float)M_PI);
  uint8_t spin = spinRPM < 600 ? TB_SPIN_FLAT : (dot(along, up) > 0 ? TB_SPIN_TOPSPIN : TB_SPIN_SLICE);

  float peakG = 0;
  for (int k = i0 - 5 > 0 ? i0 - 5 : 0; k < (i0 + 10 < n ? i0 + 10 : n); k++) peakG = fmaxf(peakG, len(ctx.at(k).highG));
  const float sat = (gyro4000 ? 3990.0f : 1990.0f) * (float)M_PI / 180;
  bool saturated = false;
  for (int k = i0 - 300 > 0 ? i0 - 300 : 0; k < (i0 + 30 < n ? i0 + 30 : n) && !saturated; k++) {
    V3 g = ctx.at(k).gyro;
    saturated = fabsf(g.x) > sat || fabsf(g.y) > sat || fabsf(g.z) > sat;
  }

  out->gen = cfg.gen;
  out->type = type;
  out->spin = spin;
  out->flags = saturated ? TB_SUMMARY_SATURATED : 0;
  out->swing_kmh = vRacket * 3.6f;
  out->ball_kmh = vBall * 3.6f;
  out->spin_rpm = spinRPM;
  out->face_deg = faceAngle;
  out->path_deg = pathAngle;
  out->impact_x_cm = impactX;
  out->impact_y_cm = impactY;
  out->peak_g = peakG;
  out->roll_ratio = rollRatio;
  out->ring_norm = ringNorm;
  out->jolt = jolt;
  out->impulse = impulse;
  out->spin_axis_y = wPre.y;
  out->vertical_spin = forehandVertical;
  out->swing_deg = swingDeg;
  return true;
}
