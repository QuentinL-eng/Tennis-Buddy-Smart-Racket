// Nearest-centroid classifier for the tap location model. No Arduino dependencies, so it also builds on a
// laptop; tools/fit_tap_model.py writes tap_model.h, this code only evaluates it.
#include "tap.h"

#include "tap_model.h"

void tapClassify(const uint8_t *features, uint8_t *zone, uint8_t *confidence) {
  *zone = TAP_ZONE_UNKNOWN;
  *confidence = 0;
#if TAP_MODEL_FITTED
  // Weighted squared distance to each fitted zone centroid, integer only (no FPU on the C3).
  int32_t best = 0x7FFFFFFF, second = 0x7FFFFFFF;
  int best_zone = TAP_ZONE_UNKNOWN;
  for (int z = 1; z < TAP_N_ZONES; z++) {
    int32_t d = 0;
    for (int f = 0; f < TAP_N_FEATURES; f++) {
      int32_t diff = (int32_t)features[f] - (int32_t)TAP_MODEL_CENTROID[z][f];
      d += (diff * diff) * TAP_MODEL_WEIGHT[f];
    }
    if (d < best) {
      second = best;
      best = d;
      best_zone = z;
    } else if (d < second) {
      second = d;
    }
  }
  if (best > TAP_MODEL_MARGIN) return;   // no zone is close enough: report unknown instead of a bad guess
  *zone = (uint8_t)best_zone;
  // Confidence is the winner's margin over the runner-up, mapped to 0..100.
  int32_t margin = second - best;
  *confidence = (uint8_t)(margin >= 40000 ? 100 : margin * 100 / 40000);
#else
  (void)features;
#endif
}
