// Handle-tap detector and location estimator.
//
// A tap on the handle is a sharp jolt in the low-g accelerometer followed by a short ring-down. Unlike a ball
// impact it barely registers on the gyro or the high-g channel, which is what separates the two. The jolt also
// depends on where along the handle it landed: the handle is a beam, and a tap excites it differently at the
// butt cap than near the throat, so the ring-down shape carries the position.
//
// The algorithms here are hardware-independent (no Arduino includes) so they can be exercised on a laptop,
// the same way sweetspot.cpp is. The IMU glue lives in firmware/src/main.cpp.
//
// Two outputs per tap:
//   * jolt / strength   what the impact looked like (this is the "was that a tap" question)
//   * zone              where along the handle it was, from the fitted model (tap_model.h)
//
// Calibration: tap the handle at known positions (tools/capture_tap_sites.py) and fit the zones with
// tools/fit_tap_model.py, which rewrites tap_model.h. Until that is done the shipped model is a placeholder
// that always reports TAP_ZONE_UNKNOWN.
#pragma once
#include <stdint.h>

#define TAP_WINDOW 256         // samples kept per tap window (~48 ms at 5.3 kHz)
#define TAP_PRE 96             // samples before the trigger kept in the window
#define TAP_N_FEATURES 10
#define TAP_N_ZONES 5          // 0 = unknown, then butt, grip_60, grip_120, grip_180, throat
#define TAP_ZONE_UNKNOWN 0

struct TapResult {
  uint32_t t_us;                      // micros() of the trigger sample
  int32_t jolt_mg;                    // peak |a| above the pre-tap baseline, mg
  uint8_t strength;                   // jolt mapped to 0..255 for a compact field
  uint8_t zone;                       // TAP_ZONE_UNKNOWN or 1..TAP_N_ZONES-1
  uint8_t confidence;                 // 0..100, how far the winner is from the next-best zone
  uint8_t features[TAP_N_FEATURES];   // quantised feature vector (for logging / re-fitting)
  uint16_t rate_hz;                   // measured sample rate the features were computed at
  int32_t dir_mg[3];                  // accel vector minus the resting baseline at the jolt's peak, mg:
                                      // which way the handle was pushed (the tapped side, up to sign)
};

// Largest deviation from the resting baseline since the last call, mg (for the status line).
int32_t tapPeakDeviation();

struct TapConfig {
  int32_t trig_mg;         // |a| - baseline must exceed this
  int max_len;             // samples allowed between the trigger and the end of the jolt
  uint32_t refractory_ms;  // ignore further taps this soon after one
  uint8_t base_shift;      // running baseline: base += (mag - base) >> shift (8 = fast, 12 = slow)
};

// Initialises with sensible defaults; call once.
void tapInit();

// Optional retune (thresholds are in mg). Anything <= 0 keeps the default.
void tapConfigure(int32_t trig_mg, int max_len, uint32_t refractory_ms);

// Feed one accelerometer sample (mg). Returns true when this sample completed a tap, in which case `out`
// holds the result. Non-blocking; constant work per sample apart from the one window pass at the end.
bool tapPush(int32_t ax, int32_t ay, int32_t az, uint32_t t_us, TapResult &out);

// Copies the last tap's window out (TAP_WINDOW x 3 mg, oldest first; the trigger is at TAP_PRE + lag).
// Only valid immediately after tapPush() returned true. tools/ uses this shape of data for fitting.
void tapWindow(int32_t *out_xyz);

// Evaluates the zone model (tap_model.h) on a quantised feature vector. Lives in tap_classify.cpp.
void tapClassify(const uint8_t *features, uint8_t *zone, uint8_t *confidence);

// Zone names for serial/BLE logging. Index 0 is "unknown".
extern const char *const TAP_ZONE_NAMES[TAP_N_ZONES + 1];
