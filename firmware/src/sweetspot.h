// On-device sweet-spot classifier. No Arduino dependencies, so it also builds on a laptop
// (ml/test_parity.py does exactly that). Spec of the features: ml/features.py. Model: ml/README.md.
#pragma once
#include <stdint.h>

#define SS_CLIP_SAMPLES 512     // 32 ms at 16 kHz
#define SS_PRE_SAMPLES 64       // impact onset sits at this index
#define SS_SAMPLE_RATE 16000
#define SS_N_FEATURES 156

struct SweetSpotResult {
  bool sweet;          // true = ball hit inside the sweet spot (<= 4 cm from center)
  uint8_t off_pct;     // 0 when sweet, else how far toward the frame (100 = at the frame)
  uint8_t confidence;  // 0..100, confidence in the sweet/not-sweet call
  float p_sweet;       // NaN: this regressor has no calibrated probability
  float distance_cm;   // estimated distance from centre
};

// Computes 156 frequency/envelope features. out must hold SS_N_FEATURES floats.
void ss_features(const int16_t *clip, float *out);

// Runs ridge distance regression. A distance <= 4 cm is sweet.
SweetSpotResult ss_infer_features(const float *features);

// Convenience: clip -> result.
SweetSpotResult ss_classify(const int16_t *clip);

// Known-answer checks on reviewed clips. Run once before starting capture.
bool ss_self_test();
