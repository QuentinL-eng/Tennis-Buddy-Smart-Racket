// BLE protocol shared with the apps (see docs/PLAN.md, "BLE protocol").
// Keep in sync with apple/RacketKit/Sources/RacketKit/Protocol.swift.
#pragma once
#include <stdint.h>

#define TB_DEVICE_NAME   "Tennis Buddy"
#define TB_SERVICE_UUID  "7E5B0001-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_IMU_UUID      "7E5B0002-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_STATUS_UUID   "7E5B0003-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_CONTROL_UUID  "7E5B0004-6B1D-4D8E-9C1A-7E5B7E5B0001"
#define TB_SHOT_UUID     "7E5B0005-6B1D-4D8E-9C1A-7E5B7E5B0001"  // on-device ML verdict, notify
#define TB_TAP_UUID      "7E5B0006-6B1D-4D8E-9C1A-7E5B7E5B0001"  // handle tap gesture, notify
// Impact mode (firmware 1.5+): the racket detects hits itself and sends only the samples around each one.
// 0007 stays unused: legacy OTA firmware used it for image data.
#define TB_HIT_UUID      "7E5B0008-6B1D-4D8E-9C1A-7E5B7E5B0001"  // TBHit, notify, sent the moment a hit is seen
#define TB_WINDOW_UUID   "7E5B0009-6B1D-4D8E-9C1A-7E5B7E5B0001"  // TBWindowChunk, notify, the samples around it
#define TB_POSE_UUID     "7E5B000A-6B1D-4D8E-9C1A-7E5B7E5B0001"  // TBPose, notify, ~30 Hz orientation for live views

#define TB_FW_MAJOR 1
#define TB_FW_MINOR 6

#define TB_SAMPLES_PER_PACKET 8

// Impact window: samples before and after the impact sample, sent in TB_SAMPLES_PER_PACKET chunks.
#define TB_WINDOW_PRE 384
#define TB_WINDOW_POST 64
#define TB_WINDOW_SAMPLES (TB_WINDOW_PRE + TB_WINDOW_POST)
#define TB_WINDOW_CHUNKS (TB_WINDOW_SAMPLES / TB_SAMPLES_PER_PACKET)

// Control commands (first byte written to the control characteristic)
enum : uint8_t {
  TB_CMD_START_STREAM = 0x01,
  TB_CMD_STOP_STREAM  = 0x02,
  TB_CMD_H3LIS_RANGE  = 0x10,  // second byte: 0 = 100 g, 1 = 200 g, 3 = 400 g
  TB_CMD_GYRO_RANGE   = 0x11,  // second byte: 0 = ±2000 dps (16.4 LSB/dps), 1 = ±4000 dps (8.2 LSB/dps).
                               // Firmware 1.3+. Since 1.6 the racket starts at ±4000 dps and returns to it when
                               // the last client disconnects; every packet's TB_FLAG_GYRO_4000 says which.
  TB_CMD_STREAM_MODE  = 0x12,  // second byte: 0 = raw (every sample on the IMU characteristic), 1 = impacts
                               // (hit, window and pose characteristics only). Firmware 1.5+. Back to raw when
                               // the last client disconnects, so an app that never sends this still streams.
};

enum : uint8_t {
  TB_STREAM_RAW = 0,
  TB_STREAM_IMPACTS = 1,
};

// What found a hit (TBHit.source)
enum : uint8_t {
  TB_HIT_MOTION = 1,  // high-g jump during a swing
  TB_HIT_MIC = 2,     // the mic heard it and a smaller high-g jump confirmed it (blocks, soft volleys)
};

// Status flags
enum : uint8_t {
  TB_FLAG_MPU_OK   = 1 << 0,
  TB_FLAG_H3LIS_OK = 1 << 1,
  TB_FLAG_STREAMING = 1 << 2,
  TB_FLAG_GYRO_4000 = 1 << 3,  // gyro samples in this packet are 8.2 LSB/dps (±4000 dps), not 16.4
  TB_FLAG_IMPACT_MODE = 1 << 4,  // status only: the racket is in impact mode (TB_CMD_STREAM_MODE)
};

#pragma pack(push, 1)
// Units are those of the original MPU6050 + H3LIS331DL; the LSM6DSV320X firmware converts into them.
struct TBSample {
  int16_t ax, ay, az;  // low-g accel, 2048 LSB/g (±16 g)
  int16_t gx, gy, gz;  // gyro, 16.4 LSB/(deg/s) (±2000 deg/s), or 8.2 with TB_FLAG_GYRO_4000
  int16_t hx, hy, hz;  // high-g accel as H3LIS331DL counts, 12-bit left-aligned (>> 4), at the h3lis_range scale
};

