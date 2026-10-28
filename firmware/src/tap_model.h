// Tap location model: which zone of the handle was tapped, from the tap features.
//
// GENERATED FILE - do not edit by hand. tools/fit_tap_model.py rewrites it:
//
//     python3 tools/capture_tap_sites.py --port COM16 --all
//     python3 tools/fit_tap_model.py
//
// The shipped values below are a PLACEHOLDER: uncalibrated centroids sitting at the middle of each feature's
// range, so the model always answers TAP_ZONE_UNKNOWN until it is fitted on real taps from this racket.
// Detection (firmware/src/tap.cpp) is independent of this file and works without it.
#pragma once
#include <stdint.h>

#define TAP_MODEL_FITTED 0   // 1 once tools/fit_tap_model.py has run

// Zone centroids in the quantised feature space, scaled per axis by TAP_MODEL_SCALE.
// Row per zone (1..TAP_N_ZONES-1), column per feature (TAP_N_FEATURES).
static const uint8_t TAP_MODEL_CENTROID[TAP_N_ZONES][10] = {
    {0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
    {128, 128, 128, 128, 128, 128, 128, 128, 128, 128},
    {128, 128, 128, 128, 128, 128, 128, 128, 128, 128},
    {128, 128, 128, 128, 128, 128, 128, 128, 128, 128},
    {128, 128, 128, 128, 128, 128, 128, 128, 128, 128},
};
// Per-feature weights: features that separate zones well count more in the distance.
static const uint8_t TAP_MODEL_WEIGHT[10] = {8, 8, 8, 16, 16, 24, 24, 16, 8, 8};
// Below TAP_MODEL_MARGIN (in fixed-point distance units) the answer is "unknown" rather than a guess.
static const int32_t TAP_MODEL_MARGIN = 1000000;
