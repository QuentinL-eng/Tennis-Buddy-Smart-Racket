// Shot metrics on the racket (firmware 1.6): a port of ShotAnalyzer and the window path of RacketEngine
// (apple/RacketKit/Sources/RacketKit/ShotAnalyzer.swift, RacketEngine.swift), so the phone gets each shot in one
// small TBShotSummary the moment it is computed, and the full window only as backlog.
//
// It works on the window exactly as the phone receives it (wire units), with the calibration and racket profile
// the app sends (TB_CMD_SHOT_CONFIG). No Arduino dependencies: tools/shot_parity/ builds it on a laptop, and
// RacketKit's ShotParityTests check it against the Swift analyzer.
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "impact.h"
#include "protocol.h"

struct ShotConfig {
  uint8_t gen;              // the app's config generation, echoed in each summary; 0 = not configured
  float mpu[9];             // Calibration.mpuToRacket, row-major: racket x, y, z axes in sensor coordinates
  float h3[9];              // Calibration.h3lisToRacket
  float gyroBias[3];        // rad/s, sensor axes
  float h3Bias[3];          // g, sensor axes
  float accelScale;
  float calQ[4];            // w, x, y, z: simd_quatf(mpuToRacket^T), turns sensor->world into racket->world
  float effectiveRadiusM;
  float forehandBodySign;   // RacketProfile.forehandBodySign: +1 / -1, 0 = use handedness
  float lateralGain, longitudinalGain, joltDeadband, acorCenter, spinGain;   // ImpactModel
  bool rightHanded;
};

// Payload of TB_CMD_SHOT_CONFIG after the command byte: gen, 37 little-endian floats in the order above
// (mpu, h3, gyroBias, h3Bias, accelScale, calQ, effectiveRadiusM, forehandBodySign, the five model constants),
// then rightHanded.
#define TB_SHOT_CONFIG_PAYLOAD (1 + 37 * 4 + 1)
bool shotConfigDecode(const uint8_t *p, size_t len, ShotConfig *out);

// Computes the shot for one window. gyro4000: the IMU was at ±4000 dps (sets the saturation limit); hgPerCount: g
// per high-g wire count (0.195 at the ±400 g range). Returns false
// if the config is missing or the window is unusable; the summary's seq, boot, age and time are left to the caller.
bool shotAnalyze(const ShotConfig &cfg, const ImpactWindow &win, bool gyro4000, float hgPerCount,
                 TBShotSummary *out);
