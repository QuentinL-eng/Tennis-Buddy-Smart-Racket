// Hit detection and orientation on the racket (firmware 1.5, impact mode).
//
// Every 1 kHz sample goes through impactStep(), which keeps the last half second in a ring buffer, tracks the
// racket's orientation with the same Mahony filter the apps use, and watches for hits. A hit is reported at once
// (TBHit); TB_WINDOW_POST ms later the samples around it are copied out as one ImpactWindow for the phone to
// analyse. No Arduino dependencies, so it also builds on a laptop: tools/impact_replay/ replays recorded
// sessions through it.
#pragma once
#include <stdint.h>
#include "protocol.h"

struct ImpactInput {
  TBSample wire;    // the sample as the window sends it: gyro at 8.2 LSB/dps
  float accel[3];   // low-g accel, g, sensor axes
  float gyro[3];    // rad/s
  float highG[3];   // high-g accel, g
  uint32_t t_us;    // micros() when it was read
};

struct ImpactWindow {
  uint16_t seq;
  uint16_t impact;                      // index of the impact sample (TB_WINDOW_PRE)
  int16_t q0[4];                        // orientation at s[0]
  uint32_t chunkT0[TB_WINDOW_CHUNKS];   // micros() of each chunk's first sample
  TBSample s[TB_WINDOW_SAMPLES];
};

enum : int {
  IMPACT_HIT = 1,      // *hit was filled in
  IMPACT_WINDOW = 2,   // *win was filled in
};

// Forgets the ring, any pending hit and the orientation (e.g. after the IMU was reconfigured).
void impactReset();

// Feeds one sample. micTriggerUs is micros() of the mic's latest trigger (0 before the first). Pass win = nullptr
// while the previous window is still being sent: a window completed then is dropped (impactWindowsDropped()).
// Returns IMPACT_* flags.
int impactStep(const ImpactInput &in, uint32_t micTriggerUs, TBHit *hit, ImpactWindow *win);

// Latest orientation, sensor axes -> world (z up): w, x, y, z.
void impactOrientation(float q[4]);

// Quaternion component -> wire (x 16384).
int16_t impactQuatWire(float v);

uint32_t impactHits();
uint32_t impactWindowsDropped();
