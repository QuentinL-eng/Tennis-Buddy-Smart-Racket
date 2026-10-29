// Replays a TennisCamera session's racket.bin (u64 arrival ns, u8 kind, u16 length, payload) through the racket's
// impact detector (src/impact.cpp), on a laptop:
//
//   python -m ziglang c++ -O2 -std=c++17 -Iinclude -Isrc -o impact_replay tools/impact_replay/impact_replay.cpp src/impact.cpp
//   ./impact_replay ../data/phone/<session>/racket.bin      (TennisCamera)
//   ./impact_replay ../data/<day>/session-...-racket.csv    (the app's recordings, exported as CSV)
//
// Prints each hit and window, and how they line up with the mic verdicts the racket sent during the session.
// Raw-stream recordings have gaps where BLE packets were lost; the replay skips over them, so a hit that fell in
// a gap can't be found here even though the racket itself would see it.
#include <math.h>
#include <stdio.h>
#include <string.h>

#include <vector>

#include "impact.h"
#include "protocol.h"

// The app's own recordings, exported as CSV (time_s, accel g, gyro rad/s, high-g g; sensor axes). No mic data.
static int replayCsv(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) {
    perror(path);
    return 1;
  }
  char line[512];
  if (!fgets(line, sizeof(line), f)) return 1;   // header
  impactReset();
  static ImpactWindow win;
  int rows = 0, hits = 0, windows = 0, gappy = 0;
  double first = -1, prev = -1;
  while (fgets(line, sizeof(line), f)) {
    double t;
    float v[9];
    if (sscanf(line, "%lf,%f,%f,%f,%f,%f,%f,%f,%f,%f", &t, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7],
               &v[8]) != 10)
      continue;
    if (prev >= 0 && t < prev - 0.05) impactReset();   // the racket rebooted
    if (first < 0) first = t;
    prev = t;
    rows++;
    ImpactInput in;
    in.t_us = (uint32_t)llround(t * 1e6);
    auto i16 = [](float x) { return (int16_t)lroundf(fmaxf(-32768, fminf(32767, x))); };
    in.wire.ax = i16(v[0] * 2048); in.wire.ay = i16(v[1] * 2048); in.wire.az = i16(v[2] * 2048);
    const float dps = 180 / 3.14159265f;
    in.wire.gx = i16(v[3] * dps * 8.2f); in.wire.gy = i16(v[4] * dps * 8.2f); in.wire.gz = i16(v[5] * dps * 8.2f);
    in.wire.hx = i16(v[6] / 0.098f * 16); in.wire.hy = i16(v[7] / 0.098f * 16); in.wire.hz = i16(v[8] / 0.098f * 16);
    for (int a = 0; a < 3; a++) {
      in.accel[a] = v[a];
      in.gyro[a] = v[3 + a];
      in.highG[a] = v[6 + a];
    }
    TBHit hit;
    int r = impactStep(in, 0, &hit, &win);
    if (r & IMPACT_HIT) {
      hits++;
      printf("HIT #%u t %.3f s jump %u g swing %u dps\n", hit.seq, hit.t_us / 1e6, hit.jump_g, hit.swing_dps);
    }
    if (r & IMPACT_WINDOW) {
      windows++;
      uint32_t span = win.chunkT0[TB_WINDOW_CHUNKS - 1] + 7000 - win.chunkT0[0];
      if (span > TB_WINDOW_SAMPLES * 1100u) gappy++;
    }
  }
  fclose(f);
  printf("\n%d samples over %.0f s; %d hits, %d windows (%d spanning gaps)\n", rows, prev - first, hits, windows,
         gappy);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: impact_replay racket.bin | recording.csv\n");
    return 2;
  }
  size_t len = strlen(argv[1]);
  if (len > 4 && strcmp(argv[1] + len - 4, ".csv") == 0) return replayCsv(argv[1]);
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    perror(argv[1]);
    return 1;
  }
  std::vector<uint8_t> data;
  uint8_t buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) data.insert(data.end(), buf, buf + n);
  fclose(f);

  uint8_t h3Range = 1;
  // Racket micros = phone ns / 1000 - offset; the smallest offset seen is the least-delayed packet.
  double offsetUs = 1e30;
  std::vector<double> verdictUs;   // racket-clock time of each mic verdict's arrival
  std::vector<double> verdictNs;
  for (size_t pos = 0; pos + 11 <= data.size();) {
    uint64_t ns;
    memcpy(&ns, &data[pos], 8);
    uint8_t kind = data[pos + 8];
    uint16_t len = data[pos + 9] | data[pos + 10] << 8;
    pos += 11;
    if (pos + len > data.size()) break;
    if (kind == 1 && len >= sizeof(TBPacket)) {
      TBPacket p;
      memcpy(&p, &data[pos], sizeof(p));
      double end = p.t0_us + 8000.0;
      offsetUs = fmin(offsetUs, ns / 1000.0 - end);
    } else if (kind == 3) {
      verdictNs.push_back((double)ns);
    }
    pos += len;
  }
  for (double ns : verdictNs) verdictUs.push_back(ns / 1000.0 - offsetUs);

  impactReset();
  static ImpactWindow win;
  std::vector<double> hitUs;
  int packets = 0, lost = 0, windows = 0, hitsMotion = 0, hitsMic = 0;
  long lastSeq = -1;
  size_t nextVerdict = 0;
  uint32_t micTrigger = 0;
  for (size_t pos = 0; pos + 11 <= data.size();) {
    uint8_t kind = data[pos + 8];
    uint16_t len = data[pos + 9] | data[pos + 10] << 8;
    pos += 11;
    if (pos + len > data.size()) break;
    const uint8_t *pl = &data[pos];
    pos += len;
    if (kind == 2 && len >= 6) h3Range = pl[5];
    if (kind != 1 || len < sizeof(TBPacket)) continue;
    TBPacket p;
    memcpy(&p, pl, sizeof(p));
    packets++;
    if (lastSeq >= 0) {
      int gap = (uint16_t)(p.seq - lastSeq) - 1;
      if (gap > 0 && gap < 1000) lost += gap;
    }
    lastSeq = p.seq;
    bool wide = p.flags & TB_FLAG_GYRO_4000;
    float gyroLsb = wide ? 8.2f : 16.4f;
    float gPerCount = h3Range == 0 ? 0.049f : h3Range == 3 ? 0.195f : 0.098f;
    for (int k = 0; k < p.count; k++) {
      const TBSample &s = p.s[k];
      ImpactInput in;
      in.wire = s;
      in.t_us = p.t0_us + 1000u * k;
      float gyro[3] = {s.gx / gyroLsb, s.gy / gyroLsb, s.gz / gyroLsb};
      int16_t *wireGyro[3] = {&in.wire.gx, &in.wire.gy, &in.wire.gz};
      for (int a = 0; a < 3; a++) {
        *wireGyro[a] = (int16_t)lroundf(fmaxf(-32768, fminf(32767, gyro[a] * 8.2f)));
        in.gyro[a] = gyro[a] * 3.14159265f / 180;
      }
      in.accel[0] = s.ax / 2048.0f; in.accel[1] = s.ay / 2048.0f; in.accel[2] = s.az / 2048.0f;
      in.highG[0] = (s.hx >> 4) * gPerCount; in.highG[1] = (s.hy >> 4) * gPerCount; in.highG[2] = (s.hz >> 4) * gPerCount;
      // The mic triggers ~40 ms before its verdict arrives (32 ms clip + inference + BLE).
      while (nextVerdict < verdictUs.size() && verdictUs[nextVerdict] - 40000 <= in.t_us) {
        micTrigger = (uint32_t)(verdictUs[nextVerdict] - 40000);
        nextVerdict++;
      }
      TBHit hit;
      int r = impactStep(in, micTrigger, &hit, &win);
      if (r & IMPACT_HIT) {
        (hit.source == TB_HIT_MIC ? hitsMic : hitsMotion)++;
        hitUs.push_back(hit.t_us);
        printf("HIT #%u t %.3f s %s jump %u g swing %u dps q %.2f %.2f %.2f %.2f\n", hit.seq, hit.t_us / 1e6,
               hit.source == TB_HIT_MIC ? "mic   " : "motion", hit.jump_g, hit.swing_dps, hit.q[0] / 16384.0,
               hit.q[1] / 16384.0, hit.q[2] / 16384.0, hit.q[3] / 16384.0);
      }
      if (r & IMPACT_WINDOW) {
        windows++;
        uint32_t span = win.chunkT0[TB_WINDOW_CHUNKS - 1] + 7000 - win.chunkT0[0];
        printf("  window #%u: %d samples over %.0f ms (%s), impact at %u\n", win.seq, TB_WINDOW_SAMPLES,
               span / 1000.0, span < TB_WINDOW_SAMPLES * 1100u ? "continuous" : "has gaps", win.impact);
      }
    }
  }

  int matched = 0;
  for (double v : verdictUs) {
    for (double h : hitUs)
      if (fabs(v - 40000 - h) < 150000) { matched++; break; }
  }
  printf("\n%d packets, %d lost (%.0f%%)\n", packets, lost, 100.0 * lost / (packets + lost));
  printf("%zu hits (%d motion, %d mic), %d windows; %zu mic verdicts, %d of them matched by a hit\n", hitUs.size(),
         hitsMotion, hitsMic, windows, verdictUs.size(), matched);
  return 0;
}
