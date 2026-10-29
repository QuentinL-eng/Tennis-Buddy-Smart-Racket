// Runs the firmware's own tap detector (firmware/src/tap.cpp) over recorded accelerometer samples, on the
// laptop. This is the same trick as ml/c_parity_main.cpp: the algorithm is hardware-independent, so it can be
// tested without the racket.
//
// Build and run:
//     g++ -std=c++17 -O2 -Ifirmware/src -o /tmp/tap_test tools/tap_detect_test.cpp \
//         firmware/src/tap.cpp firmware/src/tap_classify.cpp && /tmp/tap_test data/taps/...
//
// Input is a plain text file: one "t_us ax ay az" line per sample (mg). tools/tap_dump_csv.py produces it.
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "tap.h"

int main(int argc, char **argv) {
  tapInit();
  tapConfigure(300, 90, 200);
  int detections = 0;
  for (int a = 1; a < argc; a++) {
    FILE *f = fopen(argv[a], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[a]); continue; }
    char line[256];
    TapResult r;
    int64_t n = 0;
    int first_hit = -1;
    while (fgets(line, sizeof(line), f)) {
      long long t;
      long x, y, z;
      if (sscanf(line, "%lld %ld %ld %ld", &t, &x, &y, &z) != 4) continue;
      if (tapPush((int32_t)x, (int32_t)y, (int32_t)z, (uint32_t)t, r)) {
        detections++;
        if (first_hit < 0) first_hit = (int)n;
        printf("%s: TAP at sample %lld  jolt %5d mg  strength %3u  zone %u (%s) conf %u%%  feats["
               "%u %u %u %u %u %u %u %u %u %u]\n",
               argv[a], (long long)n, (int)r.jolt_mg, r.strength, r.zone, TAP_ZONE_NAMES[r.zone],
               r.confidence, r.features[0], r.features[1], r.features[2], r.features[3], r.features[4],
               r.features[5], r.features[6], r.features[7], r.features[8], r.features[9]);
      }
      n++;
    }
    fclose(f);
    if (first_hit < 0) printf("%s: no detection (%lld samples)\n", argv[a], (long long)n);
  }
  printf("\n%d detections across %d file(s)\n", detections, argc - 1);
  return 0;
}
