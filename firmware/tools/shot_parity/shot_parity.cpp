// Runs the racket's shot analyzer (src/shot.cpp) on a laptop, for RacketKit's ShotParityTests:
//
//   clang++ -O2 -std=c++17 -Iinclude -Isrc -o shot_parity tools/shot_parity/shot_parity.cpp src/shot.cpp
//
// stdin: the TB_CMD_SHOT_CONFIG payload, one byte gyro4000, a little-endian u32 window count, then each window as
// its TB_WINDOW_CHUNKS TBWindowChunk messages, exactly as the racket sends them. stdout: one line per window,
// "type spin flags" and the 15 summary floats, or "none" when the analyzer declines.
#include <stdio.h>
#include <string.h>

#include "shot.h"

static bool readAll(void *p, size_t n) { return fread(p, 1, n, stdin) == n; }

int main() {
  uint8_t payload[TB_SHOT_CONFIG_PAYLOAD];
  uint8_t gyro4000;
  uint32_t count;
  ShotConfig cfg;
  if (!readAll(payload, sizeof(payload)) || !readAll(&gyro4000, 1) || !readAll(&count, 4)) return 2;
  if (!shotConfigDecode(payload, sizeof(payload), &cfg)) {
    fprintf(stderr, "bad config\n");
    return 2;
  }
  static ImpactWindow win;
  for (uint32_t w = 0; w < count; w++) {
    for (int c = 0; c < TB_WINDOW_CHUNKS; c++) {
      TBWindowChunk chunk;
      if (!readAll(&chunk, sizeof(chunk))) return 2;
      win.seq = chunk.seq;
      win.impact = chunk.impact;
      memcpy(win.q0, chunk.q0, sizeof(win.q0));
      win.chunkT0[chunk.index] = chunk.t0_us;
      memcpy(&win.s[chunk.index * TB_SAMPLES_PER_PACKET], chunk.s, sizeof(chunk.s));
    }
    TBShotSummary s;
    if (!shotAnalyze(cfg, win, gyro4000 != 0, 0.195f, &s)) {
      printf("none\n");
      continue;
    }
    printf("%u %u %u %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g\n", s.type, s.spin, s.flags,
           s.swing_kmh, s.ball_kmh, s.spin_rpm, s.face_deg, s.path_deg, s.impact_x_cm, s.impact_y_cm, s.peak_g,
           s.roll_ratio, s.ring_norm, s.jolt, s.impulse, s.spin_axis_y, s.vertical_spin, s.swing_deg);
  }
  return 0;
}
