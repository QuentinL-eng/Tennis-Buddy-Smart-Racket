// Host harness: reads raw int16 clips from stdin (512 samples each), prints features + result per clip.
#include <stdio.h>
#include "../firmware/src/sweetspot.h"
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif
int main() {
#ifdef _WIN32
  _setmode(_fileno(stdin), _O_BINARY);
#endif
  int16_t clip[SS_CLIP_SAMPLES];
  while (fread(clip, sizeof(int16_t), SS_CLIP_SAMPLES, stdin) == SS_CLIP_SAMPLES) {
    float f[SS_N_FEATURES];
    ss_features(clip, f);
    SweetSpotResult r = ss_infer_features(f);
    for (int i = 0; i < SS_N_FEATURES; i++) printf("%.7g ", f[i]);
    printf("%.9g %d %d %d\n", r.distance_cm, r.sweet, r.off_pct, r.confidence);
  }
}