struct TBPacket {
  uint16_t seq;
  uint32_t t0_us;      // micros() of the first sample; samples are 1 ms apart
  uint8_t count;       // valid samples (normally TB_SAMPLES_PER_PACKET)
  uint8_t flags;       // TB_FLAG_*
  TBSample s[TB_SAMPLES_PER_PACKET];
};

struct TBStatus {
  uint16_t battery_mv;
  uint8_t fw_major, fw_minor;
  uint8_t flags;
  uint8_t h3lis_range;  // 0 = 100 g, 1 = 200 g, 3 = 400 g
  uint16_t dropped;     // packets dropped because the BLE queue was full
};
// One verdict from the on-device sweet-spot model (firmware/src/sweetspot.cpp), sent once per detected impact.
struct TBShot {
  uint16_t seq;         // counts impacts since boot
  uint8_t sweet;        // 1 = sweet spot, 0 = off-center
  uint8_t off_pct;      // 0 if sweet; else 33..100, distance toward the frame (100 = at the frame)
  uint8_t confidence;   // 0 = unavailable (ridge); legacy classifier used 50..100 percent
  uint8_t level;        // impact loudness, 0..255 (255 = full scale; ~255 means the mic clipped)
};
// One handle-tap gesture (firmware/src/tap.cpp), sent once the taps stop: a single, double or triple tap.
// Swings and ball impacts are filtered out on the racket.
struct TBTap {
  uint16_t seq;         // counts gestures since boot
  uint8_t count;        // taps in the gesture: 1 = single, 2 = double, ...
  uint8_t strength;     // strongest tap's jolt, 0..255 (255 = 2 g or more above the resting level)
  uint8_t zone;         // where on the handle: 0 = unknown, 1 butt, 2 grip_60, 3 grip_120, 4 grip_180, 5 throat
  uint8_t confidence;   // 0..100 (%), confidence in the zone; 0 while the zone model is unfitted
  int8_t dir[3];        // strongest tap's push direction in accel (sensor) axes, unit vector x 127. Its sign
                        // depends on which of two opposite sides was hit, so the app compares |cos| to the
                        // calibrated wide-side and narrow-side axes.
};
// Sent the moment a hit is detected, before its window. Quaternions are w, x, y, z x 16384 and rotate sensor
// axes into the world (z up), from the racket's own orientation filter (firmware/src/impact.cpp).
struct TBHit {
  uint16_t seq;         // counts hits since boot; the window with the same seq follows
  uint32_t t_us;        // micros() of the impact sample
  uint8_t source;       // TB_HIT_*
  uint8_t jump_g;       // high-g change over 3 ms at the impact, g (capped at 255)
  uint16_t swing_dps;   // fastest rotation in the 150 ms before the impact
  int16_t q[4];         // orientation at the impact
};
// One slice of a hit's window. Gyro is always at 8.2 LSB/dps (TB_FLAG_GYRO_4000 set), whatever the range.
struct TBWindowChunk {
  uint16_t seq;         // the TBHit this belongs to
  uint8_t index;        // 0 .. total - 1
  uint8_t total;        // TB_WINDOW_CHUNKS
  uint16_t impact;      // index of the impact sample in the whole window
  int16_t q0[4];        // orientation at the window's first sample (same in every chunk)
  uint32_t t0_us;       // micros() of this chunk's first sample; samples are 1 ms apart
  uint8_t count;
  uint8_t flags;        // TB_FLAG_*
  TBSample s[TB_SAMPLES_PER_PACKET];
};
// Live orientation while in impact mode, ~30 Hz.
struct TBPose {
  int16_t q[4];
  uint16_t gyro_dps;    // |gyro|
  uint8_t high_g;       // |high-g accel|, g (capped at 255)
  uint8_t flags;        // TB_FLAG_*
};
#pragma pack(pop)

static_assert(sizeof(TBSample) == 18, "sample size");
static_assert(sizeof(TBPacket) == 152, "packet must fit one 185-byte iOS MTU");
static_assert(sizeof(TBStatus) == 8, "status size");
static_assert(sizeof(TBShot) == 6, "shot size");
static_assert(sizeof(TBTap) == 9, "tap size");
static_assert(sizeof(TBHit) == 18, "hit size");
static_assert(sizeof(TBWindowChunk) == 164, "window chunk must fit one 185-byte iOS MTU");
static_assert(sizeof(TBPose) == 12, "pose size");
static_assert(TB_WINDOW_SAMPLES % TB_SAMPLES_PER_PACKET == 0, "window must be whole chunks");
