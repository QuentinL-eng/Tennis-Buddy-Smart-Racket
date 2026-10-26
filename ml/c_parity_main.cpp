// Host harness: reads raw int16 clips from stdin (512 samples each), prints features + result per clip.
#include <stdio.h>
#include "../firmware/src/sweetspot.h"
#include "../firmware/src/sweetspot_model.h"
int main() {
  int16_t clip[SS_CLIP_SAMPLES];
  while (fread(clip, sizeof(int16_t), SS_CLIP_SAMPLES, stdin) == SS_CLIP_SAMPLES) {
    float f[SS_N_FEATURES];
    ss_features(clip, f);
    SweetSpotResult r = ss_infer_features(f);
    for (int i = 0; i < SS_N_FEATURES; i++) printf("%.7g ", f[i]);
    printf("%.7g %d %d %d\n", r.p_sweet, r.sweet, r.off_pct, r.confidence);
  }
}
